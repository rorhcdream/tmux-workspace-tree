#!/usr/bin/env python3
"""Render a local agent transcript only when its process/session match is unique."""

import collections
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import textwrap


def command(*args):
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=3)
        return result.stdout if result.returncode == 0 else ""
    except (OSError, subprocess.TimeoutExpired):
        return ""


def records(path):
    # Bound work on large transcripts; ignore an incomplete trailing JSON record.
    try:
        with open(path, "rb") as stream:
            stream.seek(0, 2)
            start = max(0, stream.tell() - 512 * 1024)
            stream.seek(start)
            if start:
                stream.readline()
            for line in stream:
                try:
                    item = json.loads(line)
                    if isinstance(item, dict):
                        yield item
                except (ValueError, UnicodeError):
                    continue
    except OSError:
        return


def metadata(path):
    try:
        with open(path, encoding="utf-8") as stream:
            for _ in range(32):
                try:
                    item = json.loads(next(stream))
                except (ValueError, StopIteration):
                    continue
                if item.get("type") == "session_meta":
                    return item.get("payload", {})
    except (OSError, UnicodeError):
        pass
    return {}


def transcript(path, kind):
    state, latest, pending = "", "", []
    tools = collections.deque(maxlen=5)
    question_id = None
    for item in records(path):
        payload = item.get("payload") or {}
        if not isinstance(payload, dict):
            continue
        event = payload.get("type") if item.get("type") == "event_msg" else ""
        if event == "task_started":
            state = "working"
        elif event == "task_complete":
            state = "done"
        elif event == "turn_aborted":
            state, pending = "stopped", []
        elif event == "user_message":
            pending = []
        elif event == "agent_message" and isinstance(payload.get("message"), str):
            latest = payload["message"]

        message = payload if kind == "codex" else item.get("message", {})
        if not isinstance(message, dict):
            continue
        role = message.get("role") or item.get("type")
        content = message.get("content", [])
        if role == "user":
            pending = []
        if role == "assistant" and isinstance(content, list):
            text = [block.get("text", "") for block in content
                    if isinstance(block, dict) and block.get("type") in ("text", "output_text")]
            if any(text):
                latest = "\n".join(text)
        calls = []
        if kind == "codex" and payload.get("type") == "function_call":
            calls = [payload]
        elif kind == "claude" and isinstance(content, list):
            calls = [block for block in content if isinstance(block, dict) and block.get("type") == "tool_use"]
        for call in calls:
            name = call.get("name", "tool")
            tools.append(str(name))
            args = call.get("arguments", call.get("input", {}))
            if isinstance(args, str):
                try:
                    args = json.loads(args)
                except ValueError:
                    args = {}
            if name.rsplit(".", 1)[-1] in ("request_user_input", "request_user_input_async", "AskUserQuestion"):
                pending = args.get("questions", []) if isinstance(args, dict) else []
                question_id = call.get("call_id", call.get("id"))
        if payload.get("type") == "function_call_output" and payload.get("call_id") == question_id:
            # Synchronous input tools return answers here. Async acceptance is
            # not an answer; its question stays visible until a user message.
            output = payload.get("output", "")
            try:
                output = json.loads(output) if isinstance(output, str) else output
            except ValueError:
                output = None
            if isinstance(output, dict) and output.get("answers"):
                pending = []
    return {"state": "waiting" if pending else state, "text": latest,
            "questions": pending, "tools": list(tools)}


def descendants(root, processes):
    found, todo = set(), [root]
    while todo:
        pid = todo.pop()
        if pid in found:
            continue
        found.add(pid)
        todo.extend(p for p, (parent, _) in processes.items() if parent == pid)
    return found


def agents(root, processes):
    todo, seen, found = [root], set(), []
    while todo:
        pid = todo.pop()
        if pid in seen:
            continue
        seen.add(pid)
        name = processes.get(pid, (0, ""))[1]
        if name in ("node", "MainThread"):
            try:
                words = shlex.split(command("ps", "-p", str(pid), "-o", "args="))
                name = next((Path(w).name for w in words[:2] if Path(w).name in ("codex", "claude")), name)
            except ValueError:
                pass
        if name in ("codex", "claude"):
            found.append((pid, name))
        else:
            todo.extend(p for p, (parent, _) in processes.items() if parent == pid)
    return found


def open_rollouts(*options):
    files = set()
    for line in command("lsof", *options, "-Fn").splitlines():
        if line.startswith("n"):
            path = Path(line[1:])
            if path.name.startswith("rollout-") and path.suffix == ".jsonl" and path.is_file():
                files.add(path)
    return files


def unique_root(files):
    roots = {}
    for path in files:
        info = metadata(path)
        source = info.get("source")
        if (not info.get("id") or info.get("parent_thread_id")
                or info.get("thread_source") == "subagent"
                or isinstance(source, dict) and "subagent" in source):
            continue
        roots.setdefault(info["id"], []).append(path)
    if len(roots) != 1:
        return None
    return max(next(iter(roots.values())), key=lambda p: p.stat().st_mtime)


def process_cwd(pid):
    try:
        return os.path.realpath(os.readlink(f"/proc/{pid}/cwd"))
    except OSError:
        paths = [line[1:] for line in command("lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn").splitlines() if line.startswith("n")]
        return os.path.realpath(paths[0]) if len(paths) == 1 else ""


def find_sessions(target):
    window = command("tmux", "display-message", "-p", "-t", target, "#{window_id}").strip()
    if not window:
        return []
    processes = {}
    for line in command("ps", "-axo", "pid=,ppid=,comm=").splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) == 3 and parts[0].isdigit() and parts[1].isdigit():
            processes[int(parts[0])] = (int(parts[1]), Path(parts[2]).name)
    clients, selected = {}, set()
    for line in command("tmux", "list-panes", "-a", "-F", "#{window_id}\t#{pane_pid}").splitlines():
        parts = line.split("\t")
        if len(parts) != 2 or not parts[1].isdigit():
            continue
        for pid, kind in agents(int(parts[1]), processes):
            clients[pid] = kind
            if parts[0] == window:
                selected.add(pid)
    result = []
    icon = command("tmux", "display-message", "-p", "-t", window, "#{@agent_status}").strip()
    shared = None
    cwds = {}
    for pid in sorted(selected):
        kind = clients[pid]
        path = None
        reported_state = ""
        if kind == "codex":
            owned = open_rollouts("-a", "-p", ",".join(map(str, descendants(pid, processes))))
            path = unique_root(owned)
            if not owned:
                # Shared app-server handles are usable only with one pane
                # client and one root session in the same working directory.
                if shared is None:
                    shared = open_rollouts("-a", "-c", "codex")
                    cwds = {p: process_cwd(p) for p, k in clients.items() if k == "codex"}
                cwd = cwds.get(pid)
                if cwd and list(cwds.values()).count(cwd) == 1:
                    path = unique_root(p for p in shared if os.path.realpath(metadata(p).get("cwd", "")) == cwd)
        else:
            matches = set()
            for config in Path.home().glob(".claude*"):
                try:
                    status = json.loads((config / "sessions" / f"{pid}.json").read_text())
                    reported_state = status.get("status", "")
                    session_id = status.get("sessionId", "")
                    if session_id and re.fullmatch(r"[A-Za-z0-9_-]+", session_id):
                        matches.update((config / "projects").glob(f"*/{session_id}.jsonl"))
                except (OSError, ValueError):
                    pass
            if len(matches) == 1:
                path = matches.pop()
        if path:
            data = transcript(path, kind)
            if reported_state:
                data["state"] = reported_state
            data["icon"] = icon
            result.append((kind, data))
    return result


def clean(text):
    return "".join(c for c in str(text) if c in "\n\t" or ord(c) >= 32 and not 127 <= ord(c) < 160)


def render(sessions, width):
    lines = []
    for kind, data in sessions:
        lines.append(f"{kind.title()} — {data.get('icon', '')} {data['state'] or 'session'}")
        for question in data["questions"]:
            if not isinstance(question, dict):
                continue
            lines.extend(("", "Pending question", question.get("question", "")))
            for option in question.get("options", []):
                if isinstance(option, dict):
                    lines.append("  • " + str(option.get("label", "")))
        if data["text"]:
            lines.extend(("", "Latest assistant response", data["text"][-16000:]))
        if data["tools"]:
            lines.extend(("", "Recent tools: " + " → ".join(data["tools"])))
        lines.append("")
    return "\n".join("\n".join(textwrap.wrap(clean(line), width=width, replace_whitespace=False,
                                           drop_whitespace=False)) for line in lines)


def main():
    try:
        sessions = find_sessions(sys.argv[1])
        if not sessions or not any(d["text"] or d["questions"] or d["tools"] for _, d in sessions):
            return 1
        width = max(10, int(os.environ.get("FZF_PREVIEW_COLUMNS", "80")))
        print(render(sessions, width))
        return 0
    except (OSError, ValueError, TypeError, KeyError):
        return 1


if __name__ == "__main__":
    sys.exit(main())
