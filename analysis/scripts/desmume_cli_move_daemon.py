#!/usr/bin/env python3

from __future__ import annotations

import argparse
import sys
import time
from dataclasses import dataclass
from pathlib import Path

try:
    from analysis.scripts.desmume_battle_bridge import (
        DEFAULT_COMMAND_PATH,
        DEFAULT_STATE_PATH,
        BattleState,
        atomic_write_json,
        build_select_move_command,
        load_state,
    )
except ModuleNotFoundError:
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
    from analysis.scripts.desmume_battle_bridge import (
        DEFAULT_COMMAND_PATH,
        DEFAULT_STATE_PATH,
        BattleState,
        atomic_write_json,
        build_select_move_command,
        load_state,
    )


@dataclass(frozen=True)
class PromptDecision:
    kind: str
    move_id: int | None = None


def parse_prompt_input(raw: str) -> PromptDecision:
    text = raw.strip()
    if text == "":
        return PromptDecision(kind="skip")

    lowered = text.lower()
    if lowered in {"skip", "s"}:
        return PromptDecision(kind="skip")
    if lowered in {"quit", "q", "exit"}:
        return PromptDecision(kind="quit")
    if lowered in {"show", "state"}:
        return PromptDecision(kind="show")

    try:
        move_id = int(text, 0)
    except ValueError as exc:
        raise ValueError(
            "Enter a numeric move_id, `skip`, `show`, or `quit`."
        ) from exc

    if move_id <= 0:
        raise ValueError("move_id must be a positive integer.")

    return PromptDecision(kind="move", move_id=move_id)


def describe_state(state: BattleState) -> str:
    if not state.in_battle or state.player is None or state.enemy is None:
        return "no active battle"
    return (
        f"session={state.session_id} frame={state.frame} phase={state.phase} "
        f"player={state.player.species}@{state.player.hp}/{state.player.max_hp} "
        f"enemy={state.enemy.species}@{state.enemy.hp}/{state.enemy.max_hp}"
    )


def prompt_for_move(state: BattleState) -> PromptDecision:
    while True:
        print(describe_state(state))
        raw = input("move_id (`skip`, `show`, `quit`): ")
        try:
            decision = parse_prompt_input(raw)
        except ValueError as err:
            print(str(err))
            continue
        if decision.kind == "show":
            continue
        return decision


def should_prompt(state: BattleState, prompted_session_ids: set[str]) -> bool:
    return (
        state.in_battle
        and state.session_id is not None
        and state.phase == "fight_menu"
        and state.session_id not in prompted_session_ids
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Watch DeSmuME state.json and prompt in the CLI for a move_id when fight_menu opens."
    )
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
        "--poll-seconds",
        type=float,
        default=0.1,
        help="Polling interval while waiting for fight_menu.",
    )
    return parser


def main() -> int:
    args = build_parser().parse_args()
    prompted_session_ids: set[str] = set()
    last_signature: tuple[str | None, str, int | None] | None = None

    while True:
        try:
            state = load_state(args.state_path)
        except FileNotFoundError:
            time.sleep(args.poll_seconds)
            continue
        except Exception as err:
            print(f"state read failed: {err}")
            time.sleep(args.poll_seconds)
            continue

        signature = (state.session_id, state.phase, state.frame)
        if signature != last_signature and state.in_battle:
            print(describe_state(state))
            last_signature = signature

        if state.session_id is None:
            time.sleep(args.poll_seconds)
            continue

        if should_prompt(state, prompted_session_ids):
            decision = prompt_for_move(state)
            if decision.kind == "quit":
                return 0
            prompted_session_ids.add(state.session_id)
            if decision.kind == "skip":
                print(f"skipped session {state.session_id}")
                time.sleep(args.poll_seconds)
                continue
            if decision.kind != "move" or decision.move_id is None:
                time.sleep(args.poll_seconds)
                continue

            command = build_select_move_command(
                state=state,
                move_id=decision.move_id,
                target_battler=None,
                expected_phase="fight_menu",
            )
            atomic_write_json(args.command_path, command.to_json())
            print(
                f"queued {command.command_id} for session {state.session_id} with move_id={decision.move_id}"
            )

        if not state.in_battle:
            last_signature = None

        time.sleep(args.poll_seconds)


if __name__ == "__main__":
    raise SystemExit(main())
