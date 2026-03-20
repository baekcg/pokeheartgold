#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import subprocess
import tempfile
import zlib
from pathlib import Path
from typing import Any


SSTATE_HEADER = b"DeSmuME SState"
SSTATE_PAYLOAD_OFFSET = 0x20
DEFAULT_ARM9_ANCHOR = 0xC6A0
DEFAULT_LUA_SCRIPT = Path("analysis/scripts/desmume_battle_state_detector.lua")
DEFAULT_HARNESS_SCRIPT = Path("analysis/scripts/desmume_lua_savestate_harness.lua")
DEFAULT_STATE_PATH = Path("runtime/desmume/state.json")
DEFAULT_COMMAND_PATH = Path("runtime/desmume/command.json")


def parse_int(value: str) -> int:
    return int(value, 0)


def decompress_savestate(path: Path) -> bytes:
    raw = path.read_bytes()
    if not raw.startswith(SSTATE_HEADER):
        raise ValueError(f"{path} is not a DeSmuME SState file")
    return zlib.decompress(raw[SSTATE_PAYLOAD_OFFSET:])


def parse_schedule_entry(raw: str) -> tuple[int, int, int]:
    frame_s, addr_s, value_s = raw.split(":", 2)
    return int(frame_s, 0), int(addr_s, 0), int(value_s, 0)


def write_schedule_file(path: Path, entries: list[tuple[int, int, int]]) -> None:
    lines = [f"{frame} 0x{addr:08X} 0x{value:08X}" for frame, addr, value in entries]
    path.write_text("\n".join(lines) + ("\n" if lines else ""))


def parse_harness_output(stdout: str) -> dict[str, Any]:
    stats: dict[str, Any] = {
        "writes": [],
    }
    for line in stdout.splitlines():
        if line.startswith("HARNESS_FRAMES="):
            stats["frames"] = int(line.split("=", 1)[1])
        elif line.startswith("HARNESS_JOYPAD_CALLS="):
            stats["joypad_calls"] = int(line.split("=", 1)[1])
        elif line.startswith("HARNESS_LAST_BUTTONS="):
            raw_buttons = line.split("=", 1)[1]
            stats["last_buttons"] = [item for item in raw_buttons.split(",") if item]
        elif line.startswith("HARNESS_SAVESTATE_SLOTS="):
            raw_slots = line.split("=", 1)[1]
            stats["savestate_slots"] = [int(item) for item in raw_slots.split(",") if item]
        elif line.startswith("HARNESS_WRITE="):
            stats["writes"].append(line.split("=", 1)[1])
    stats["stdout"] = stdout.splitlines()
    return stats


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Run the DeSmuME Lua bridge against a static savestate with mocked emulator APIs."
    )
    parser.add_argument("--savestate", type=Path, required=True)
    parser.add_argument("--frames", type=int, default=1)
    parser.add_argument("--arm9-anchor", type=parse_int, default=DEFAULT_ARM9_ANCHOR)
    parser.add_argument("--lua-script", type=Path, default=DEFAULT_LUA_SCRIPT)
    parser.add_argument("--harness-script", type=Path, default=DEFAULT_HARNESS_SCRIPT)
    parser.add_argument("--state-path", type=Path, default=DEFAULT_STATE_PATH)
    parser.add_argument("--command-path", type=Path, default=DEFAULT_COMMAND_PATH)
    parser.add_argument(
        "--schedule",
        action="append",
        default=[],
        help="Apply a u32 write at a frame as frame:addr:value, numbers in decimal or 0x-prefixed hex.",
    )
    parser.add_argument(
        "--clear-bridge",
        action="store_true",
        help="Remove existing state.json and command.json before running.",
    )
    parser.add_argument(
        "--print-json",
        action="store_true",
        help="Print a JSON summary containing the final state snapshot and harness stats.",
    )
    return parser


def main() -> int:
    args = build_parser().parse_args()

    if args.clear_bridge:
        for path in (args.state_path, args.command_path):
            if path.exists():
                path.unlink()

    decompressed = decompress_savestate(args.savestate)
    schedule_entries = [parse_schedule_entry(entry) for entry in args.schedule]

    with tempfile.TemporaryDirectory() as tmpdir:
        tmpdir_path = Path(tmpdir)
        raw_state_path = tmpdir_path / "savestate.raw.bin"
        schedule_path = tmpdir_path / "schedule.txt"
        raw_state_path.write_bytes(decompressed)
        write_schedule_file(schedule_path, schedule_entries)

        proc = subprocess.run(
            [
                "lua",
                str(args.harness_script),
                str(args.lua_script),
                str(raw_state_path),
                str(args.arm9_anchor),
                str(args.frames),
                str(schedule_path),
            ],
            capture_output=True,
            text=True,
            check=False,
        )

    if proc.returncode != 0:
        raise SystemExit(proc.stderr or proc.stdout)

    state_payload = None
    if args.state_path.exists():
        state_payload = json.loads(args.state_path.read_text())

    summary = {
        "state": state_payload,
        "stats": parse_harness_output(proc.stdout),
    }

    if args.print_json:
        print(json.dumps(summary, indent=2, sort_keys=True))
    else:
        if state_payload is not None:
            print(
                f"session={state_payload.get('session_id')} "
                f"phase={state_payload.get('phase')} "
                f"last_command_status={state_payload.get('last_command_status')}"
            )
        else:
            print("state.json was not produced")
        print(proc.stdout, end="" if proc.stdout.endswith("\n") else "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
