from __future__ import annotations

import unittest

from analysis.scripts.desmume_battle_bridge import BattleState
from analysis.scripts.desmume_cli_move_daemon import (
    describe_state,
    parse_prompt_input,
    should_prompt,
)
from analysis.scripts.test_desmume_battle_bridge import sample_state_payload


class CliMoveDaemonTests(unittest.TestCase):
    def test_parse_prompt_input(self) -> None:
        self.assertEqual(parse_prompt_input("145").move_id, 145)
        self.assertEqual(parse_prompt_input("0x91").move_id, 145)
        self.assertEqual(parse_prompt_input("skip").kind, "skip")
        self.assertEqual(parse_prompt_input("show").kind, "show")
        self.assertEqual(parse_prompt_input("quit").kind, "quit")
        with self.assertRaises(ValueError):
            parse_prompt_input("abc")
        with self.assertRaises(ValueError):
            parse_prompt_input("0")

    def test_should_prompt_only_once_per_session(self) -> None:
        state = BattleState.from_json(sample_state_payload())
        self.assertTrue(should_prompt(state, set()))
        self.assertFalse(should_prompt(state, {state.session_id or ""}))

        no_menu_payload = sample_state_payload()
        no_menu_payload["phase"] = "commit_window"
        no_menu_state = BattleState.from_json(no_menu_payload)
        self.assertFalse(should_prompt(no_menu_state, set()))

    def test_describe_state(self) -> None:
        state = BattleState.from_json(sample_state_payload())
        description = describe_state(state)
        self.assertIn("session=022C3CF4-1", description)
        self.assertIn("phase=fight_menu", description)
        self.assertIn("player=25@80/90", description)


if __name__ == "__main__":
    unittest.main()
