#!/usr/bin/env python3

import argparse
import struct
import zlib
from pathlib import Path


SSTATE_HEADER = b"DeSmuME SState"
SSTATE_PAYLOAD_OFFSET = 0x20
ARM9_RAM_BASE = 0x02000000

SIZE_BATTLEMON = 0xC0
OFF_SPECIES = 0x00
OFF_MOVES = 0x0C
OFF_STAT_CHANGES = 0x18
OFF_ABILITY = 0x27
OFF_MOVE_PP_CUR = 0x2C
OFF_LEVEL = 0x34
OFF_HP = 0x4C
OFF_MAX_HP = 0x50
OFF_EXP = 0x64
OFF_STATUS = 0x6C
OFF_STATUS2 = 0x70
OFF_ITEM = 0x78
OFF_MOVE_EFFECT_FLAGS = 0x80


def read_u16(buf: bytes, off: int) -> int:
    return struct.unpack_from("<H", buf, off)[0]


def read_u32(buf: bytes, off: int) -> int:
    return struct.unpack_from("<I", buf, off)[0]


def read_s32(buf: bytes, off: int) -> int:
    return struct.unpack_from("<i", buf, off)[0]


def read_moves(buf: bytes, off: int) -> tuple[int, int, int, int]:
    return struct.unpack_from("<4H", buf, off + OFF_MOVES)


def read_stat_changes(buf: bytes, off: int) -> list[int]:
    return list(struct.unpack_from("<8b", buf, off + OFF_STAT_CHANGES))


def load_savestate(path: Path) -> bytes:
    raw = path.read_bytes()
    if not raw.startswith(SSTATE_HEADER):
        raise ValueError(f"{path} is not a DeSmuME SState file")
    return zlib.decompress(raw[SSTATE_PAYLOAD_OFFSET:])


def read_arm9_head(rom: bytes) -> bytes:
    arm9_rom_offset = read_u32(rom, 0x20)
    return rom[arm9_rom_offset:arm9_rom_offset + 0x40]


def find_arm9_anchor(state: bytes, rom: bytes) -> int:
    needle = read_arm9_head(rom)
    idx = state.find(needle)
    if idx == -1:
        raise ValueError("Could not locate ARM9 memory inside the savestate")
    return idx


def live_addr(arm9_anchor: int, file_off: int) -> int:
    return ARM9_RAM_BASE + (file_off - arm9_anchor)


def iter_candidates(state: bytes):
    limit = len(state) - SIZE_BATTLEMON
    for off in range(limit):
        yield {
            "file_off": off,
            "species": read_u16(state, off + OFF_SPECIES),
            "moves": read_moves(state, off),
            "stat_changes": read_stat_changes(state, off),
            "ability": state[off + OFF_ABILITY],
            "move_pp_cur": list(state[off + OFF_MOVE_PP_CUR:off + OFF_MOVE_PP_CUR + 4]),
            "level": state[off + OFF_LEVEL],
            "hp": read_s32(state, off + OFF_HP),
            "max_hp": read_u32(state, off + OFF_MAX_HP),
            "exp": read_u32(state, off + OFF_EXP),
            "status": read_u32(state, off + OFF_STATUS),
            "status2": read_u32(state, off + OFF_STATUS2),
            "item": read_u16(state, off + OFF_ITEM),
            "move_effect_flags": read_u32(state, off + OFF_MOVE_EFFECT_FLAGS),
        }


def matches(args, cand) -> bool:
    if args.species is not None and cand["species"] != args.species:
        return False
    if args.level is not None and cand["level"] != args.level:
        return False
    if args.hp is not None and cand["hp"] != args.hp:
        return False
    if args.max_hp is not None and cand["max_hp"] != args.max_hp:
        return False
    if args.status is not None and cand["status"] != args.status:
        return False
    if args.status2 is not None and cand["status2"] != args.status2:
        return False
    if args.move:
        want = tuple(args.move) + (0,) * (4 - len(args.move))
        if cand["moves"][:len(args.move)] != want[:len(args.move)]:
            return False
    return True


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Locate BattleMon structures in a DeSmuME savestate."
    )
    parser.add_argument("savestate", type=Path)
    parser.add_argument("rom", type=Path)
    parser.add_argument("--species", type=int)
    parser.add_argument("--level", type=int)
    parser.add_argument("--hp", type=int)
    parser.add_argument("--max-hp", type=int)
    parser.add_argument("--status", type=int)
    parser.add_argument("--status2", type=int)
    parser.add_argument(
        "--move",
        type=int,
        action="append",
        default=[],
        help="Required move ID in slot order; pass multiple times",
    )
    parser.add_argument("--limit", type=int, default=20)
    args = parser.parse_args()

    state = load_savestate(args.savestate)
    rom = args.rom.read_bytes()
    arm9_anchor = find_arm9_anchor(state, rom)

    print(f"savestate={args.savestate}")
    print(f"rom={args.rom}")
    print(f"decompressed_size=0x{len(state):x}")
    print(f"arm9_anchor_file_offset=0x{arm9_anchor:x}")
    print(f"arm9_ram_base=0x{ARM9_RAM_BASE:08x}")

    count = 0
    for cand in iter_candidates(state):
        if not matches(args, cand):
            continue
        count += 1
        file_off = cand["file_off"]
        addr = live_addr(arm9_anchor, file_off)
        print("")
        print(f"candidate_{count}:")
        print(f"  file_off=0x{file_off:x}")
        print(f"  live_addr=0x{addr:08x}")
        print(f"  species={cand['species']}")
        print(f"  moves={cand['moves']}")
        print(f"  stat_changes={cand['stat_changes']}")
        print(f"  ability={cand['ability']}")
        print(f"  move_pp_cur={cand['move_pp_cur']}")
        print(f"  level={cand['level']}")
        print(f"  hp={cand['hp']}")
        print(f"  max_hp={cand['max_hp']}")
        print(f"  exp={cand['exp']}")
        print(f"  status={cand['status']}")
        print(f"  status2={cand['status2']}")
        print(f"  item={cand['item']}")
        print(f"  move_effect_flags={cand['move_effect_flags']}")
        if count >= args.limit:
            break

    print("")
    print(f"match_count={count}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
