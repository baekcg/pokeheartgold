from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from analysis.scripts.desmume_battle_bridge import (
    SCHEMA_VERSION,
    BattleState,
    atomic_write_json,
    build_press_buttons_command,
    build_save_state_command,
    build_select_move_command,
    format_state_summary,
    load_state,
    parse_buttons,
    resolve_move_name,
    state_to_json,
)


def sample_state_payload() -> dict:
    battler = {
        "battler_id": 0,
        "role": "player",
        "present": True,
        "species": 25,
        "level": 30,
        "hp": 80,
        "max_hp": 90,
        "status": 0,
        "status2": 0,
        "primary_status": "healthy",
        "status_flags": [],
        "item": 0,
        "ability": 9,
        "friendship": 100,
        "weight": 60,
        "move_effect_flags": 0,
        "stat_changes": [6, 8, 6, 5, 6, 6, 6, 6],
        "stat_stages": {
            "attack": 2,
            "defense": 0,
            "speed": -1,
            "special_attack": 0,
            "special_defense": 0,
            "accuracy": 0,
            "evasion": 0,
        },
        "boosted_stats": ["attack"],
        "lowered_stats": ["speed"],
        "has_stat_boosts": True,
        "has_stat_drops": True,
        "moves": [33, 45, 85, 98],
        "pp": [35, 30, 15, 20],
    }
    enemy = dict(battler)
    enemy["battler_id"] = 1
    enemy["role"] = "enemy"
    enemy["species"] = 19
    enemy["ability"] = 50
    return {
        "schema_version": SCHEMA_VERSION,
        "frame": 123,
        "session_id": "022C3CF4-1",
        "in_battle": True,
        "ctx": 0x022C3CF4,
        "phase": "fight_menu",
        "raw": {
            "command": 5,
            "command_next": 13,
            "move_no_temp": 33,
            "move_no_cur": 33,
        },
        "battle_status": 0,
        "battle_status2": 0,
        "damage": 0,
        "hit_damage": 0,
        "battlers_on_field": 2,
        "battlers": [battler, enemy, None, None],
        "player": battler,
        "enemy": enemy,
        "player_partner": None,
        "enemy_partner": None,
        "capabilities": {
            "joypad": True,
            "savestate_slot": False,
            "memory_write_u32": True,
        },
        "last_command_id": None,
        "last_command_status": "idle",
        "last_command_error": None,
    }


class BattleBridgeTests(unittest.TestCase):
    def test_load_state_round_trip(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            state_path = Path(tmpdir) / "state.json"
            state_path.write_text(json.dumps(sample_state_payload()))
            state = load_state(state_path)

        self.assertIsInstance(state, BattleState)
        self.assertEqual(state.session_id, "022C3CF4-1")
        self.assertEqual(state.phase, "fight_menu")
        self.assertEqual(state.player.moves[0], 33)
        self.assertEqual(state.player.stat_stages["attack"], 2)
        self.assertEqual(len(state.battlers), 4)
        self.assertTrue(state.capabilities["joypad"])

    def test_build_select_move_command(self) -> None:
        state = BattleState.from_json(sample_state_payload())
        command = build_select_move_command(
            state=state,
            move_id=145,
            target_battler=1,
            expected_phase="fight_menu",
        )

        payload = command.to_json()
        self.assertEqual(payload["schema_version"], SCHEMA_VERSION)
        self.assertEqual(payload["action"], "select_move")
        self.assertEqual(payload["move_id"], 145)
        self.assertEqual(payload["target_battler"], 1)
        self.assertEqual(payload["expected_phase"], "fight_menu")
        self.assertEqual(payload["for_session_id"], "022C3CF4-1")

    def test_build_press_buttons_and_save_state_commands(self) -> None:
        state = BattleState.from_json(sample_state_payload())

        press_command = build_press_buttons_command(
            state=state,
            buttons=["Right", "A"],
            hold_frames=2,
            expected_phase="target_select",
        )
        save_command = build_save_state_command(
            state=state,
            slot=3,
            expected_phase=None,
        )

        self.assertEqual(press_command.to_json()["buttons"], ["Right", "A"])
        self.assertEqual(press_command.to_json()["hold_frames"], 2)
        self.assertEqual(save_command.to_json()["slot"], 3)
        self.assertEqual(save_command.to_json()["action"], "save_state")

    def test_atomic_write_json_replaces_target(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            command_path = Path(tmpdir) / "command.json"
            atomic_write_json(command_path, {"schema_version": SCHEMA_VERSION, "value": 1})
            atomic_write_json(command_path, {"schema_version": SCHEMA_VERSION, "value": 2})

            payload = json.loads(command_path.read_text())

        self.assertEqual(payload["value"], 2)

    def test_parse_buttons_rejects_unknown_buttons(self) -> None:
        self.assertEqual(parse_buttons("A,Right"), ["A", "Right"])
        with self.assertRaises(ValueError):
            parse_buttons("A,Foo")

    def test_state_to_json_resolves_names_and_stat_changes(self) -> None:
        state = BattleState.from_json(sample_state_payload())
        payload = state_to_json(state)

        self.assertEqual(payload["battlers"][0]["species_name"], "Pikachu")
        self.assertEqual(payload["battlers"][0]["ability_name"], "Static")
        self.assertEqual(payload["battlers"][0]["primary_status_name"], "Healthy")
        self.assertEqual(payload["battlers"][0]["boosted_stats"], ["attack"])
        self.assertEqual(payload["battlers"][0]["lowered_stats"], ["speed"])
        self.assertEqual(payload["battlers"][0]["move_slots"][0]["move_name"], "Tackle")

    def test_move_name_lookup_prefers_actual_move_define(self) -> None:
        self.assertEqual(resolve_move_name(0), "None")
        self.assertEqual(resolve_move_name(10), "Scratch")

    def test_format_state_summary_lists_all_battlers(self) -> None:
        state = BattleState.from_json(sample_state_payload())
        summary = format_state_summary(state)

        self.assertIn("session=022C3CF4-1", summary)
        self.assertIn("[0] player: Pikachu", summary)
        self.assertIn("[1] enemy: Rattata", summary)
        self.assertIn("[2] empty", summary)
        self.assertIn("[3] empty", summary)


if __name__ == "__main__":
    unittest.main()
