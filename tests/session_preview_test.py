import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("preview", Path(__file__).parents[1] / "scripts/session_preview.py")
preview = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preview)


class SessionPreviewTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "rollout-example.jsonl"

    def write(self, *items):
        self.path.write_text("\n".join(json.dumps(item) for item in items) + "\n")

    def event(self, kind):
        return {"type": "event_msg", "payload": {"type": kind}}

    def question(self):
        return {"type": "response_item", "payload": {
            "type": "function_call", "name": "request_user_input_async", "call_id": "q1",
            "arguments": json.dumps({"questions": [{"question": "Which option?", "options": [{"label": "One"}]}]})}}

    def test_question_survives_completion_and_async_acceptance(self):
        self.write(self.event("task_started"), self.question(),
                   {"type": "response_item", "payload": {"type": "function_call_output", "call_id": "q1", "output": "accepted"}},
                   self.event("task_complete"))
        data = preview.transcript(self.path, "codex")
        self.assertEqual(data["state"], "waiting")
        rendered = preview.render([("codex", data)], 32)
        self.assertIn("Which option?", rendered)
        self.assertIn("One", rendered)
        self.assertTrue(all(len(line) <= 32 for line in rendered.splitlines()))

    def test_answer_clears_question_and_latest_response_is_used(self):
        self.write(self.question(), self.event("user_message"),
                   {"type": "response_item", "payload": {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "Latest response"}]}},
                   self.event("task_complete"))
        data = preview.transcript(self.path, "codex")
        self.assertFalse(data["questions"])
        self.assertEqual(data["state"], "done")
        self.assertEqual(data["text"], "Latest response")

    def test_tool_summary_excludes_arguments_and_outputs(self):
        self.write({"type": "response_item", "payload": {"type": "function_call", "name": "exec_command", "arguments": "example arguments"}})
        data = preview.transcript(self.path, "codex")
        self.assertEqual(data["tools"], ["exec_command"])
        self.assertNotIn("example arguments", preview.render([("codex", data)], 80))

    def test_claude_response_and_tools(self):
        self.write({"type": "assistant", "message": {"content": [
            {"type": "text", "text": "Example reply"},
            {"type": "tool_use", "name": "Read", "input": {"file": "example.txt"}}]}})
        data = preview.transcript(self.path, "claude")
        self.assertEqual(data["text"], "Example reply")
        self.assertEqual(data["tools"], ["Read"])

    def test_partial_record_is_ignored(self):
        self.write({"type": "event_msg", "payload": {"type": "agent_message", "message": "Complete text"}})
        with self.path.open("a") as stream:
            stream.write('{"type":')
        self.assertEqual(preview.transcript(self.path, "codex")["text"], "Complete text")

    def test_ambiguous_roots_are_rejected(self):
        with patch.object(preview, "metadata", side_effect=[{"id": "one"}, {"id": "two"}]):
            self.assertIsNone(preview.unique_root([Path("one"), Path("two")]))

    def test_subagent_is_not_used_as_main_session(self):
        with patch.object(preview, "metadata", return_value={"id": "child", "source": {"subagent": {}}}):
            self.assertIsNone(preview.unique_root([self.path]))

    def test_transcript_control_sequences_are_not_executed(self):
        self.assertNotIn("\x1b", preview.clean("text\x1b[2J\x00"))

    def test_shared_session_with_two_clients_in_same_directory_is_rejected(self):
        def output(*args):
            if args[0] == "ps":
                return "10 1 codex\n20 1 codex\n"
            if args[1] == "list-panes":
                return "@1\t10\n@2\t20\n"
            return "@1" if args[-1] == "#{window_id}" else ""
        with patch.object(preview, "command", side_effect=output), \
                patch.object(preview, "open_rollouts", side_effect=[set(), {self.path}]), \
                patch.object(preview, "process_cwd", return_value="/example"):
            self.assertEqual(preview.find_sessions("@1"), [])

    def test_tree_uses_original_screen_fallback_only_when_session_preview_fails(self):
        root = Path(self.temp.name)
        binary = root / "bin"
        binary.mkdir()
        tmux = binary / "tmux"
        tmux.write_text('#!/bin/sh\ncase "$1" in\n'
                        'display-message) printf "1700000000\\t0\\n";;\n'
                        'capture-pane) printf "UPPER_LEFT_SCREEN\\n";;\nesac\n')
        tmux.chmod(0o755)
        python = binary / "python3"
        env = {**os.environ, "PATH": str(binary) + os.pathsep + os.environ["PATH"], "TMPDIR": str(root)}
        tree = Path(__file__).parents[1] / "scripts/tree.sh"
        for script, expected, absent in [
                ("exit 1", "UPPER_LEFT_SCREEN", "SESSION_VIEW"),
                ("echo SESSION_VIEW", "SESSION_VIEW", "UPPER_LEFT_SCREEN")]:
            python.write_text("#!/bin/sh\n" + script + "\n")
            python.chmod(0o755)
            result = subprocess.run(["bash", str(tree), "--preview", "example", "@1"],
                                    env=env, text=True, capture_output=True, check=True)
            self.assertIn(expected, result.stdout)
            self.assertNotIn(absent, result.stdout)


if __name__ == "__main__":
    unittest.main()
