# Credits & inspiration

`palwarden` stands on the shoulders of other people's work. This project is
licensed under **AGPL-3.0** (see [`LICENSE`](LICENSE)); the components below keep
their own licenses, and this file records what came from where so nobody's work
is passed off as ours.

## Starting points / bundled components

### Palworld Config Parser Tool — inspiration (no longer bundled)
- **Upstream:** pelican-eggs/Palworld-Config-Parser-Tool (v1.0.23), **AGPL-3.0**
- **History:** we originally shipped the upstream *prebuilt binary* at
  `bin/palworld-config-parser`, wrapped by `sbin/palworld-config-apply-env`. It
  established the interface this project still uses: settings come from the
  environment, the live `PalWorldSettings.ini` is edited in place.
- **Now:** that binary has been **removed and replaced by our own Python
  implementation** at the same path, so the repo and image contain no opaque
  third-party executable. The reimplementation was written from the observable
  interface (env-var names, Palworld's own INI format) — not from upstream source —
  and resolves env names against the keys present in the live config rather than
  copying any mapping table. Credit to the upstream project for the idea and the
  interface; it is no longer a dependency.

### Palworld Dedicated Server Config Creator (web UI)
- **Upstream:** BlinkZer0/Palworld-Dedicated-Server-Config-Creator
- **License:** **MIT** — retained verbatim at
  [`webui/LICENSE.upstream-mit`](webui/LICENSE.upstream-mit)
  (© 2025 Palworld Dedicated Server Config Creator Contributors).
- **How we use it:** `webui/PalWorldSettingsEditor.html` is a **fork** of the
  upstream editor. It was vendored byte-identical for a while (to keep upstream
  syncs trivial); we deliberately gave that up (2026-08) after concluding we do
  not track upstream, and integrated the palwarden live control plane directly
  into the page instead — nav, Load Live Config, the changed-keys diff, and the
  `settings_save` / `settings_save_apply_restart` jobs, marked in the file
  header. The form, styling and the offline generate/copy workflow remain
  upstream's work under MIT; our additions are AGPL-3.0. MIT permits exactly
  this, and we keep their copyright + permission notice for the parts derived
  from their work.
- **Narrowed derivation:** `webui/EngineIniPerformanceEditor.html` was once
  described here as a companion to that editor. It is **first-party, AGPL-3.0**,
  and carries our SPDX header: the curated Engine.ini levers, the `engine.env`
  generation, and the control-plane integration (`palworld-engine-config`,
  `current/Engine.ini`, the Save / Save-and-apply jobs) have no upstream
  counterpart. What *is* derived from the MIT upstream is the page shell and the
  enable-checkbox-per-setting form idiom, which is why the file's header points
  back here and `webui/LICENSE.upstream-mit` still applies to that much.
- **Not derived:** `webui/palwarden.html` (the control-plane dashboard) is
  first-party, AGPL-3.0, written from scratch.

### palworld-save-tools — format reference (not bundled)
- **Upstream:** cheahjs/palworld-save-tools (v0.24.0), **MIT**
- **How we use it:** `lib/palwarden_gvas.py` is **first-party AGPL-3.0 code**
  written against the GVAS wire format, with upstream as the reference for the
  on-disk encodings (property headers, fstrings, the container layout). No
  upstream code is vendored or imported; upstream also cannot read the `PlM`
  (Oodle) containers current game versions write, which is half of why the
  reader exists. Credit to the upstream project for mapping the format first.

### pyooz / ooz — optional Oodle decompression
- **Upstream:** zao/pyooz (PyPI `pyooz`, installs a module named `ooz`),
  wrapping powzix/ooz — both **GPL-3.0-or-later** (pyooz via its trove
  classifier; ooz via per-file license headers).
- **How we use it:** an **optional, runtime-only** dependency of
  `palworld-player-stats`: the game Oodle-compresses saves (`PlM` magic) since
  ~0.6, and ooz is the only open-source decoder. Never bundled in the repo or
  the deb; the Docker image pip-installs it behind `WITH_PLAYER_STATS=true`,
  bare metal installs it by hand, and everything degrades gracefully without
  it. GPLv3+ combines cleanly with our AGPL-3.0-or-later.
- **Provenance caveat, recorded honestly:** ooz is a reverse-engineering of
  RAD/Epic's proprietary Oodle codec. Its author licensed their code GPLv3+,
  the code is widely redistributed across game-tooling communities, and no
  dispute is known — but that history is worth knowing, and it is why the
  dependency is optional and decompression-only.

## Trademark

Palworld is a trademark of Pocketpair, Inc. `palwarden` is an unofficial,
community tool and is not affiliated with, endorsed by, or connected to
Pocketpair.

---

*Building on someone's tool here doesn't imply they endorse this project. If you
maintain one of the upstreams and want the attribution changed, open an issue.*
