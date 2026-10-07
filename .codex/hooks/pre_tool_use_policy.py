#!/usr/bin/env python3
"""Codex PreToolUse adapter for the shared gx_ghostty safety gate.

Loads .claude/hooks/pre_tool_use_gate.py from the same checkout and runs it with
the Codex protocol, which never answers "ask" (ask-level rules become deny).
Codex registers this hook for Bash and apply_patch only, so a missing or broken
gate, an unreadable payload or any unexpected error fails closed with exit 2 and
the reason on stderr; Codex treats exit 2 with a stderr reason as a block.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

GATE_PATH = Path(__file__).resolve().parents[2] / ".claude" / "hooks" / "pre_tool_use_gate.py"


def _fail_closed(message: str) -> int:
    reconfigure = getattr(sys.stderr, "reconfigure", None)
    if reconfigure is not None:
        reconfigure(encoding="utf-8", errors="replace")
    print(f"pre_tool_use_policy: {message}", file=sys.stderr)
    return 2


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    sys.dont_write_bytecode = True
    try:
        spec = importlib.util.spec_from_file_location("gx_ghostty_pre_tool_use_gate", GATE_PATH)
        if spec is None or spec.loader is None:
            raise ImportError(f"cannot load {GATE_PATH}")
        gate = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = gate
        spec.loader.exec_module(gate)
    except Exception as exc:  # noqa: BLE001 - the hook must fail closed, never crash open
        return _fail_closed(f"共享安全门不可用，已按失败关闭拦截：{exc}")
    try:
        return gate.main(["--protocol", "codex", *args])
    except Exception as exc:  # noqa: BLE001 - an unexpected gate error must still block
        return _fail_closed(f"共享安全门运行出错，已按失败关闭拦截：{exc}")


if __name__ == "__main__":
    raise SystemExit(main())
