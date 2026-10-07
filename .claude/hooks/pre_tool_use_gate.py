#!/usr/bin/env python3
"""PreToolUse safety gate shared by Claude Code, ZCode and Codex.

The only policy source is dangerous_patterns.conf next to this file. The
adapters (block_dangerous.sh for Claude Code/ZCode and
.codex/hooks/pre_tool_use_policy.py for Codex) carry no patterns of their own.

stdin:  the client's hook payload, e.g. {"tool_name": "Bash", "tool_input": {...}}.
stdout: nothing when the call is allowed, otherwise one PreToolUse decision JSON.
exit:   0 once a decision is made; 2 (reason on stderr) when the payload is not a
        JSON object, or when the policy cannot be loaded or evaluated for a guarded
        tool (shell, file writes, apply_patch). The hooks are registered for guarded
        tools only, so an unreadable payload fails closed instead of silently allowing.
        1 (traceback on stderr) when evaluation outlives the watchdog deadline
        (EVALUATION_DEADLINE_SECONDS; tests may shorten it via GX_GATE_WATCHDOG_SECONDS);
        every registered hook command turns that into a blocking 2.
"""

from __future__ import annotations

import argparse
import faulthandler
import json
import os
import posixpath
import re
import shlex
import sys
from collections.abc import Mapping
from pathlib import Path
from typing import NamedTuple

HOOK_DIR = Path(__file__).resolve().parent
CONF_PATH = HOOK_DIR / "dangerous_patterns.conf"
# The checkout root is derived from this file's location (<root>/.claude/hooks/),
# not from the session cwd, so FILE rules stay root-relative from any subdirectory.
REPO_ROOT = HOOK_DIR.parents[1]
SECTIONS = ("SHELL", "FILE")
LEVELS = ("deny", "ask")
SHELL_TOOLS = frozenset({"bash"})
WRITE_TOOLS = frozenset({"edit", "write", "multiedit", "notebookedit"})
# Codex edits files through apply_patch, whose patch text names the target files.
PATCH_TOOLS = frozenset({"apply_patch"})
# Claude Code/ZCode send file_path (notebook_path for NotebookEdit); Kimi Code's Write/Edit send path.
FILE_KEYS = ("file_path", "notebook_path", "path")
PROTOCOLS = ("claude", "codex")
CODEX_ASK_NOTE = "（Codex 的 PreToolUse 不支持 ask，已按仓库策略直接拒绝；确需执行请由人工在终端操作）"
# The clients allow the tool call when a hook outlives its 30 s timeout. A pathological
# command can keep the regex engine busy without releasing the GIL, so a C-level
# faulthandler watchdog ends the process first; block_dangerous.sh may try a second
# interpreter, so two deadlines must still fit inside the client timeout.
EVALUATION_DEADLINE_SECONDS = 10.0
# Tests shorten the watchdog with this variable. Only values in (0, EVALUATION_DEADLINE_SECONDS]
# count, so the environment can never stretch evaluation past the client timeout.
DEADLINE_ENV = "GX_GATE_WATCHDOG_SECONDS"

_MSYS_DRIVE = re.compile(r"^/(?:cygdrive/)?([A-Za-z])(?=/|$)")
_WINDOWS_DRIVE = re.compile(r"^[A-Za-z]:/")
# A line continuation is an odd run of escape characters before a newline (an even run
# is literal): backslash for bash/sh, backtick for PowerShell. Both shells drop the pair.
_CONTINUATIONS = (
    re.compile(r"(?<!\\)((?:\\\\)*)\\\r?\n"),
    re.compile(r"(?<!`)((?:``)*)`\r?\n"),
)
_PATCH_HEADER = re.compile(r"^\*\*\* (?:Add File|Update File|Delete File|Move to):[ \t]*(.*?)[ \t]*\r?$", re.MULTILINE)
_APPLY_PATCH_CALL = re.compile(r"\bapply_?patch\b")


class PolicyError(ValueError):
    """dangerous_patterns.conf cannot be used as a policy."""


class Rule(NamedTuple):
    section: str
    pattern: re.Pattern[str]
    reason: str
    level: str
    line_no: int


class Decision(NamedTuple):
    level: str
    reason: str


def load_rules(conf_path: Path = CONF_PATH) -> list[Rule]:
    """Parse the TAB-separated policy; any malformed line rejects the whole file."""
    try:
        text = conf_path.read_text(encoding="utf-8-sig")
    except (OSError, UnicodeDecodeError) as exc:
        raise PolicyError(f"无法读取 {conf_path.name}：{exc}") from exc
    rules: list[Rule] = []
    # splitlines() also strips CR, so a CRLF checkout (core.autocrlf=true) parses the same.
    for line_no, line in enumerate(text.splitlines(), start=1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) != 4:
            raise PolicyError(f"第 {line_no} 行应为 4 列（TAB 分隔），实际 {len(parts)} 列")
        section = parts[0].strip().upper()
        regex = parts[1]
        reason = parts[2].strip()
        level = parts[3].strip().lower()
        if section not in SECTIONS:
            raise PolicyError(f"第 {line_no} 行 SECTION 非法：{parts[0]!r}")
        if level not in LEVELS:
            raise PolicyError(f"第 {line_no} 行级别非法：{parts[3]!r}")
        if not regex.strip() or not reason:
            raise PolicyError(f"第 {line_no} 行正则或理由为空")
        flags = re.IGNORECASE if section == "FILE" else 0
        try:
            pattern = re.compile(regex, flags)
        except re.error as exc:
            raise PolicyError(f"第 {line_no} 行正则非法：{exc}") from exc
        rules.append(Rule(section, pattern, reason, level, line_no))
    if not rules:
        raise PolicyError("未声明任何规则")
    return rules


def shell_command(tool_input: dict) -> str:
    command = tool_input.get("command")
    if isinstance(command, str):
        return command
    if isinstance(command, list) and all(isinstance(part, str) for part in command):
        return shlex.join(command)
    return ""


def shell_variants(command: str) -> list[str]:
    """The command plus its line-continuation-joined forms; SHELL rules match any of them.

    Keeping the original guards against shells where the escape character is literal.
    """
    variants = [command]
    for continuation in _CONTINUATIONS:
        joined = continuation.sub(r"\1", command)
        if joined not in variants:
            variants.append(joined)
    return variants


def _strings(value: object) -> list[str]:
    if isinstance(value, str):
        return [value]
    if isinstance(value, dict):
        return [text for item in value.values() for text in _strings(item)]
    if isinstance(value, (list, tuple)):
        return [text for item in value for text in _strings(item)]
    return []


def patch_targets(value: object) -> list[str]:
    """Best-effort target paths named by apply_patch headers in any string inside value."""
    return [
        match.group(1)
        for text in _strings(value)
        for match in _PATCH_HEADER.finditer(text)
        if match.group(1)
    ]


def _posix_path(raw: str) -> str:
    text = raw.strip().replace("\\", "/")
    if text.startswith(("//?/", "//./")):
        text = text[4:]
    if os.name == "nt":
        match = _MSYS_DRIVE.match(text)
        if match:
            text = f"{match.group(1).upper()}:{text[match.end():] or '/'}"
    return text


def _is_absolute(text: str) -> bool:
    return text.startswith("/") or bool(_WINDOWS_DRIVE.match(text))


def repo_relative(raw: str, root: Path = REPO_ROOT, cwd: str | Path | None = None) -> str:
    """Normalize a tool path and make it relative to root when it lies inside it.

    Paths outside root come back absolute (forward slashes), so root-anchored
    FILE rules cannot match them while unanchored ones (.env, keys) still do.
    """
    root_text = posixpath.normpath(_posix_path(str(root)))
    text = _posix_path(raw)
    if not text:
        return ""
    if not _is_absolute(text):
        base = _posix_path(str(cwd)) if cwd else root_text
        if not _is_absolute(base):
            base = f"{root_text}/{base}"
        text = f"{base.rstrip('/')}/{text}"
    text = posixpath.normpath(text)
    parts = text.split("/")
    root_parts = root_text.rstrip("/").split("/")
    # Windows and macOS file systems are case-insensitive; compare components casefolded.
    if len(parts) >= len(root_parts) and all(
        a.casefold() == b.casefold() for a, b in zip(parts, root_parts)
    ):
        return "/".join(parts[len(root_parts):]) or "."
    return text


def evaluate(
    tool_name: object,
    tool_input: dict,
    rules: list[Rule],
    *,
    root: Path = REPO_ROOT,
    cwd: str | Path | None = None,
) -> Decision | None:
    """Return the decision for one tool call; any deny wins over any ask."""
    name = str(tool_name or "").lower()
    commands: list[str] = []
    paths: list[str] = []
    if name in SHELL_TOOLS:
        command = shell_command(tool_input)
        commands = shell_variants(command) if command else []
        # Codex can also run apply_patch through the shell; its patch headers name the files.
        if _APPLY_PATCH_CALL.search(command):
            paths = patch_targets(tool_input.get("command"))
    elif name in WRITE_TOOLS:
        paths = [value for key in FILE_KEYS if isinstance(value := tool_input.get(key), str)]
    elif name in PATCH_TOOLS:
        paths = patch_targets(tool_input)
    else:
        return None
    subjects = [("SHELL", text) for text in commands]
    subjects += [
        ("FILE", relative)
        for path in paths
        if path.strip() and (relative := repo_relative(path, root, cwd))
    ]
    ask: Decision | None = None
    for rule in rules:
        for section, subject in subjects:
            if section != rule.section or not rule.pattern.search(subject):
                continue
            where = "命中命令" if section == "SHELL" else f"命中文件 {subject}"
            decision = Decision(
                rule.level,
                f"{rule.reason}（{where}；规则见 .claude/hooks/dangerous_patterns.conf 第 {rule.line_no} 行）",
            )
            if rule.level == "deny":
                return decision
            ask = ask or decision
    return ask


def render(decision: Decision, protocol: str) -> dict:
    """Build the PreToolUse output for the requested client protocol.

    Claude Code (and ZCode through the same adapter) honor "ask". Codex parses
    "ask" but treats it as a failed hook and runs the tool anyway, so on the
    Codex protocol an ask-level rule is reported as deny.
    """
    level, reason = decision.level, decision.reason
    if protocol == "codex" and level == "ask":
        level, reason = "deny", reason + CODEX_ASK_NOTE
    return {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": level,
            "permissionDecisionReason": reason,
        }
    }


def _use_utf8_streams() -> None:
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if reconfigure is not None:
            reconfigure(encoding="utf-8", errors="replace")


def _read_payload() -> dict | None:
    """The hook payload, or None when stdin does not hold a JSON object."""
    stdin = getattr(sys.stdin, "buffer", None)
    raw = stdin.read() if stdin is not None else b""
    try:
        payload = json.loads(raw.decode("utf-8-sig"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None
    return payload if isinstance(payload, dict) else None


def _is_guarded(tool_name: object) -> bool:
    name = str(tool_name or "").lower()
    return name in SHELL_TOOLS or name in WRITE_TOOLS or name in PATCH_TOOLS


def _fail_closed(message: str) -> int:
    print(f"pre_tool_use_gate: {message}", file=sys.stderr)
    return 2


def evaluation_deadline(environ: Mapping[str, str] | None = None) -> float:
    """The watchdog deadline: DEADLINE_ENV when it is a number in (0, default], else the default."""
    raw = (os.environ if environ is None else environ).get(DEADLINE_ENV, "")
    try:
        value = float(raw)
    except (TypeError, ValueError):
        return EVALUATION_DEADLINE_SECONDS
    # NaN fails both comparisons and infinity exceeds the cap, so both keep the default.
    return value if 0 < value <= EVALUATION_DEADLINE_SECONDS else EVALUATION_DEADLINE_SECONDS


def _arm_watchdog() -> bool:
    """Exit with status 1 (and a traceback on stderr) if evaluation outlives the deadline."""
    try:
        faulthandler.dump_traceback_later(evaluation_deadline(), exit=True, file=sys.stderr)
    except (AttributeError, OSError, RuntimeError, ValueError):
        return False
    return True


def main(argv: list[str] | None = None) -> int:
    _use_utf8_streams()
    parser = argparse.ArgumentParser(description="PreToolUse safety gate (policy: dangerous_patterns.conf)")
    parser.add_argument("--protocol", choices=PROTOCOLS, default="claude")
    args = parser.parse_args(argv)
    try:
        payload = _read_payload()
    except Exception as exc:  # noqa: BLE001 - an unreadable payload must fail closed
        return _fail_closed(f"无法读取 hook 输入，已按失败关闭拦截：{exc}")
    if payload is None:
        return _fail_closed("hook 输入为空或不是 JSON 对象，无法判定工具，已按失败关闭拦截")
    tool_name = payload.get("tool_name")
    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        tool_input = {}
    session_cwd = payload.get("cwd")
    armed = _arm_watchdog()
    try:
        cwd = session_cwd if isinstance(session_cwd, str) and session_cwd.strip() else os.getcwd()
        decision = evaluate(tool_name, tool_input, load_rules(), cwd=cwd)
    except Exception as exc:  # noqa: BLE001 - any failure must fail closed for guarded tools
        if _is_guarded(tool_name):
            return _fail_closed(f"安全门无法判定，已按失败关闭拦截：{exc}")
        return 0
    finally:
        if armed:
            faulthandler.cancel_dump_traceback_later()
    if decision is not None:
        print(json.dumps(render(decision, args.protocol), ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
