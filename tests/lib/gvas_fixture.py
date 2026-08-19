# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
"""Synthetic Palworld player-save fixtures for the GVAS reader tests.

Builds `.sav` bytes in the game's on-disk shape — the 12-byte compressed
container around a GVAS property tree — using stdlib zlib and the `PlZ`
magic, which the game itself still accepts, so no Oodle codec is needed
anywhere in the test suite. The wire encodings mirror what the game writes
(reference: palworld-save-tools 0.24.0, MIT — see CREDITS.md); the property
`size` field is the *logical* size (it excludes per-type headers such as the
optional-guid flag byte), exactly like Unreal's.
"""
from __future__ import annotations

import struct
import zlib


def fstring(s: str) -> bytes:
    if s == "":
        return struct.pack("<i", 0)
    if s.isascii():
        b = s.encode("ascii")
        return struct.pack("<i", len(b) + 1) + b + b"\x00"
    b = s.encode("utf-16-le")
    return struct.pack("<i", -(len(b) // 2 + 1)) + b + b"\x00\x00"


def _u32(v: int) -> bytes:
    return struct.pack("<I", v)


def _i32(v: int) -> bytes:
    return struct.pack("<i", v)


def _u64(v: int) -> bytes:
    return struct.pack("<Q", v)


def prop(name: str, type_name: str, size: int, payload: bytes) -> bytes:
    """One encoded property: name, type, logical size, payload (with headers)."""
    return fstring(name) + fstring(type_name) + _u64(size) + payload


def int_prop(name: str, value: int) -> bytes:
    return prop(name, "IntProperty", 4, b"\x00" + _i32(value))


def int64_prop(name: str, value: int) -> bytes:
    return prop(name, "Int64Property", 8, b"\x00" + struct.pack("<q", value))


def bool_prop(name: str, value: bool) -> bytes:
    # Bool is the oddball: value byte comes BEFORE the optional-guid flag.
    return prop(name, "BoolProperty", 0, (b"\x01" if value else b"\x00") + b"\x00")


def float_prop(name: str, value: float) -> bytes:
    return prop(name, "FloatProperty", 4, b"\x00" + struct.pack("<f", value))


def str_prop(name: str, value: str, type_name: str = "StrProperty") -> bytes:
    f = fstring(value)
    return prop(name, type_name, len(f), b"\x00" + f)


def name_prop(name: str, value: str) -> bytes:
    return str_prop(name, value, "NameProperty")


def enum_prop(name: str, enum_type: str, value: str) -> bytes:
    f = fstring(value)
    return prop(name, "EnumProperty", len(f), fstring(enum_type) + b"\x00" + f)


def _prop_value(type_name: str, value) -> bytes:
    if type_name in ("NameProperty", "EnumProperty", "StrProperty"):
        return fstring(value)
    if type_name == "IntProperty":
        return _i32(value)
    if type_name == "BoolProperty":
        return b"\x01" if value else b"\x00"
    raise ValueError(f"fixture cannot encode map element type {type_name}")


def map_prop(name: str, key_type: str, value_type: str, entries) -> bytes:
    """MapProperty; `entries` is a list of (key, value) pairs."""
    body = _u32(0) + _u32(len(entries))
    for k, v in entries:
        body += _prop_value(key_type, k) + _prop_value(value_type, v)
    payload = fstring(key_type) + fstring(value_type) + b"\x00" + body
    return prop(name, "MapProperty", len(body), payload)


def concat(*encoded: bytes) -> bytes:
    return b"".join(encoded)


def property_list(*encoded: bytes) -> bytes:
    """A struct value: concatenated properties terminated by 'None'."""
    return b"".join(encoded) + fstring("None")


def struct_prop(name: str, struct_type: str, value: bytes) -> bytes:
    """StructProperty whose value bytes are already encoded (see property_list)."""
    payload = fstring(struct_type) + b"\x00" * 16 + b"\x00" + value
    return prop(name, "StructProperty", len(value), payload)


def raw_prop(name: str, type_name: str, size: int, payload: bytes) -> bytes:
    """An arbitrary (e.g. unknown-typed) property, for degradation tests."""
    return prop(name, type_name, size, payload)


def gvas_header(save_class: str = "/Script/Pal.PalWorldPlayerSaveGame") -> bytes:
    return b"".join(
        [
            _i32(0x53415647),  # 'GVAS'
            _i32(3),  # SaveGameFileVersion
            _i32(522),  # PackageFileUEVersion (UE4)
            _i32(1008),  # PackageFileUEVersion (UE5)
            struct.pack("<HHH", 5, 1, 1),  # engine major/minor/patch
            _u32(0),  # engine changelist
            fstring("main"),  # engine branch
            _i32(3),  # CustomVersionFormat
            _u32(0),  # no custom versions
            fstring(save_class),
        ]
    )


def build_gvas(*top_props: bytes) -> bytes:
    return gvas_header() + b"".join(top_props) + fstring("None") + b"\x00" * 4


def wrap_sav(
    gvas: bytes,
    magic: bytes = b"PlZ",
    type_byte: int = 1,
    ulen: int | None = None,
    clen: int | None = None,
) -> bytes:
    """The 12-byte container. Pass ulen/clen to lie (torn-read fixtures)."""
    comp = zlib.compress(gvas)
    if ulen is None:
        ulen = len(gvas)
    if clen is None:
        clen = len(comp)
    return struct.pack("<II", ulen, clen) + magic + bytes([type_byte]) + comp


def player_sav(record_props: bytes = b"", extra_savedata: bytes = b"") -> bytes:
    """A minimal player .sav: SaveData struct holding a RecordData struct."""
    record = struct_prop(
        "RecordData",
        "PalLoggedinPlayerSaveDataRecordData",
        property_list(record_props),
    )
    save_data = struct_prop(
        "SaveData",
        "PalPlayerDataSaveData",
        property_list(extra_savedata, record),
    )
    return wrap_sav(build_gvas(save_data))
