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

    def codex_user(self, text):
        return {"type": "response_item", "payload": {
            "type": "message", "role": "user", "content": [{"type": "input_text", "text": text}]}}

    def claude_user(self, content, **fields):
        return {"type": "user", "message": {"role": "user", "content": content}, **fields}

    def test_codex_last_input_skips_injected_context(self):
        self.write(self.codex_user("typed request"),
                   self.codex_user("<environment_context>\n<cwd>/x</cwd>\n</environment_context>"),
                   self.codex_user("<skill>\nbody\n</skill>"),
                   self.codex_user("# AGENTS.md instructions for /x"),
                   self.codex_user("The following is the Codex agent history"))
        self.assertEqual(preview.transcript(self.path, "codex")["input"], "typed request")

    def test_codex_input_starting_with_a_tag_is_kept(self):
        self.write(self.codex_user("<div> is broken in this page"))
        self.assertEqual(preview.transcript(self.path, "codex")["input"], "<div> is broken in this page")

    def test_codex_user_message_event_is_input(self):
        self.write({"type": "event_msg", "payload": {"type": "user_message", "message": "from event"}})
        self.assertEqual(preview.transcript(self.path, "codex")["input"], "from event")

    def test_claude_last_input_skips_non_human_entries(self):
        self.write(self.claude_user("typed request", origin={"kind": "human"}),
                   self.claude_user([{"type": "tool_result", "content": "output"}]),
                   self.claude_user("injected", isMeta=True),
                   self.claude_user("summary", isCompactSummary=True),
                   self.claude_user("<task-notification>done</task-notification>", origin={"kind": "task-notification"}),
                   self.claude_user("<local-command-stdout>out</local-command-stdout>"),
                   self.claude_user([{"type": "text", "text": "[Request interrupted by user]"}]))
        self.assertEqual(preview.transcript(self.path, "claude")["input"], "typed request")

    def test_claude_slash_command_is_shown_as_typed(self):
        self.write(self.claude_user("<command-message>foo</command-message>\n<command-name>/foo</command-name>\n"
                                    "<command-args>some args</command-args>", origin={"kind": "human"}))
        self.assertEqual(preview.transcript(self.path, "claude")["input"], "/foo some args")

    def test_claude_queued_prompt_is_input_but_notification_is_not(self):
        self.write({"type": "attachment", "attachment": {
                        "type": "queued_command", "commandMode": "prompt",
                        "origin": {"kind": "human"}, "prompt": "typed mid-turn"}},
                   {"type": "attachment", "attachment": {
                        "type": "queued_command", "commandMode": "task-notification",
                        "origin": {"kind": "task-notification"}, "prompt": "background"}})
        self.assertEqual(preview.transcript(self.path, "claude")["input"], "typed mid-turn")

    def test_last_input_is_found_behind_the_normal_tail(self):
        filler = {"type": "assistant", "message": {"content": [{"type": "text", "text": "x" * 100_000}]}}
        self.write(self.claude_user("long-running request", origin={"kind": "human"}), *[filler] * 8)
        self.assertEqual(preview.transcript(self.path, "claude")["input"], "long-running request")

    def test_last_input_renders_before_response_with_each_line_wrapped(self):
        data = {"state": "done", "text": "reply", "input": "first line\n" + "word " * 20, "questions": [], "tools": []}
        rendered = preview.render([("claude", data)], 32).splitlines()
        self.assertLess(rendered.index("Last input"), rendered.index("Latest assistant response"))
        self.assertEqual(rendered[rendered.index("Last input") + 1], "first line")
        self.assertTrue(all(len(line) <= 32 for line in rendered))

    def test_long_input_is_truncated(self):
        data = {"state": "", "text": "", "input": "y" * 5000, "questions": [], "tools": []}
        rendered = preview.render([("claude", data)], 80)
        self.assertEqual(rendered.count("y"), preview.INPUT_PREVIEW_CHARS)
        self.assertIn("…", rendered)

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
