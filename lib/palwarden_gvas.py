# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
"""Read Palworld `.sav` files: the compressed container and the GVAS tree.

Written for the player-stats board (spec: docs/superpowers/specs/
2026-08-18-player-stats-board-design.md) against the wire format, with
palworld-save-tools 0.24.0 (MIT) as reference — see CREDITS.md. Two design
rules everything here follows:

1. **Codec dispatch is by magic.** `PlZ` is stdlib zlib; `PlM` (the game's
   default since ~0.6) is Oodle via `pyooz`, imported lazily and only on
   that path, so a machine without pyooz can still parse PlZ and gets a
   typed `ParserUnavailable` — never an ImportError — when it meets PlM.

2. **Per-field degradation.** The game's format drifts across patches; a
   reader that raises on novelty breaks the whole stats board on every game
   update. The property `size` field is a *logical* size (it excludes
   per-type headers such as the optional-guid flag), so a property cannot in
   general be skipped blind — but every container type (Struct/Array/Map/Set)
   reveals its exact value extent once its header is read. A parse failure
   inside a container is therefore recorded, the stream reseeks to the known
   end, and every sibling survives. Unknown property *types* are skipped via
   the common scalar convention (flag byte + `size` payload bytes) when the
   stream still looks sane afterwards, and otherwise degrade the enclosing
   container instead.

Values come back JSON-ready: scalars, strings, dicts (structs, maps keyed by
str), and lists. Errors are bounded "path: message" strings.
"""
from __future__ import annotations

import struct
import zlib

MAX_ERRORS = 64
MAX_ERROR_LEN = 160
# A save is player-authored data; strings beyond this are a misparse, not text.
MAX_FSTRING = 1 << 20


class SavError(Exception):
    """Base for everything this module raises deliberately."""


class SavCorrupt(SavError):
    """The container or GVAS header is torn/truncated/not a save."""


class ParserUnavailable(SavError):
    """An Oodle (PlM) save was met but pyooz is not installed."""


class _ParseError(Exception):
    """Internal: a property failed to parse; containment decides the blast radius."""


class _SkipProperty(Exception):
    """Internal: property recorded and stream already resynced; keep going."""


# --- container ---------------------------------------------------------------

def decompress_sav(data: bytes) -> bytes:
    """Container header: u32 ulen, u32 clen, 3-byte magic, u8 type."""
    if len(data) < 12:
        raise SavCorrupt("shorter than the 12-byte container header")
    ulen, clen = struct.unpack_from("<II", data)
    magic = data[8:11]
    save_type = data[11]
    payload = data[12:]
    if magic == b"PlZ":
        if save_type not in (0x01, 0x31, 0x32):
            raise SavCorrupt(f"unknown PlZ save type 0x{save_type:02x}")
        try:
            raw = zlib.decompress(payload)
        except zlib.error as exc:
            raise SavCorrupt(f"zlib: {exc}") from exc
        if save_type == 0x32:  # double-compressed
            if len(raw) != clen:
                raise SavCorrupt(
                    f"inner length {len(raw)} != compressed_len {clen}"
                )
            try:
                raw = zlib.decompress(raw)
            except zlib.error as exc:
                raise SavCorrupt(f"zlib (inner): {exc}") from exc
        elif len(payload) != clen:
            raise SavCorrupt(
                f"payload length {len(payload)} != compressed_len {clen}"
            )
    elif magic == b"PlM":
        if len(payload) != clen:
            raise SavCorrupt(
                f"payload length {len(payload)} != compressed_len {clen}"
            )
        raw = _oodle_decompress(payload, ulen)
    else:
        raise SavCorrupt(f"unknown save magic {magic!r}")
    if len(raw) != ulen:
        raise SavCorrupt(f"decompressed to {len(raw)} bytes, header says {ulen}")
    return raw


def _oodle_decompress(payload: bytes, ulen: int) -> bytes:
    try:
        # The PyPI package is `pyooz`, but the module it installs is `ooz`
        # (ooz.abi3.so). The one optional dependency; PlZ never gets here.
        import ooz
    except ImportError as exc:
        raise ParserUnavailable(
            "Oodle-compressed (PlM) save but pyooz is not installed — "
            "see docs/tools.md (palworld-player-stats) for the install step"
        ) from exc
    try:
        return ooz.decompress(payload, ulen)
    except Exception as exc:  # ooz raises RuntimeError on bad data
        raise SavCorrupt(f"oodle: {exc}") from exc


# --- GVAS --------------------------------------------------------------------

class _Reader:
    __slots__ = ("data", "pos")

    def __init__(self, data: bytes):
        self.data = data
        self.pos = 0

    def read(self, n: int) -> bytes:
        end = self.pos + n
        if n < 0 or end > len(self.data):
            raise _ParseError(f"eof reading {n} bytes at {self.pos}")
        b = self.data[self.pos:end]
        self.pos = end
        return b

    def u8(self) -> int:
        return self.read(1)[0]

    def i32(self) -> int:
        return struct.unpack("<i", self.read(4))[0]

    def u32(self) -> int:
        return struct.unpack("<I", self.read(4))[0]

    def i64(self) -> int:
        return struct.unpack("<q", self.read(8))[0]

    def u64(self) -> int:
        return struct.unpack("<Q", self.read(8))[0]

    def u16(self) -> int:
        return struct.unpack("<H", self.read(2))[0]

    def f32(self) -> float:
        return struct.unpack("<f", self.read(4))[0]

    def f64(self) -> float:
        return struct.unpack("<d", self.read(8))[0]

    def fstring(self) -> str:
        (n,) = struct.unpack("<i", self.read(4))
        if n == 0:
            return ""
        if n < 0:
            n = -n
            if n > MAX_FSTRING:
                raise _ParseError(f"implausible utf-16 string length {n}")
            return self.read(n * 2)[:-2].decode("utf-16-le", errors="replace")
        if n > MAX_FSTRING:
            raise _ParseError(f"implausible string length {n}")
        return self.read(n)[:-1].decode("ascii", errors="replace")

    def guid(self) -> str:
        b = self.read(16)
        # Unreal's on-disk GUID byte order, matching community tooling so the
        # strings line up with item 10's future ID->name tables.
        return "%08x-%04x-%04x-%04x-%04x%08x" % (
            (b[3] << 24) | (b[2] << 16) | (b[1] << 8) | b[0],
            (b[7] << 8) | b[6],
            (b[5] << 8) | b[4],
            (b[0xB] << 8) | b[0xA],
            (b[9] << 8) | b[8],
            (b[0xF] << 24) | (b[0xE] << 16) | (b[0xD] << 8) | b[0xC],
        )

    def optional_guid(self) -> None:
        if self.u8():
            self.read(16)


def _record(errors: list[str], path: str, msg: str) -> None:
    if len(errors) < MAX_ERRORS:
        errors.append(f"{path}: {msg}"[:MAX_ERROR_LEN])
    elif len(errors) == MAX_ERRORS:
        errors.append("... further errors suppressed")


def parse_sav(data: bytes) -> tuple[dict, list[str]]:
    """Container + GVAS. Returns (properties, errors)."""
    return parse_gvas(decompress_sav(data))


def parse_gvas(data: bytes) -> tuple[dict, list[str]]:
    r = _Reader(data)
    try:
        _read_header(r)
    except _ParseError as exc:
        raise SavCorrupt(f"GVAS header: {exc}") from exc
    errors: list[str] = []
    try:
        props = _properties(r, "", errors)
    except _ParseError as exc:
        # Root level has no containing extent to reseek to; keep the partial.
        props = {}
        _record(errors, "(root)", str(exc))
    return props, errors


def _read_header(r: _Reader) -> None:
    if r.i32() != 0x53415647:
        raise _ParseError("no GVAS magic")
    version = r.i32()
    if version != 3:
        raise _ParseError(f"unexpected save game version {version}")
    r.read(8)   # package file versions (UE4, UE5)
    r.read(10)  # engine major/minor/patch + changelist
    r.fstring()  # engine branch
    if r.i32() != 3:
        raise _ParseError("unexpected custom version format")
    count = r.u32()
    if count > 10000:
        raise _ParseError(f"implausible custom version count {count}")
    r.read(20 * count)  # (guid, i32) pairs
    r.fstring()  # save game class name


def _properties(r: _Reader, path: str, errors: list[str]) -> dict:
    out: dict = {}
    while True:
        name = r.fstring()
        if name == "None":
            return out
        if name == "":
            raise _ParseError("empty property name")
        type_name = r.fstring()
        size = r.u64()
        prop_path = f"{path}.{name}" if path else name
        try:
            out[name] = _property(r, type_name, size, prop_path, errors)
        except _SkipProperty:
            continue


def _property(r: _Reader, type_name: str, size: int, path: str, errors: list[str]):
    # Scalars: optional-guid flag, then the value (which `size` describes).
    if type_name == "IntProperty" or type_name == "FixedPoint64Property":
        r.optional_guid()
        return r.i32()
    if type_name == "Int64Property":
        r.optional_guid()
        return r.i64()
    if type_name == "UInt32Property":
        r.optional_guid()
        return r.u32()
    if type_name == "UInt16Property":
        r.optional_guid()
        return r.u16()
    if type_name == "FloatProperty":
        r.optional_guid()
        return r.f32()
    if type_name == "StrProperty" or type_name == "NameProperty":
        r.optional_guid()
        return r.fstring()
    if type_name == "BoolProperty":
        value = r.u8() > 0  # the oddball: value precedes the flag byte
        r.optional_guid()
        return value
    if type_name == "EnumProperty":
        r.fstring()  # enum type
        r.optional_guid()
        return r.fstring()
    if type_name == "ByteProperty":
        enum_type = r.fstring()
        r.optional_guid()
        return r.u8() if enum_type == "None" else r.fstring()

    # Containers: after the type-specific header, the value occupies exactly
    # `size` bytes — the containment boundary every failure reseeks to.
    if type_name == "StructProperty":
        struct_type = r.fstring()
        r.read(16)  # struct id
        r.optional_guid()
        return _contained(r, size, path, errors,
                          lambda: _struct_value(r, struct_type, path, errors))
    if type_name == "ArrayProperty":
        array_type = r.fstring()
        r.optional_guid()
        return _contained(r, size, path, errors,
                          lambda: _array_value(r, array_type, size, path, errors))
    if type_name == "MapProperty":
        key_type = r.fstring()
        value_type = r.fstring()
        r.optional_guid()
        return _contained(r, size, path, errors,
                          lambda: _map_value(r, key_type, value_type, path, errors))
    if type_name == "SetProperty":
        # Upstream lacks a working reader for this; layout verified against
        # production saves 2026-08-16: element-type fstring, optional-guid
        # flag byte, u32 removes, u32 count, then the elements (struct
        # elements are property lists, NOT raw guids).
        element_type = r.fstring()
        r.optional_guid()
        return _contained(r, size, path, errors,
                          lambda: _set_value(r, element_type, path, errors))

    # Unknown type: try the common scalar convention (flag byte + `size`
    # payload bytes); commit only if the stream still looks like a property
    # list afterwards. Otherwise degrade the enclosing container.
    start = r.pos
    try:
        r.optional_guid()
        r.read(size)
        plausible = _plausible_next(r)
    except _ParseError:
        plausible = False
    if plausible:
        _record(errors, path, f"skipped unknown property type {type_name}")
        raise _SkipProperty()
    r.pos = start
    raise _ParseError(f"unknown property type {type_name}")


def _contained(r: _Reader, size: int, path: str, errors: list[str], parse):
    """Run `parse`; on failure or extent mismatch, record + reseek + skip."""
    start = r.pos
    end = start + size
    if end > len(r.data):
        raise _ParseError(f"value extent {size} exceeds file")
    try:
        value = parse()
        if r.pos != end:
            raise _ParseError(f"value ended at {r.pos}, expected {end}")
        return value
    except _ParseError as exc:
        _record(errors, path, str(exc))
        r.pos = end
        raise _SkipProperty() from exc


def _struct_value(r: _Reader, struct_type: str, path: str, errors: list[str]):
    if struct_type == "Vector":
        return {"x": r.f64(), "y": r.f64(), "z": r.f64()}
    if struct_type == "Quat":
        return {"x": r.f64(), "y": r.f64(), "z": r.f64(), "w": r.f64()}
    if struct_type == "LinearColor":
        return {"r": r.f32(), "g": r.f32(), "b": r.f32(), "a": r.f32()}
    if struct_type == "DateTime":
        return r.u64()
    if struct_type == "Guid":
        return r.guid()
    return _properties(r, path, errors)


def _array_value(r: _Reader, array_type: str, size: int, path: str, errors: list[str]):
    count = r.u32()
    if array_type == "StructProperty":
        prop_name = r.fstring()
        r.fstring()  # prop type (StructProperty)
        r.u64()      # inner size
        type_name = r.fstring()
        r.read(16)   # struct id
        r.read(1)    # flag
        return [
            _struct_value(r, type_name, f"{path}.{prop_name}[{i}]", errors)
            for i in range(count)
        ]
    if array_type in ("NameProperty", "EnumProperty", "StrProperty"):
        return [r.fstring() for _ in range(count)]
    if array_type == "IntProperty":
        return [r.i32() for _ in range(count)]
    if array_type == "Int64Property":
        return [r.i64() for _ in range(count)]
    if array_type == "UInt32Property":
        return [r.u32() for _ in range(count)]
    if array_type == "FloatProperty":
        return [r.f32() for _ in range(count)]
    if array_type == "BoolProperty":
        return [r.u8() > 0 for _ in range(count)]
    if array_type == "ByteProperty":
        # A raw byte blob (count == remaining payload); keep it opaque.
        if size - 4 == count:
            r.read(count)
            return {"bytes": count}
        raise _ParseError("labelled ByteProperty array")
    if array_type == "Guid":
        return [r.guid() for _ in range(count)]
    raise _ParseError(f"unknown array element type {array_type}")


def _map_value(r: _Reader, key_type: str, value_type: str, path: str,
               errors: list[str]) -> dict:
    r.u32()  # removed-element count (always 0 in saves)
    count = r.u32()
    out: dict = {}
    for i in range(count):
        key = _element(r, key_type, "Guid", f"{path}.key[{i}]", errors)
        value = _element(r, value_type, None, f"{path}.value[{i}]", errors)
        out[str(key)] = value
    return out


def _set_value(r: _Reader, element_type: str, path: str, errors: list[str]) -> list:
    r.u32()  # removed-element count
    count = r.u32()
    return [
        _element(r, element_type, None, f"{path}[{i}]", errors)
        for i in range(count)
    ]


def _element(r: _Reader, type_name: str, struct_default: str | None, path: str,
             errors: list[str]):
    """A bare (header-less) element inside a map or set."""
    if type_name in ("NameProperty", "EnumProperty", "StrProperty"):
        return r.fstring()
    if type_name == "IntProperty":
        return r.i32()
    if type_name == "Int64Property":
        return r.i64()
    if type_name == "UInt32Property":
        return r.u32()
    if type_name == "FloatProperty":
        return r.f32()
    if type_name == "BoolProperty":
        return r.u8() > 0
    if type_name == "StructProperty":
        # No struct-type tag on the wire here. Map keys are guids in every
        # observed Palworld save; other struct elements are property lists.
        # A wrong guess misparses, the enclosing extent check catches it,
        # and the container degrades — never its siblings.
        if struct_default == "Guid":
            return r.guid()
        return _properties(r, path, errors)
    raise _ParseError(f"unknown element type {type_name}")


def _plausible_next(r: _Reader) -> bool:
    """Does the stream look like a property list from here? (Peek only.)"""
    save = r.pos
    try:
        name = r.fstring()
        if name == "None":
            return True
        if not (0 < len(name) <= 120) or not name.isprintable():
            return False
        type_name = r.fstring()
        return type_name.endswith("Property") and 0 < len(type_name) <= 64
    except _ParseError:
        return False
    finally:
        r.pos = save
