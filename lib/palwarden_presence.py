# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
"""Shared player-presence evidence: schema, strict payload validation, and
sequence-fenced observation transactions.

Idle eligibility (idle-shutdown/knock-wake spec §5.1) must rest on POSITIVE,
fresh, schema-valid empty observations — never on identity history. This
module owns the singleton ``presence_state`` row and the one observation
writer shared by the ``palworld-fps`` sampler and (Task 7) the idle watcher's
final checks, so both sides classify a payload identically.

Contract:

- ``presence_state`` is a one-row table: ``last_success_ms`` (last
  schema-valid players observation), ``valid`` (did the most recent attempted
  pass succeed), ``empty_since_ms`` (start of the current observed-empty
  interval, NULL when occupied/unknown), plus ``allocated_seq``/``applied_seq``
  counters for the observation fence.
- A valid empty response preserves ``empty_since_ms`` only while the previous
  observation was valid and no more than MAX_GAP_MS old (forward AND not in
  the future); otherwise the empty interval starts now.
- A nonempty list clears ``empty_since_ms`` — including lists that contain
  only loading placeholders (placeholder filtering happens when recording
  identities, never when classifying occupancy).
- Failure/malformed payloads invalidate state and clear ``empty_since_ms``.
  Missing/wrong-shaped ``players``, non-list values, and non-object entries
  are ERRORS, never an empty list.
- Before each HTTP request the caller ``reserve_observation()``s an increasing
  sequence in a short write transaction; ``apply_observation()`` applies a
  result only while its sequence is newer than ``applied_seq``. This fences an
  older in-flight sampler response from overwriting a newer watcher result or
  retroactively extending playtime. No DB transaction is ever held across the
  HTTP request.

Callers must hold no open transaction when calling reserve/apply/invalidate;
each opens its own short ``BEGIN IMMEDIATE`` and commits.
"""

from __future__ import annotations

import json
import os
import sqlite3
from typing import Any

# Maximum trusted observation gap, fixed in v1: slower sampling simply cannot
# obtain idle eligibility (spec §5.1 — documented, not weakened).
MAX_GAP_MS = 60_000

# Presence-session grace for playtime accounting (was a palworld-fps constant;
# env-overridable as the tests' lever to force session splits without waiting).
PRESENCE_GRACE_MS = int(os.environ.get("PALWARDEN_PRESENCE_GRACE_MS", "60000"))


class PresencePayloadError(ValueError):
    """The players payload is missing, malformed, or ambiguous — an ERROR.

    It must never be coerced to an empty list: a silent [] would let a broken
    REST answer masquerade as positive evidence of an empty server.
    """


def create_schema(con: sqlite3.Connection) -> None:
    """Additive migration for everything presence owns: identity, sessions,
    and the singleton row (which begins unknown — a migrated DB's historical
    rows never initialize trusted emptiness)."""
    con.execute(
        """
        CREATE TABLE IF NOT EXISTS player_identity (
            player_uid    TEXT NOT NULL PRIMARY KEY,
            steam_userid  TEXT,
            name          TEXT NOT NULL,
            level         INTEGER,
            first_seen_ms INTEGER NOT NULL,
            last_seen_ms  INTEGER NOT NULL,
            total_play_ms INTEGER NOT NULL DEFAULT 0
        )
        """
    )
    con.execute(
        """
        CREATE TABLE IF NOT EXISTS player_sessions (
            player_uid    TEXT NOT NULL,
            started_at_ms INTEGER NOT NULL,
            last_seen_ms  INTEGER NOT NULL,
            samples       INTEGER NOT NULL
        )
        """
    )
    con.execute("CREATE INDEX IF NOT EXISTS idx_player_sessions_uid_time ON player_sessions(player_uid, last_seen_ms)")
    con.execute(
        """
        CREATE TABLE IF NOT EXISTS presence_state (
            id              INTEGER PRIMARY KEY CHECK (id = 1),
            last_success_ms INTEGER,
            valid           INTEGER NOT NULL DEFAULT 0,
            empty_since_ms  INTEGER,
            allocated_seq   INTEGER NOT NULL DEFAULT 0,
            applied_seq     INTEGER NOT NULL DEFAULT 0
        )
        """
    )
    con.execute("INSERT OR IGNORE INTO presence_state (id, valid) VALUES (1, 0)")
    con.commit()


def _reject_duplicate_keys(pairs):
    seen = set()
    for key, _ in pairs:
        if key in seen:
            raise PresencePayloadError("duplicate JSON key %r" % (key,))
        seen.add(key)
    return dict(pairs)


def parse_api_json(text: str) -> dict[str, Any]:
    """Strictly parse one complete REST API response (spec §5.1, F3).

    The whole output must be a single JSON object: a top-level array,
    trailing garbage, or duplicate keys AT ANY DEPTH is an error — never a
    silently-coerced ``[]``. ``json.loads`` alone accepts duplicate keys
    (last wins), so an occupied ``{"players":[A],"players":[]}`` answer
    would otherwise read as empty; the pairs hook refuses it instead. The
    API client prints the raw REST body on success (errors go to stderr
    with a non-zero exit), so there is no surrounding prose to slice out.
    """
    try:
        payload = json.loads(text, object_pairs_hook=_reject_duplicate_keys)
    except PresencePayloadError:
        raise
    except (ValueError, TypeError) as exc:
        raise PresencePayloadError("API output is not one JSON object: %s" % exc)
    if not isinstance(payload, dict):
        raise PresencePayloadError("API payload is not a JSON object")
    return payload


def validate_players_payload(payload: Any) -> list[dict[str, Any]]:
    """Strictly extract the players list, or raise PresencePayloadError.

    One validator for sampler and watcher final checks alike: a missing or
    wrong-shaped ``players`` field, a non-list value, or any non-object entry
    is an error, not ``[]``.
    """
    if not isinstance(payload, dict):
        raise PresencePayloadError("players payload is not a JSON object")
    if "players" not in payload:
        raise PresencePayloadError("players payload is missing the 'players' field")
    players = payload["players"]
    if not isinstance(players, list):
        raise PresencePayloadError("'players' is not a list")
    for entry in players:
        if not isinstance(entry, dict):
            raise PresencePayloadError("'players' contains a non-object entry")
    return players


def _begin_immediate(con: sqlite3.Connection) -> None:
    # sqlite3's default isolation starts a deferred transaction on the first
    # read; we want the write lock up front so the read-check-update below is
    # atomic against other observers (spec: short write transaction).
    if not con.in_transaction:
        con.execute("BEGIN IMMEDIATE")


def reserve_observation(con: sqlite3.Connection) -> int:
    """Reserve the next observation sequence BEFORE the HTTP request.

    Returns the reserved sequence; a later apply_observation() with it is
    refused once any newer sequence has been applied.
    """
    _begin_immediate(con)
    con.execute(
        "UPDATE presence_state SET allocated_seq = allocated_seq + 1 WHERE id = 1"
    )
    seq = int(
        con.execute("SELECT allocated_seq FROM presence_state WHERE id = 1").fetchone()[0]
    )
    con.commit()
    return seq


def apply_observation(
    con: sqlite3.Connection,
    seq: int,
    ok: bool,
    players: list[dict[str, Any]] | None,
    at_ms: int,
    grace_ms: int = PRESENCE_GRACE_MS,
) -> dict[str, Any]:
    """Apply one observation under the sequence fence, in one transaction.

    ``ok=True`` requires a payload already accepted by
    validate_players_payload(); ``ok=False`` (players ignored) invalidates
    evidence. Returns ``{"applied": bool, "seen": int}``; a superseded
    sequence applies NOTHING — no presence_state change, no identity/session
    or playtime movement.
    """
    _begin_immediate(con)
    row = con.execute(
        "SELECT last_success_ms, valid, empty_since_ms, applied_seq "
        "FROM presence_state WHERE id = 1"
    ).fetchone()
    if row is None:  # tolerate a schema created by an older build
        con.rollback()
        create_schema(con)
        return apply_observation(con, seq, ok, players, at_ms, grace_ms)
    last_success_ms, valid, empty_since_ms, applied_seq = (
        row[0],
        int(row[1]),
        row[2],
        int(row[3]),
    )
    if seq <= applied_seq:
        con.rollback()
        return {"applied": False, "seen": 0}

    if not ok:
        last_success_ms, valid, empty_since_ms = last_success_ms, 0, None
    else:
        assert players is not None
        valid = 1
        last_success_ms = at_ms
        if len(players) == 0:
            # Preserve the empty interval only while the PRIOR observation was
            # valid and fresh (forward, and not in the future).
            fresh = (
                bool(row[1])
                and row[0] is not None
                and 0 <= at_ms - int(row[0]) <= MAX_GAP_MS
            )
            empty_since_ms = row[2] if (fresh and row[2] is not None) else at_ms
        else:
            empty_since_ms = None

    con.execute(
        "UPDATE presence_state SET last_success_ms=?, valid=?, empty_since_ms=?, "
        "applied_seq=? WHERE id = 1",
        (last_success_ms, valid, empty_since_ms, seq),
    )
    seen = 0
    if ok and players is not None:
        seen = _record_identities(con, players, at_ms, grace_ms)
    con.commit()
    return {"applied": True, "seen": seen}


def invalidate(con: sqlite3.Connection) -> None:
    """Best-effort invalidation for a failed pass (and for watcher checks).

    Clears validity and the empty interval; leaves last_success_ms alone so
    freshness expires naturally. Never raises for a DB that is itself
    unavailable — the caller's warning is the observable signal then.
    """
    try:
        _begin_immediate(con)
        con.execute(
            "UPDATE presence_state SET valid = 0, empty_since_ms = NULL WHERE id = 1"
        )
        con.commit()
    except sqlite3.Error:
        try:
            con.rollback()
        except sqlite3.Error:
            pass


def _record_identities(
    con: sqlite3.Connection,
    players: list[dict[str, Any]],
    at_ms: int,
    grace_ms: int,
) -> int:
    """Fold one observation's list into identities and sessions.

    Moved verbatim from palworld-fps.record_presence (playtime semantics
    unchanged); runs inside the caller's fenced transaction so presence_state
    and identity/session updates commit coherently.
    """
    seen = 0
    for player in players:
        uid = str(player.get("playerId") or "").strip()
        # While a player is still loading in, the REST API lists them with the
        # placeholder playerId "None" (observed on v1.0.3; some builds report
        # all zeros instead) — a real sighting, but not an identity. Counting
        # it would fold every player's loading screen into one shared phantom
        # row, so skip it; their session starts once the real uid appears.
        if not uid or uid == "None" or uid.strip("0") == "":
            continue
        seen += 1
        name = str(player.get("name") or "")
        steam = str(player.get("userId") or "").strip() or None
        level = player.get("level")
        level = int(level) if isinstance(level, (int, float)) else None
        row = con.execute(
            "SELECT 1 FROM player_identity WHERE player_uid = ?", (uid,)
        ).fetchone()
        if row is None:
            con.execute(
                """
                INSERT INTO player_identity
                    (player_uid, steam_userid, name, level, first_seen_ms, last_seen_ms, total_play_ms)
                VALUES (?, ?, ?, ?, ?, ?, 0)
                """,
                (uid, steam, name, level, at_ms, at_ms),
            )
        else:
            # Names and levels track the latest sighting (players rename);
            # COALESCE keeps a known steam id / level over a missing one.
            con.execute(
                """
                UPDATE player_identity
                SET steam_userid = COALESCE(?, steam_userid), name = ?,
                    level = COALESCE(?, level), last_seen_ms = ?
                WHERE player_uid = ?
                """,
                (steam, name, level, at_ms, uid),
            )
        session = con.execute(
            """
            SELECT rowid, last_seen_ms FROM player_sessions
            WHERE player_uid = ? ORDER BY last_seen_ms DESC LIMIT 1
            """,
            (uid,),
        ).fetchone()
        if session is not None and 0 <= at_ms - int(session["last_seen_ms"]) <= grace_ms:
            delta = at_ms - int(session["last_seen_ms"])
            con.execute(
                "UPDATE player_sessions SET last_seen_ms = ?, samples = samples + 1 WHERE rowid = ?",
                (at_ms, session["rowid"]),
            )
            con.execute(
                "UPDATE player_identity SET total_play_ms = total_play_ms + ? WHERE player_uid = ?",
                (delta, uid),
            )
        else:
            con.execute(
                "INSERT INTO player_sessions (player_uid, started_at_ms, last_seen_ms, samples) VALUES (?, ?, ?, 1)",
                (uid, at_ms, at_ms),
            )
    return seen
