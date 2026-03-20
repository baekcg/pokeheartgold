#!/usr/bin/env python3

from __future__ import annotations

import argparse
import functools
import json
import re
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any


SCHEMA_VERSION = 1
DEFAULT_STATE_PATH = Path("runtime/desmume/state.json")
DEFAULT_COMMAND_PATH = Path("runtime/desmume/command.json")
REPO_ROOT = Path(__file__).resolve().parents[2]
SPECIES_HEADER_PATH = REPO_ROOT / "include/constants/species.h"
ITEMS_HEADER_PATH = REPO_ROOT / "include/constants/items.h"
ABILITIES_HEADER_PATH = REPO_ROOT / "include/constants/abilities.h"
MOVES_HEADER_PATH = REPO_ROOT / "include/constants/moves.h"
DEFINE_RE = re.compile(r"^#define\s+([A-Z0-9_]+)\s+((?:0x)?[0-9A-Fa-f]+)\b")
VALID_BUTTONS = {
    "A",
    "B",
    "X",
    "Y",
    "L",
    "R",
    "Start",
    "Select",
    "Up",
    "Down",
    "Left",
    "Right",
    "Touch",
    "Debug",
    "Lid",
    "Reset",
}

NAME_OVERRIDES = {
    "FARFETCHD": "Farfetch'd",
    "HO_OH": "Ho-Oh",
    "MR_MIME": "Mr. Mime",
    "NIDORAN_F": "Nidoran F",
    "NIDORAN_M": "Nidoran M",
    "PORYGON_Z": "Porygon-Z",
}

STATUS_LABELS = {
    "healthy": "Healthy",
    "sleep": "Sleep",
    "poison": "Poison",
    "bad_poison": "Bad Poison",
    "burn": "Burn",
    "freeze": "Freeze",
    "paralysis": "Paralysis",
}

STAT_STAGE_DISPLAY_ORDER = (
    ("attack", "Atk"),
    ("defense", "Def"),
    ("speed", "Spe"),
    ("special_attack", "SpA"),
    ("special_defense", "SpD"),
    ("accuracy", "Acc"),
    ("evasion", "Eva"),
)


@dataclass(frozen=True)
class BattlerState:
    battler_id: int | None
    role: str | None
    present: bool
    species: int
    level: int
    hp: int
    max_hp: int
    status: int
    status2: int
    item: int
    ability: int
    friendship: int
    weight: int
    move_effect_flags: int
    primary_status: str
    status_flags: tuple[str, ...]
    stat_changes: tuple[int, ...]
    stat_stages: dict[str, int]
    boosted_stats: tuple[str, ...]
    lowered_stats: tuple[str, ...]
    has_stat_boosts: bool
    has_stat_drops: bool
    moves: tuple[int, int, int, int]
    pp: tuple[int, int, int, int]

    @classmethod
    def from_json(cls, payload: dict[str, Any] | None) -> "BattlerState | None":
        if payload is None:
            return None
        return cls(
            battler_id=int(payload["battler_id"])
            if payload.get("battler_id") is not None
            else None,
            role=str(payload["role"]) if payload.get("role") is not None else None,
            present=bool(payload.get("present", int(payload.get("species", 0)) != 0)),
            species=int(payload["species"]),
            level=int(payload["level"]),
            hp=int(payload["hp"]),
            max_hp=int(payload["max_hp"]),
            status=int(payload["status"]),
            status2=int(payload["status2"]),
            item=int(payload["item"]),
            ability=int(payload["ability"]),
            friendship=int(payload["friendship"]),
            weight=int(payload["weight"]),
            move_effect_flags=int(payload["move_effect_flags"]),
            primary_status=str(payload.get("primary_status", "healthy")),
            status_flags=tuple(str(v) for v in payload.get("status_flags", [])),
            stat_changes=tuple(int(v) for v in payload.get("stat_changes", [])),
            stat_stages={
                str(key): int(value)
                for key, value in (payload.get("stat_stages") or {}).items()
            },
            boosted_stats=tuple(str(v) for v in payload.get("boosted_stats", [])),
            lowered_stats=tuple(str(v) for v in payload.get("lowered_stats", [])),
            has_stat_boosts=bool(payload.get("has_stat_boosts", False)),
            has_stat_drops=bool(payload.get("has_stat_drops", False)),
            moves=tuple(int(v) for v in payload["moves"]),
            pp=tuple(int(v) for v in payload["pp"]),
        )


@dataclass(frozen=True)
class BattleState:
    frame: int
    session_id: str | None
    in_battle: bool
    ctx: int | None
    phase: str
    battle_status: int | None
    battle_status2: int | None
    damage: int | None
    hit_damage: int | None
    battlers_on_field: int | None
    battlers: tuple["BattlerState | None", ...]
    player: BattlerState | None
    enemy: BattlerState | None
    player_partner: BattlerState | None
    enemy_partner: BattlerState | None
    capabilities: dict[str, bool]
    last_command_id: str | None
    last_command_status: str | None
    last_command_error: str | None
    raw: dict[str, Any] | None

    @classmethod
    def from_json(cls, payload: dict[str, Any]) -> "BattleState":
        if int(payload["schema_version"]) != SCHEMA_VERSION:
            raise ValueError(
                f"Unsupported schema version {payload['schema_version']} (expected {SCHEMA_VERSION})"
            )
        battlers_payload = payload.get("battlers")
        if isinstance(battlers_payload, list):
            battlers = tuple(BattlerState.from_json(entry) for entry in battlers_payload)
        else:
            battlers = (
                BattlerState.from_json(payload.get("player")),
                BattlerState.from_json(payload.get("enemy")),
                BattlerState.from_json(payload.get("player_partner")),
                BattlerState.from_json(payload.get("enemy_partner")),
            )
        return cls(
            frame=int(payload["frame"]),
            session_id=payload.get("session_id"),
            in_battle=bool(payload["in_battle"]),
            ctx=int(payload["ctx"]) if payload.get("ctx") is not None else None,
            phase=str(payload["phase"]),
            battle_status=int(payload["battle_status"])
            if payload.get("battle_status") is not None
            else None,
            battle_status2=int(payload["battle_status2"])
            if payload.get("battle_status2") is not None
            else None,
            damage=int(payload["damage"]) if payload.get("damage") is not None else None,
            hit_damage=int(payload["hit_damage"])
            if payload.get("hit_damage") is not None
            else None,
            battlers_on_field=int(payload["battlers_on_field"])
            if payload.get("battlers_on_field") is not None
            else None,
            battlers=battlers,
            player=BattlerState.from_json(payload.get("player")),
            enemy=BattlerState.from_json(payload.get("enemy")),
            player_partner=BattlerState.from_json(payload.get("player_partner")),
            enemy_partner=BattlerState.from_json(payload.get("enemy_partner")),
            capabilities={
                str(key): bool(value) for key, value in payload["capabilities"].items()
            },
            last_command_id=payload.get("last_command_id"),
            last_command_status=payload.get("last_command_status"),
            last_command_error=payload.get("last_command_error"),
            raw=payload.get("raw"),
        )


@dataclass(frozen=True)
class BattleCommand:
    command_id: str
    for_session_id: str
    action: str
    expected_phase: str | None = None
    move_id: int | None = None
    target_battler: int | None = None
    buttons: tuple[str, ...] | None = None
    hold_frames: int | None = None
    slot: int | None = None

    def to_json(self) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "schema_version": SCHEMA_VERSION,
            "command_id": self.command_id,
            "for_session_id": self.for_session_id,
            "action": self.action,
        }
        if self.expected_phase is not None:
            payload["expected_phase"] = self.expected_phase
        if self.move_id is not None:
            payload["move_id"] = self.move_id
        if self.target_battler is not None:
            payload["target_battler"] = self.target_battler
        if self.buttons is not None:
            payload["buttons"] = list(self.buttons)
        if self.hold_frames is not None:
            payload["hold_frames"] = self.hold_frames
        if self.slot is not None:
            payload["slot"] = self.slot
        return payload


def load_state(path: Path) -> BattleState:
    payload = json.loads(path.read_text())
    if not isinstance(payload, dict):
        raise ValueError("state.json root must be an object")
    return BattleState.from_json(payload)


@functools.lru_cache(maxsize=None)
def load_constant_lookup(path: Path, prefix: str) -> dict[int, str]:
    mapping: dict[int, str] = {}
    for line in path.read_text().splitlines():
        match = DEFINE_RE.match(line.strip())
        if match is None:
            continue
        symbol = match.group(1)
        if not symbol.startswith(prefix):
            continue
        value = int(match.group(2), 0)
        if value not in mapping:
            mapping[value] = symbol
    return mapping


def format_constant_name(raw_name: str | None, prefix: str) -> str | None:
    if raw_name is None or not raw_name.startswith(prefix):
        return None
    stem = raw_name[len(prefix) :]
    if stem in NAME_OVERRIDES:
        return NAME_OVERRIDES[stem]
    return stem.replace("_", " ").title()


def resolve_symbol(value: int, path: Path, prefix: str) -> str | None:
    return load_constant_lookup(path, prefix).get(value)


def resolve_name(value: int, path: Path, prefix: str) -> str | None:
    return format_constant_name(resolve_symbol(value, path, prefix), prefix)


def resolve_species_name(species: int) -> str | None:
    return resolve_name(species, SPECIES_HEADER_PATH, "SPECIES_")


def resolve_item_name(item: int) -> str | None:
    return resolve_name(item, ITEMS_HEADER_PATH, "ITEM_")


def resolve_ability_name(ability: int) -> str | None:
    return resolve_name(ability, ABILITIES_HEADER_PATH, "ABILITY_")


def resolve_move_name(move_id: int) -> str | None:
    return resolve_name(move_id, MOVES_HEADER_PATH, "MOVE_")


def describe_status(primary_status: str, status_flags: tuple[str, ...]) -> str:
    if primary_status in STATUS_LABELS:
        return STATUS_LABELS[primary_status]
    if status_flags:
        return ", ".join(STATUS_LABELS.get(flag, flag.replace("_", " ")) for flag in status_flags)
    return "Unknown"


def atomic_write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = path.with_suffix(path.suffix + ".tmp")
    tmp_path.write_text(json.dumps(payload, ensure_ascii=True, sort_keys=True) + "\n")
    tmp_path.replace(path)


def make_command_id(action: str, state: BattleState, suffix: str) -> str:
    if state.session_id is None:
        raise ValueError("Cannot build a command without an active session_id")
    return f"{action}:{state.session_id}:{state.frame}:{suffix}"


def build_select_move_command(
    state: BattleState, move_id: int, target_battler: int | None, expected_phase: str | None
) -> BattleCommand:
    return BattleCommand(
        command_id=make_command_id(
            "select_move",
            state,
            f"move{move_id}-target{target_battler if target_battler is not None else 'none'}",
        ),
        for_session_id=state.session_id or "",
        action="select_move",
        expected_phase=expected_phase,
        move_id=move_id,
        target_battler=target_battler,
    )


def build_press_buttons_command(
    state: BattleState, buttons: list[str], hold_frames: int, expected_phase: str | None
) -> BattleCommand:
    button_suffix = "-".join(buttons)
    return BattleCommand(
        command_id=make_command_id("press_buttons", state, f"{button_suffix}-{hold_frames}"),
        for_session_id=state.session_id or "",
        action="press_buttons",
        expected_phase=expected_phase,
        buttons=tuple(buttons),
        hold_frames=hold_frames,
    )


def build_save_state_command(
    state: BattleState, slot: int, expected_phase: str | None
) -> BattleCommand:
    return BattleCommand(
        command_id=make_command_id("save_state", state, f"slot{slot}"),
        for_session_id=state.session_id or "",
        action="save_state",
        expected_phase=expected_phase,
        slot=slot,
    )


def wait_for_state(
    state_path: Path,
    *,
    watch: bool,
    poll_seconds: float,
    timeout_seconds: float | None,
    expected_phase: str | None,
) -> BattleState:
    deadline = None if timeout_seconds is None else time.monotonic() + timeout_seconds
    while True:
        try:
            state = load_state(state_path)
        except FileNotFoundError:
            if not watch:
                raise
        except json.JSONDecodeError:
            if not watch:
                raise
        else:
            if not state.in_battle:
                if not watch:
                    raise RuntimeError("No active battle in state.json")
            elif state.session_id is None:
                if not watch:
                    raise RuntimeError("Active battle is missing session_id")
            elif expected_phase is None or state.phase == expected_phase:
                return state

        if not watch:
            raise RuntimeError("Requested state is not ready")
        if deadline is not None and time.monotonic() >= deadline:
            raise TimeoutError("Timed out waiting for matching battle state")
        time.sleep(poll_seconds)


def parse_buttons(raw_buttons: str) -> list[str]:
    buttons = [part.strip() for part in raw_buttons.split(",") if part.strip()]
    if not buttons:
        raise ValueError("At least one button must be provided")
    unsupported = [button for button in buttons if button not in VALID_BUTTONS]
    if unsupported:
        supported = ", ".join(sorted(VALID_BUTTONS))
        raise ValueError(
            f"Unsupported button(s): {', '.join(unsupported)}. Supported buttons: {supported}"
        )
    return buttons


def print_state(state: BattleState, output_format: str) -> None:
    if output_format == "summary":
        print(format_state_summary(state))
        return
    print(json.dumps(state_to_json(state), ensure_ascii=False, indent=2, sort_keys=True))


def format_stat_stage_summary(battler: BattlerState) -> str:
    changes = []
    for key, label in STAT_STAGE_DISPLAY_ORDER:
        delta = battler.stat_stages.get(key, 0)
        if delta > 0:
            changes.append(f"{label}+{delta}")
        elif delta < 0:
            changes.append(f"{label}{delta}")
    if changes:
        return ", ".join(changes)
    return "neutral"


def format_battler_summary(battler: BattlerState | None) -> str:
    if battler is None:
        return "empty"
    role = battler.role or f"battler_{battler.battler_id}"
    if not battler.present:
        return f"[{battler.battler_id}] {role}: empty"

    species_name = resolve_species_name(battler.species) or f"Species {battler.species}"
    item_name = resolve_item_name(battler.item) or str(battler.item)
    ability_name = resolve_ability_name(battler.ability) or str(battler.ability)
    status_name = describe_status(battler.primary_status, battler.status_flags)
    return (
        f"[{battler.battler_id}] {role}: {species_name} "
        f"Lv{battler.level} HP {battler.hp}/{battler.max_hp} "
        f"status={status_name} item={item_name} ability={ability_name} "
        f"stages={format_stat_stage_summary(battler)}"
    )


def format_state_summary(state: BattleState) -> str:
    if not state.in_battle:
        return (
            f"frame={state.frame} phase={state.phase} in_battle={state.in_battle} "
            f"last_command_status={state.last_command_status}"
        )

    lines = [
        (
            f"session={state.session_id} frame={state.frame} phase={state.phase} "
            f"ctx={hex(state.ctx) if state.ctx is not None else 'none'} "
            f"battlers_on_field={state.battlers_on_field} "
            f"last_command_status={state.last_command_status}"
        )
    ]
    for battler_id, battler in enumerate(state.battlers):
        if battler is None:
            lines.append(f"[{battler_id}] empty")
            continue
        lines.append(format_battler_summary(battler))
    return "\n".join(lines)


def state_to_json(state: BattleState) -> dict[str, Any]:
    def battler_to_json(battler: BattlerState | None) -> dict[str, Any] | None:
        if battler is None:
            return None
        move_slots = []
        for idx, move_id in enumerate(battler.moves):
            move_slots.append(
                {
                    "slot": idx + 1,
                    "move_id": move_id,
                    "move_name": resolve_move_name(move_id),
                    "pp": battler.pp[idx],
                }
            )
        return {
            "battler_id": battler.battler_id,
            "role": battler.role,
            "present": battler.present,
            "species": battler.species,
            "species_name": resolve_species_name(battler.species),
            "level": battler.level,
            "hp": battler.hp,
            "max_hp": battler.max_hp,
            "status": battler.status,
            "status2": battler.status2,
            "primary_status": battler.primary_status,
            "primary_status_name": describe_status(
                battler.primary_status, battler.status_flags
            ),
            "status_flags": list(battler.status_flags),
            "item": battler.item,
            "item_name": resolve_item_name(battler.item),
            "ability": battler.ability,
            "ability_name": resolve_ability_name(battler.ability),
            "friendship": battler.friendship,
            "weight": battler.weight,
            "move_effect_flags": battler.move_effect_flags,
            "stat_changes": list(battler.stat_changes),
            "stat_stages": battler.stat_stages,
            "boosted_stats": list(battler.boosted_stats),
            "lowered_stats": list(battler.lowered_stats),
            "has_stat_boosts": battler.has_stat_boosts,
            "has_stat_drops": battler.has_stat_drops,
            "moves": list(battler.moves),
            "pp": list(battler.pp),
            "move_slots": move_slots,
        }

    return {
        "frame": state.frame,
        "session_id": state.session_id,
        "in_battle": state.in_battle,
        "ctx": state.ctx,
        "phase": state.phase,
        "battle_status": state.battle_status,
        "battle_status2": state.battle_status2,
        "damage": state.damage,
        "hit_damage": state.hit_damage,
        "battlers_on_field": state.battlers_on_field,
        "battlers": [battler_to_json(battler) for battler in state.battlers],
        "player": battler_to_json(state.player),
        "enemy": battler_to_json(state.enemy),
        "player_partner": battler_to_json(state.player_partner),
        "enemy_partner": battler_to_json(state.enemy_partner),
        "capabilities": state.capabilities,
        "last_command_id": state.last_command_id,
        "last_command_status": state.last_command_status,
        "last_command_error": state.last_command_error,
        "raw": state.raw,
    }


def add_common_wait_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--state-path",
        type=Path,
        default=DEFAULT_STATE_PATH,
        help=f"Path to state.json (default: {DEFAULT_STATE_PATH})",
    )
    parser.add_argument(
        "--command-path",
        type=Path,
        default=DEFAULT_COMMAND_PATH,
        help=f"Path to command.json (default: {DEFAULT_COMMAND_PATH})",
    )
    parser.add_argument(
        "--watch",
        action="store_true",
        help="Poll until an active battle and the expected phase are available.",
    )
    parser.add_argument(
        "--poll-seconds",
        type=float,
        default=0.1,
        help="Polling interval for --watch mode.",
    )
    parser.add_argument(
        "--timeout-seconds",
        type=float,
        default=None,
        help="Optional timeout for --watch mode.",
    )
    parser.add_argument(
        "--expected-phase",
        type=str,
        default=None,
        help="Phase gate to include in the command and, with --watch, wait for before writing.",
    )


def cmd_show_state(args: argparse.Namespace) -> int:
    state = load_state(args.state_path)
    print_state(state, args.format)
    return 0


def cmd_send_select_move(args: argparse.Namespace) -> int:
    state = wait_for_state(
        args.state_path,
        watch=args.watch,
        poll_seconds=args.poll_seconds,
        timeout_seconds=args.timeout_seconds,
        expected_phase=args.expected_phase,
    )
    command = build_select_move_command(
        state=state,
        move_id=args.move_id,
        target_battler=args.target_battler,
        expected_phase=args.expected_phase,
    )
    atomic_write_json(args.command_path, command.to_json())
    print(command.command_id)
    return 0


def cmd_send_press_buttons(args: argparse.Namespace) -> int:
    state = wait_for_state(
        args.state_path,
        watch=args.watch,
        poll_seconds=args.poll_seconds,
        timeout_seconds=args.timeout_seconds,
        expected_phase=args.expected_phase,
    )
    command = build_press_buttons_command(
        state=state,
        buttons=parse_buttons(args.buttons),
        hold_frames=args.hold_frames,
        expected_phase=args.expected_phase,
    )
    atomic_write_json(args.command_path, command.to_json())
    print(command.command_id)
    return 0


def cmd_send_save_state(args: argparse.Namespace) -> int:
    state = wait_for_state(
        args.state_path,
        watch=args.watch,
        poll_seconds=args.poll_seconds,
        timeout_seconds=args.timeout_seconds,
        expected_phase=args.expected_phase,
    )
    command = build_save_state_command(
        state=state,
        slot=args.slot,
        expected_phase=args.expected_phase,
    )
    atomic_write_json(args.command_path, command.to_json())
    print(command.command_id)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Read DeSmuME state.json and write high-level command.json actions."
    )
    subparsers = parser.add_subparsers(dest="subcommand", required=True)

    show_state = subparsers.add_parser("show-state", help="Print the current normalized state.")
    show_state.add_argument(
        "--state-path",
        type=Path,
        default=DEFAULT_STATE_PATH,
        help=f"Path to state.json (default: {DEFAULT_STATE_PATH})",
    )
    show_state.add_argument(
        "--format",
        choices=("json", "summary"),
        default="json",
        help="Output format for the current battle state.",
    )
    show_state.set_defaults(func=cmd_show_state)

    send_select_move = subparsers.add_parser(
        "send-select-move",
        help="Write a select_move command for the current battle session.",
    )
    add_common_wait_args(send_select_move)
    send_select_move.add_argument("--move-id", type=int, required=True)
    send_select_move.add_argument("--target-battler", type=int, default=None)
    send_select_move.set_defaults(func=cmd_send_select_move)

    send_press_buttons = subparsers.add_parser(
        "send-press-buttons",
        help="Write a press_buttons command for the current battle session.",
    )
    add_common_wait_args(send_press_buttons)
    send_press_buttons.add_argument(
        "--buttons",
        type=str,
        required=True,
        help="Comma-separated button list, for example A or Right,A.",
    )
    send_press_buttons.add_argument("--hold-frames", type=int, default=1)
    send_press_buttons.set_defaults(func=cmd_send_press_buttons)

    send_save_state = subparsers.add_parser(
        "send-save-state",
        help="Write a save_state command for the current battle session.",
    )
    add_common_wait_args(send_save_state)
    send_save_state.add_argument("--slot", type=int, required=True)
    send_save_state.set_defaults(func=cmd_send_save_state)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
