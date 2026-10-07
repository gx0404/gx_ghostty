#!/usr/bin/env python3
"""Probes for the shared PreToolUse safety gate and the per-client AI tool configs.

Every probe is a side-effect-free JSON payload; nothing dangerous is executed.
Dangerous literals are assembled from fragments so that a host session guarded
by the same policy does not block this file or the commands that run it.
"""

from __future__ import annotations

import ast
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from functools import lru_cache
from pathlib import Path

try:
    import tomllib
except ModuleNotFoundError:  # Python 3.10
    import tomli as tomllib  # type: ignore[no-redef]

REPO_ROOT = Path(__file__).resolve().parents[1]
HOOKS_DIR = REPO_ROOT / ".claude" / "hooks"
GATE_PATH = HOOKS_DIR / "pre_tool_use_gate.py"
CONF_PATH = HOOKS_DIR / "dangerous_patterns.conf"
WRAPPER_PATH = HOOKS_DIR / "block_dangerous.sh"
CODEX_ADAPTER_PATH = REPO_ROOT / ".codex" / "hooks" / "pre_tool_use_policy.py"
CLAUDE_SETTINGS = REPO_ROOT / ".claude" / "settings.json"
CLAUDE_RULES_DIR = REPO_ROOT / ".claude" / "rules"
CLAUDE_REVIEWER = REPO_ROOT / ".claude" / "agents" / "code-reviewer.md"
CODEX_CONFIG = REPO_ROOT / ".codex" / "config.toml"
ZCODE_CONFIG = REPO_ROOT / ".zcode" / "config.json"

TOPLEVEL = "$(git rev-parse --show-toplevel)"
# Claude Code exports CLAUDE_PROJECT_DIR to hooks; the git fallback only works inside the checkout.
CLAUDE_ROOT = "${CLAUDE_PROJECT_DIR:-" + TOPLEVEL + "}"
# Exit 2 blocks in every client; any other failure (127 when the script or interpreter is
# missing) would be a non-blocking hook error, so the registered commands normalize it to 2.
FAIL_CLOSED = " || exit 2"
CLAUDE_HOOK_COMMAND = f'bash "{CLAUDE_ROOT}/.claude/hooks/block_dangerous.sh"{FAIL_CLOSED}'
ZCODE_HOOK_COMMAND = f'bash "{TOPLEVEL}/.claude/hooks/block_dangerous.sh"{FAIL_CLOSED}'
CODEX_HOOK_COMMAND = f'python3 "{TOPLEVEL}/.codex/hooks/pre_tool_use_policy.py"{FAIL_CLOSED}'
# Codex runs command_windows through PowerShell: 5.1 rejects "||" and 7 ends every failure
# with exit 1, so the Windows form checks $? (python3 not found leaves $LASTEXITCODE unset)
# and $LASTEXITCODE itself.
CODEX_WINDOWS_HOOK_COMMAND = (
    f'python3 "{TOPLEVEL}/.codex/hooks/pre_tool_use_policy.py"; if (-not $? -or $LASTEXITCODE -ne 0) {{ exit 2 }}'
)
CLIENT_MATCHER = "Bash|Edit|Write|MultiEdit|NotebookEdit"
CODEX_MATCHER = "^(Bash|apply_patch)$"
COMMAND_POSITION = "(?m)(?:^|[;&|(){`]|\\$\\()[ \\t]*(?:(?:if|elif|while|until|then|do|else|!)[ \\t]+)*"
WRITE_TOOLS = ("Edit", "Write", "MultiEdit", "NotebookEdit")
# Keys allowed by the PreToolUse output schema embedded in Codex 0.160
# ("additionalProperties": false on both levels); anything else fails the hook open.
CODEX_OUTPUT_KEYS = {"continue", "decision", "hookSpecificOutput", "reason", "stopReason", "suppressOutput", "systemMessage"}
CODEX_SPECIFIC_KEYS = {"additionalContext", "hookEventName", "permissionDecision", "permissionDecisionReason", "updatedInput"}

GIT = "gi" + "t"
PUSH = "pu" + "sh"
FORCE = "--for" + "ce"
LEASE = "--force-with-" + "lease"
NO_VERIFY = "--no-" + "verify"
GH = "g" + "h"
PKILL = "pk" + "ill"
KILLALL = "kill" + "all"
WINGET = "win" + "get"
CHOCO = "cho" + "co"
SCOOP = "sco" + "op"
MSIEXEC = "msi" + "exec"
DOT_ENV = "." + "env"
DOT_SSH = ".s" + "sh"
SSH_DIR = "~/" + DOT_SSH
HOOKS_PATH = "core.hooks" + "Path"
APPLY_PATCH = "apply" + "_patch"
FORCE_PUSH = f"{GIT} {PUSH} {FORCE} origin main"
HARD_RESET = f"{GIT} reset --hard HEAD~1"


def _patch(*headers: str) -> str:
    """A minimal apply_patch envelope; each header line is followed by one hunk line."""
    body = [line for header in headers for line in (header, "+x")]
    return "\n".join(["*** Begin Patch", *body, "*** End Patch"]) + "\n"


SHELL_DENY = [
    FORCE_PUSH,
    f"{GIT} {PUSH} -f",
    f"{GIT} {PUSH} -fu origin main",
    f"{GIT} {PUSH} origin +main",
    f"{GIT} {PUSH} --mirror origin",
    f"just ci-check && {GIT} {PUSH} origin main {FORCE}",
    f"cd /tmp && {GIT} {PUSH} origin main {FORCE}; echo done",
    f"sudo {GIT} {PUSH} -f origin main",
    f"echo main | xargs {GIT} {PUSH} -f origin",
    f"bash -c '{GIT} {PUSH} {FORCE}'",
    f'sh -c "{GIT} {PUSH} -f origin main"',
    f"GIT_TRACE=1 {GIT} {PUSH} -f",
    f"env GIT_TRACE=1 {GIT} {PUSH} -f",
    f"timeout 30 {GIT} {PUSH} {FORCE}",
    f"bash <<'EOF'\n{GIT} {PUSH} {FORCE}\nEOF",
    f"{GIT} -C /tmp/x {PUSH} -f origin main",
    f'{GIT} -C "D:/my repo" {PUSH} -f origin main',
    f"{GIT} -c core.x=y {PUSH} {FORCE}",
    f"/usr/bin/{GIT} {PUSH} -f",
    "C:\\Git\\cmd\\" + f"{GIT}.exe {PUSH} -f",
    f"echo `{GIT} {PUSH} -f`",
    f'{GIT} commit -m "fix $({GIT} {PUSH} -f)"',
    f"for b in a; do {GIT} {PUSH} -f origin $b; done",
    # Shell keywords and case arms put the next word in command position.
    f"if {GIT} {PUSH} -f origin x; then :; fi",
    f"if false; then :; elif {GIT} {PUSH} -f origin x; then :; fi",
    f"while {GIT} {PUSH} -f origin x; do :; done",
    f"until {GIT} {PUSH} -f origin x; do :; done",
    f"! {GIT} {PUSH} -f origin x",
    f"if ! {GIT} {PUSH} {FORCE}; then :; fi",
    f"case x in *) {GIT} {PUSH} -f ;; esac",
    f"case x in a) :;; b) {GIT} {PUSH} -f ;; esac",
    # Line continuations are joined before matching (bash backslash, PowerShell backtick).
    f"{GIT} {PUSH} \\\n  {FORCE} origin gx_ghostty",
    f"{GIT} {PUSH} \\\r\n  {FORCE} origin gx_ghostty",
    f"{GIT} pu\\\nsh -f origin x",
    f"{GH} release \\\n  create gx-v1.0.0",
    f"{GIT} {PUSH} `\n  {FORCE} origin x",
    f"echo a \\\\\n{GIT} {PUSH} -f",
    f"{GIT} {PUSH} upstream",
    f"{GIT} --no-pager {PUSH} upstream main",
    f"{GIT} {PUSH} -u upstream feature/x",
    f"{GIT} {PUSH} https://github.com/ghostty-org/ghostty.git main",
    f"{GIT} {PUSH} git@github.com:Ghostty-Org/Ghostty.git main",
    f"{GIT} {PUSH} upstream --delete x",
    f"{GIT} commit {NO_VERIFY} -m x",
    f"{GIT} commit -n -m x",
    f"{GIT} commit -nm x",
    f'{GIT} commit -m "msg" -n',
    f"if true; then {GIT} commit -m x {NO_VERIFY}; fi",
    f"{GIT} merge {NO_VERIFY} main",
    f"{GIT} -c {HOOKS_PATH}=/dev/null commit -m x",
    f"{GIT} -c core.autocrlf=false -c core.hookspath= commit -m x",
    f"{GIT} --config-env={HOOKS_PATH}=HP commit -m x",
    f"{GIT} add -f .claude/settings.local.json",
    f"{GIT} add --force x",
    f"{GIT} add -Af",
    f"{GIT} filter-branch --all",
    f"{GIT} filter-repo --path x",
    f"{GIT} replace a b",
    f"{GIT} reflog expire --expire=now --all",
    f"{GH} issue create --title x",
    f"{GH} issue new",
    f"{GH} pr create --fill",
    f"{GH} pr new",
    f"{GH} pr merge 12",
    f"{GH} -R ghostty-org/ghostty pr create",
    f"bash -c '{GH} pr merge 1'",
    f"{GH} release create gx-v0.1.0",
    f"{GH} release delete-asset gx-v0.1.0 a.tar.gz",
    f"GH_TOKEN=x {GH} release upload gx-v0.1.0 a.tar.gz",
    f"{GH} workflow run gx-release.yml -f publish=true",
    f"{GH} -R gx0404/gx_ghostty workflow run gx-release.yml --ref gx_ghostty",
    f"{GH} api -X POST repos/gx0404/gx_ghostty/releases -f tag_name=gx-v1.0.0",
    f"{GH} api repos/gx0404/gx_ghostty/actions/workflows/gx-release.yml/dispatches -f ref=gx_ghostty",
    f"{GH} api --method DELETE repos/gx0404/gx_ghostty/git/refs/tags/gx-v1.0.0",
    f"{GH} api -XPATCH repos/o/r/releases/1 -F draft=false",
    f"{GH} api --method=put repos/o/r/actions/workflows/1/enable",
    f"cat {SSH_DIR}/id_rsa",
    f"cat {SSH_DIR}/config",
    f"cat {DOT_SSH}/config",
    f"cat {DOT_ENV}",
    f"cat config/{DOT_ENV}.local",
    f"cp {DOT_ENV} /tmp/x",
    "base64 server.pem",
    # Readers beyond the POSIX pagers: search tools, interpreters and PowerShell cmdlets.
    "Get-Content -Raw C:\\Users\\x\\" + DOT_SSH + "\\id_ed25519",
    f"rg -n TOKEN {DOT_ENV}",
    f"grep . {DOT_ENV}",
    f"python -c \"print(open('{DOT_ENV}').read())\"",
    f"node -e \"require('fs').readFileSync('{DOT_ENV}')\"",
    f"sed -n 1p {DOT_ENV}.local",
    f"awk 1 {DOT_ENV}",
    f"type {DOT_ENV}",
    f"Select-String -Path {DOT_ENV} -Pattern TOKEN",
    f"Copy-Item {SSH_DIR}/id_rsa C:/tmp/k",
    f"{WINGET} install Zig.Zig",
    f"{CHOCO} install zig",
    f"{SCOOP} install zig",
    f"{WINGET} upgrade --all",
    f"{WINGET} update Zig.Zig",
    f"{CHOCO} upgrade zig",
    f"{SCOOP} update zig",
    f"{MSIEXEC} /i foo.msi",
    f"{MSIEXEC} /qn /i foo.msi",
    f"just setup && {WINGET} install Perl",
    "echo x > graphify-out/GRAPH_REPORT.md",
    "echo x >> ./docs/kb/chunks.json",
    "echo x > .\\docs\\kb\\chunks.json",
    "sed -i s/a/b/ docs/kb/chunks.json",
    "cat x | tee build.zig.zon.json",
    "Set-Content -Path docs/kb/chunks.json -Value x",
    "'x' | Out-File -FilePath graphify-out\\GRAPH_REPORT.md",
    "add-content docs\\kb\\chunks.json x",
    "sed --in-place s/a/b/ docs/kb/chunks.json",
    "cp /tmp/chunks.json docs/kb/chunks.json",
    "cp x graphify-out/GRAPH_REPORT.md",
    "mv /tmp/x build.zig.zon.json",
    "mv docs/kb/chunks.json /tmp/",
    "Copy-Item C:\\tmp\\x docs\\kb\\chunks.json",
    "Move-Item x flatpak\\zig-packages.json",
    f"{APPLY_PATCH} <<'EOF'\n{_patch('*** Update File: docs/kb/chunks.json')}EOF",
    # PowerShell and WSL wrappers.
    f'iex "{GIT} {PUSH} -f origin x"',
    f"Invoke-Expression '{GIT} {PUSH} {FORCE} origin x'",
    f'invoke-expression "{GH} pr create --fill"',
    f"wsl {GIT} {PUSH} -f origin x",
    f"wsl.exe -- {GIT} {PUSH} {FORCE}",
    f"wsl cat {SSH_DIR}/id_rsa",
    f"Start-Process {GIT} -ArgumentList '{PUSH} {FORCE}' -Wait",
    f'Start-Process -FilePath "{GIT}" -ArgumentList "{PUSH}","{FORCE}"',
    f"start-process {GH} 'release create gx-v1.0.0'",
    # Quoted command names, subcommands and force arguments.
    f'{GIT} {PUSH} origin "+HEAD:gx_ghostty"',
    f"{GIT} {PUSH} origin '+main'",
    f'{GIT} {PUSH} "{FORCE}"',
    f"{GIT} {PUSH} '-f' origin x",
    f'{GIT} "{PUSH}" -f',
    f'"{GIT}" {PUSH} -f',
    f'& "{GIT}" {PUSH} {FORCE}',
]
SHELL_ASK = [
    f"{GIT} {PUSH} {LEASE} origin x",
    f"{GIT} {PUSH} {LEASE}=main:abc origin main",
    f"{GIT} {PUSH} --delete origin feature/x",
    f"{GIT} {PUSH} origin --delete gx-v1.0.0",
    f"{GIT} {PUSH} -d origin x",
    f"{GIT} {PUSH} origin :feature/x",
    HARD_RESET,
    f"if true; then {HARD_RESET}; fi",
    f"{GIT} clean -fd",
    f"{GIT} clean -fdx",
    f"{PKILL} -9 zig",
    f"just build && {PKILL} zig",
    f"sudo {KILLALL} zig",
    f"pgrep zig | xargs -r {PKILL} -f",
    f"bash -c '{PKILL} zig'",
    f"bash <<'EOF'\n{PKILL} zig\nEOF",
    f"GX=1 {PKILL} zig",
    f"{GH} run rerun 123",
    f"{GH} run rerun 123 --failed",
    f"iex '{GIT} reset --hard'",
    f'{GIT} {PUSH} origin "--delete" x',
    f'{GIT} {PUSH} "{LEASE}"',
    # Setting or clearing core.hooksPath switches the repository hooks off.
    f"{GIT} config {HOOKS_PATH} .githooks",
    f"{GIT} config --global {HOOKS_PATH} ~/.hooks",
    f"{GIT} config set {HOOKS_PATH} /dev/null",
    f'{GIT} config {HOOKS_PATH} ""',
    f"{GIT} config --unset {HOOKS_PATH}",
    f"{GIT} config unset {HOOKS_PATH}",
    f"{GIT} config --local --unset-all core.hookspath",
    # Shell writes to the gate's own policy, adapters and client configs.
    "echo x > .claude/settings.json",
    "echo '{}' >> .claude/settings.local.json",
    "echo x > D:/gx_projects/gx_ghostty/.codex/hooks/x.py",
    "cat x | tee .codex/config.toml",
    "sed -i s/a/b/ .claude/hooks/dangerous_patterns.conf",
    "sed --in-place s/a/b/ .zcode/config.json",
    "Set-Content -Path .codex\\hooks\\pre_tool_use_policy.py -Value x",
    "'x' | Out-File .claude\\settings.json",
    "cp /tmp/x .claude/settings.json",
    "Copy-Item x .zcode\\config.json",
    "mv .claude/hooks /tmp/h",
    "rm -rf .claude/hooks",
    "rm -rf .claude",
    "rm .codex/config.toml",
    "Remove-Item -Recurse .claude\\hooks",
    "del .claude\\settings.local.json",
]
SHELL_ALLOW = [
    f"{GIT} status",
    f"{GIT} {PUSH} origin gx_ghostty",
    f"{GIT} {PUSH} -u origin feature/x",
    f"{GIT} {PUSH} origin feature-f",
    f"{GIT} {PUSH} --follow-tags origin",
    f"{GIT} {PUSH} origin upstream-sync",
    f"{GIT} {PUSH} --set-upstream origin x",
    f"{GIT} {PUSH} origin HEAD:refs/heads/x",
    f"{GIT} {PUSH} --dry-run origin feature-d",
    f"{GIT} fetch upstream",
    f"{GIT} pull upstream main",
    f"{GIT} merge --no-ff main -m 'chore(sync): 合并上游 main'",
    f'{GIT} commit -m "feat(ai): 新增安全门"',
    f"{GIT} commit --amend --no-edit",
    f"{GIT} commit -m 'docs: 解释为何禁止 {FORCE_PUSH} 与 {GH} release create'",
    f'{GIT} commit -m "docs: we do not {GIT} {PUSH} {FORCE}"',
    f'{GIT} commit -m "docs: never if {GIT} {PUSH} -f"',
    f'{GIT} commit -m "ci: 禁止 {NO_VERIFY} 与 -n"',
    f"{GIT} commit -F - <<'EOF'\nfeat: x\n\nbody mentions -n and {NO_VERIFY}\nEOF",
    f"{GIT} commit -m \"$(cat <<'EOF'\nfeat: x\n\nbody: 禁止 {FORCE_PUSH} 与 -n\nEOF\n)\"",
    f"{GIT} commit -m x \\\n  -m y",
    f"{GIT} -c core.autocrlf=false status",
    f"{GIT} add -A",
    f"{GIT} add --all",
    f"cd /tmp && {GIT} add -A",
    f"{GIT} clean -n",
    f"{GIT} reset --soft HEAD~1",
    f"rg '{FORCE_PUSH}' docs/",
    f"rg 'if {GIT} {PUSH} -f' docs/",
    f"rg '{GIT} {PUSH} -f' docs/ \\\n  --glob '*.md'",
    f"if rg -q '{GIT} {PUSH} -f' docs; then echo found; fi",
    f'rg "{GH} pr create" docs/',
    f"rg {PKILL} docs/",
    f"rg '{HOOKS_PATH}' docs/",
    f"python3 - <<'PYEOF'\ntext = '禁 {FORCE_PUSH}、{GH} pr create 与 {GIT} commit -n'\nprint(len(text))\nPYEOF",
    f"python3 - <<'PYEOF'\ntext = '禁 {PKILL}/猜 PID'\nPYEOF",
    f'echo "{PKILL} 与 {FORCE_PUSH} 都被拦截"',
    f'echo "! {GIT} {PUSH} -f"',
    f"echo 'while {GIT} {PUSH} -f; do'",
    f"echo 'avoid {WINGET} install here'",
    f"{WINGET} list",
    f"{SCOOP} list",
    f"{MSIEXEC} /?",
    "just ci-check",
    "python scripts/resolve_agent_rules.py --check",
    "python -m unittest scripts.test_ai_tool_hooks",
    "zig build test -Dtest-filter=Parser",
    f"{GH} run list",
    f"{GH} run view 123 --log",
    f"{GH} pr view 1",
    f"{GH} release view gx-v0.1.0",
    f"{GH} workflow list",
    f"{GH} workflow view gx-release.yml",
    f"{GH} workflow run gx-ci.yml",
    f'rg "{GH} workflow run gx-release" docs/',
    f"{GH} api repos/gx0404/gx_ghostty/releases/latest",
    f"{GH} api -X GET repos/o/r/releases -f per_page=100",
    f"{GH} api graphql -f query='{{ viewer {{ login }} }}'",
    "cat README.md",
    "head -n 5 .envrc",
    "rg -n envrc docs/",
    "rg -n TOKEN docs/",
    f"cat {DOT_ENV}.example",
    f"cat {SSH_DIR}/id_rsa.pub",
    f"Get-Content {SSH_DIR}/id_rsa.pub",
    "Get-Content README.md",
    "kill 1234",
    "cat graphify-out/GRAPH_REPORT.md",
    "sed -n 1p docs/kb/chunks.json",
    "Get-Content docs/kb/chunks.json",
    "Set-Content -Path docs/notes.md -Value x",
    "python scripts/build_agent_kb.py --confirm",
    f"{APPLY_PATCH} <<'EOF'\n{_patch('*** Update File: src/terminal/Terminal.zig')}EOF",
    f"cat > /tmp/x.patch <<'EOF'\n{_patch('*** Update File: docs/kb/chunks.json')}EOF",
    "cp docs/kb/chunks.json /tmp/chunks.json",
    "cp graphify-out/GRAPH_REPORT.md /tmp/",
    "Copy-Item docs\\kb\\chunks.json C:\\tmp\\x",
    "rg 'Invoke-Expression' docs/",
    f"echo 'wsl {GIT} {PUSH} -f'",
    "wsl --list --verbose",
    "Start-Process notepad",
    f'iex "{GIT} status"',
    f'{GIT} {PUSH} origin "feature/x"',
    f'{GIT} {PUSH} "origin" "gx_ghostty"',
    f'{GIT} {PUSH} origin "feature-f"',
    f'{GIT} commit -m "{FORCE} is banned"',
    f"{GIT} config {HOOKS_PATH}",
    f"{GIT} config --get {HOOKS_PATH}",
    f"{GIT} config get {HOOKS_PATH}",
    f"{GIT} config --unset core.autocrlf",
    f"rg '{GIT} config {HOOKS_PATH} .githooks' docs/",
    "just install-hooks",
    "cat .claude/settings.json",
    "cp .claude/settings.json /tmp/settings.json",
    "cp .codex/config.toml .codex/config.toml.bak",
    "sed -n 1p .claude/hooks/dangerous_patterns.conf",
    "Get-Content .codex\\config.toml",
    "echo x > .claude/README.md",
    "rm .claude/rules/old.md",
    f"{GIT} diff .claude/settings.json",
    "rg 'tee .claude/settings.json' docs/",
]
FILE_DENY = [
    "graphify-out/graph.json",
    "graphify-out/GRAPH_REPORT.md",
    "graphify-out/source-fingerprint.json",
    "docs/kb/chunks.json",
    ".local/toolchains/zig/zig-0.16.0/zig",
    "build.zig.zon.json",
    "build.zig.zon.nix",
    "build.zig.zon.txt",
    "flatpak/zig-packages.json",
    "vendor/glad/src/gl.c",
    ".github/workflows-archive/test.yml",
    DOT_ENV,
    f"config/{DOT_ENV}.local",
    "certs/server.pem",
    "id_ed25519",
]
# The safety gate's own policy, adapters and client hook/permission configs.
FILE_ASK = [
    ".claude/settings.json",
    ".claude/settings.local.json",
    ".claude/hooks/dangerous_patterns.conf",
    ".claude/hooks/pre_tool_use_gate.py",
    ".claude/hooks/block_dangerous.sh",
    ".codex/config.toml",
    ".codex/hooks/pre_tool_use_policy.py",
    ".zcode/config.json",
]
FILE_ALLOW = [
    "src/terminal/Terminal.zig",
    "docs/AGENT_RULES/routes.toml",
    "docs/kb/README.md",
    ".github/workflows-archive/README.md",
    ".github/workflows/gx-ci.yml",
    "vendor/nerd-fonts/README.md",
    "scripts/graphify.py",
    ".envrc",
    f"{DOT_ENV}.example",
    "id_ed25519.pub",
    ".claude/README.md",
    ".claude/rules/framework.md",
    ".claude/agents/code-reviewer.md",
    ".codex/README.md",
    ".codex/agents/gx-ghostty-reviewer.toml",
    ".zcode/README.md",
]
GIT_LONG_OPTIONS = (
    "--no-pager", "--literal-pathspecs", "--no-replace-objects", "--glob-pathspecs",
    "--noglob-pathspecs", "--icase-pathspecs", "--no-optional-locks", "--no-advice",
)


def _load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None, path
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


@lru_cache(maxsize=None)
def _gate():
    sys.dont_write_bytecode = True
    return _load_module("gx_ghostty_pre_tool_use_gate_under_test", GATE_PATH)


def _level(tool: str, tool_input: dict, **kwargs) -> str | None:
    gate = _gate()
    decision = gate.evaluate(tool, tool_input, gate.load_rules(), **kwargs)
    return None if decision is None else decision.level


def _run(argv: list[str], payload: dict | bytes, *, cwd: Path = REPO_ROOT, env: dict | None = None):
    data = payload if isinstance(payload, bytes) else json.dumps(payload).encode("utf-8")
    return subprocess.run(argv, input=data, capture_output=True, cwd=cwd, env=env, timeout=120, check=False)


def _decision(result: subprocess.CompletedProcess) -> dict | None:
    out = result.stdout.decode("utf-8").strip()
    return json.loads(out) if out else None


def _is_windows_launcher(path: str) -> bool:
    lowered = path.replace("\\", "/").lower()
    return "/windows/system32/" in lowered or "/windowsapps/" in lowered


@lru_cache(maxsize=None)
def find_bash() -> str | None:
    """Git Bash on Windows (never the WSL launcher), the PATH bash elsewhere."""
    candidate = shutil.which("bash")
    if candidate and not _is_windows_launcher(candidate):
        return candidate
    if os.name != "nt":
        return candidate
    try:
        exec_path = subprocess.run(
            ["git", "--exec-path"], capture_output=True, text=True, check=True, timeout=60
        ).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return None
    # <git>/{mingw64,ucrt64,...}/libexec/git-core -> <git>/bin/bash.exe or <git>/usr/bin/bash.exe
    base = Path(exec_path)
    for parent in [base, *base.parents][:5]:
        for relative in ("bin/bash.exe", "usr/bin/bash.exe"):
            if (parent / relative).is_file():
                return str(parent / relative)
    return None


def _bash_env(extra_path: Path | None = None, *, project_dir: str | None = None) -> dict:
    """Environment for running registered hook commands; CLAUDE_PROJECT_DIR only when given."""
    bash = find_bash()
    env = dict(os.environ)
    env.pop("CLAUDE_PROJECT_DIR", None)
    if project_dir is not None:
        env["CLAUDE_PROJECT_DIR"] = project_dir
    entries = [str(Path(bash).parent)] if bash else []
    if extra_path is not None:
        entries.insert(0, str(extra_path))
    env["PATH"] = os.pathsep.join([*entries, env.get("PATH", "")])
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    return env


def _write_shim(directory: Path, name: str, target: str) -> None:
    script = directory / name
    script.write_bytes(f'#!/bin/sh\nexec "{Path(target).as_posix()}" "$@"\n'.encode("utf-8"))
    script.chmod(0o755)


def _powershells() -> list[tuple[str, str]]:
    """(name, path) of Windows PowerShell 5.1 (Windows only) and PowerShell 7 when installed."""
    found: list[tuple[str, str]] = []
    if os.name == "nt":
        system_root = Path(os.environ.get("SystemRoot", r"C:\Windows"))
        legacy = shutil.which("powershell") or str(system_root / "System32" / "WindowsPowerShell" / "v1.0" / "powershell.exe")
        if Path(legacy).is_file():
            found.append(("powershell", legacy))
    pwsh = shutil.which("pwsh")
    if pwsh:
        found.append(("pwsh", pwsh))
    return found


def _path_without_python(directory: Path) -> str:
    """A PATH that still finds git but no python3/python (Git's own bin dirs ship no Python)."""
    git = shutil.which("git")
    assert git is not None, "git is required"
    if os.name == "nt":
        system_root = Path(os.environ.get("SystemRoot", r"C:\Windows"))
        return os.pathsep.join([str(Path(git).parent), str(system_root / "System32"), str(system_root)])
    _write_shim(directory, "git", git)
    return str(directory)


@lru_cache(maxsize=None)
def _toplevel() -> str:
    return subprocess.run(
        ["git", "rev-parse", "--show-toplevel"], cwd=REPO_ROOT, capture_output=True, text=True, check=True, timeout=60
    ).stdout.strip()


def _registered_commands() -> list[tuple[str, str]]:
    """(client, command) for every PreToolUse hook registered in the three configs."""
    commands: list[tuple[str, str]] = []
    claude = json.loads(CLAUDE_SETTINGS.read_text(encoding="utf-8"))
    for block in claude["hooks"]["PreToolUse"]:
        commands += [("claude", hook["command"]) for hook in block["hooks"]]
    zcode = json.loads(ZCODE_CONFIG.read_text(encoding="utf-8"))
    for block in zcode["hooks"]["events"]["PreToolUse"]:
        commands += [("zcode", hook["command"]) for hook in block["hooks"]]
    codex = tomllib.loads(CODEX_CONFIG.read_text(encoding="utf-8"))
    for block in codex["hooks"]["PreToolUse"]:
        commands += [("codex", hook["command"]) for hook in block["hooks"]]
    return commands


def _script_of(command: str) -> tuple[str, Path]:
    expanded = command.replace(CLAUDE_ROOT, _toplevel()).replace(TOPLEVEL, _toplevel())
    match = re.fullmatch(r'(bash|python3?) "([^"]+)" \|\| exit 2', expanded)
    if match is None:
        raise AssertionError(f"unrecognized hook command: {command}")
    return match.group(1), Path(match.group(2))


@lru_cache(maxsize=None)
def _git_visible_files() -> tuple[str, ...]:
    out = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=REPO_ROOT, capture_output=True, check=True, timeout=120,
    ).stdout
    return tuple(item.decode("utf-8") for item in out.split(b"\0") if item)


def _glob_regex(pattern: str) -> re.Pattern[str]:
    out, i = [], 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
        elif pattern.startswith("**", i):
            out.append(".*")
            i += 2
        elif pattern[i] == "*":
            out.append("[^/]*")
            i += 1
        elif pattern[i] == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(pattern[i]))
            i += 1
    return re.compile("".join(out) + r"\Z")


def _frontmatter(path: Path) -> tuple[dict, str]:
    lines = path.read_text(encoding="utf-8").splitlines()
    if not lines or lines[0] != "---":
        raise AssertionError(f"{path} has no frontmatter")
    end = lines.index("---", 1)
    meta: dict = {}
    key = None
    for line in lines[1:end]:
        item = re.match(r'^\s+-\s+"?([^"]+?)"?\s*$', line)
        field = re.match(r"^([A-Za-z][\w-]*):\s*(.*)$", line)
        if field:
            key, value = field.group(1), field.group(2).strip()
            meta[key] = value if value else []
        elif item and key is not None:
            meta[key].append(item.group(1))
    return meta, "\n".join(lines[end + 1:]).strip()


class PolicyFileTests(unittest.TestCase):
    def setUp(self) -> None:
        self.gate = _gate()
        self.rules = self.gate.load_rules()

    def test_policy_loads_with_both_sections_and_levels(self) -> None:
        self.assertGreaterEqual(len(self.rules), 30)
        self.assertEqual({"SHELL", "FILE"}, {rule.section for rule in self.rules})
        self.assertEqual({"deny", "ask"}, {rule.level for rule in self.rules})
        self.assertEqual({"deny", "ask"}, {rule.level for rule in self.rules if rule.section == "FILE"})
        for rule in self.rules:
            self.assertTrue(rule.reason.strip(), rule.line_no)

    def test_shell_rules_are_anchored_at_command_position(self) -> None:
        for rule in self.rules:
            if rule.section != "SHELL":
                continue
            regex = rule.pattern.pattern
            with self.subTest(line=rule.line_no):
                if regex.startswith(">"):
                    continue  # redirection has no command position to anchor
                self.assertTrue(regex.startswith(COMMAND_POSITION), regex[:60])
                self.assertIn("^", regex.replace("[^", ""))

    def test_shell_rules_share_one_prefix_including_wrappers(self) -> None:
        anchored = [r.pattern.pattern for r in self.rules if r.section == "SHELL" and not r.pattern.pattern.startswith(">")]
        shared = os.path.commonprefix(anchored)
        self.assertTrue(shared.startswith(COMMAND_POSITION))
        self.assertIn("(?:sudo|", shared)
        self.assertIn("|pwsh|wsl|(?i:iex|invoke-expression|start-process))", shared)

    def test_option_skipping_is_unambiguous(self) -> None:
        # "-{1,2}[\w-]+" splits "--x" two ways and backtracks exponentially; a hook timeout allows the call.
        for rule in self.rules:
            with self.subTest(line=rule.line_no):
                self.assertNotIn("-{1,2}", rule.pattern.pattern)

    def test_file_rules_ignore_case(self) -> None:
        for rule in self.rules:
            if rule.section == "FILE":
                self.assertTrue(rule.pattern.flags & re.IGNORECASE, rule.line_no)

    def test_crlf_and_bom_copy_parses_identically(self) -> None:
        text = CONF_PATH.read_text(encoding="utf-8-sig").replace("\r\n", "\n")
        with tempfile.TemporaryDirectory() as tmp:
            crlf = Path(tmp) / "dangerous_patterns.conf"
            crlf.write_bytes(("\ufeff" + text.replace("\n", "\r\n")).encode("utf-8"))
            parsed = self.gate.load_rules(crlf)
        summary = [(r.section, r.pattern.pattern, r.reason, r.level, r.line_no) for r in self.rules]
        self.assertEqual(summary, [(r.section, r.pattern.pattern, r.reason, r.level, r.line_no) for r in parsed])

    def test_malformed_policies_are_rejected(self) -> None:
        cases = {
            "three columns": "SHELL\tfoo\treason\n",
            "bad level": "SHELL\tfoo\treason\tblock\n",
            "bad section": "PATH\tfoo\treason\tdeny\n",
            "bad regex": "SHELL\t(foo\treason\tdeny\n",
            "empty reason": "SHELL\tfoo\t \tdeny\n",
            "no rules": "# only a comment\n\n",
        }
        with tempfile.TemporaryDirectory() as tmp:
            for name, text in cases.items():
                with self.subTest(case=name):
                    conf = Path(tmp) / f"{name}.conf"
                    conf.write_text(text, encoding="utf-8")
                    with self.assertRaises(self.gate.PolicyError):
                        self.gate.load_rules(conf)
            with self.assertRaises(self.gate.PolicyError):
                self.gate.load_rules(Path(tmp) / "missing.conf")


class ShellProbeTests(unittest.TestCase):
    """Paired probes: real execution is gated, text that only mentions a command is not."""

    def test_real_execution_is_denied(self) -> None:
        for command in SHELL_DENY:
            with self.subTest(command=command):
                self.assertEqual("deny", _level("Bash", {"command": command}))

    def test_risky_execution_asks(self) -> None:
        for command in SHELL_ASK:
            with self.subTest(command=command):
                self.assertEqual("ask", _level("Bash", {"command": command}))

    def test_text_mentions_and_routine_commands_pass(self) -> None:
        for command in SHELL_ALLOW:
            with self.subTest(command=command):
                self.assertIsNone(_level("Bash", {"command": command}))

    def test_deny_wins_over_ask(self) -> None:
        self.assertEqual("deny", _level("Bash", {"command": f"{PKILL} zig; {FORCE_PUSH}"}))
        self.assertEqual("deny", _level("Bash", {"command": f"{HARD_RESET} && {FORCE_PUSH}"}))

    def test_argv_style_command_is_joined(self) -> None:
        self.assertEqual("deny", _level("Bash", {"command": [GIT, PUSH, FORCE]}))
        self.assertEqual("deny", _level("Bash", {"command": ["bash", "-lc", FORCE_PUSH]}))
        self.assertEqual("deny", _level("Bash", {"command": ["powershell.exe", "-Command", f"Get-Content {DOT_ENV}"]}))

    def test_line_continuations_are_joined_without_losing_the_original(self) -> None:
        gate = _gate()
        self.assertEqual(
            [f"{GIT} {PUSH} \\\n  -f", f"{GIT} {PUSH}   -f"], gate.shell_variants(f"{GIT} {PUSH} \\\n  -f")
        )
        # An even run of backslashes is literal, so the newline still separates commands.
        self.assertEqual(["a \\\\\nb"], gate.shell_variants("a \\\\\nb"))
        self.assertEqual(["a\n`` \nb"], gate.shell_variants("a\n`` \nb"))
        self.assertEqual(["x `\ny", "x y"], gate.shell_variants("x `\ny"))

    def test_long_option_runs_do_not_backtrack(self) -> None:
        options = " ".join(GIT_LONG_OPTIONS[i % len(GIT_LONG_OPTIONS)] for i in range(40))
        for command in (
            f"{GIT} {options} status; {GIT} {PUSH} -f",
            f"{GH} {options} pr view 1; {GH} pr merge 1",
            f"{GIT} {options} commit -m x; {GIT} {PUSH} upstream",
        ):
            with self.subTest(command=command[:40]):
                started = time.perf_counter()
                level = _level("Bash", {"command": command})
                self.assertLess(time.perf_counter() - started, 1.0, "the hook timeout (30 s) would allow the call")
                self.assertEqual("deny", level)

    def test_tool_names_are_case_insensitive_and_unguarded_tools_pass(self) -> None:
        self.assertEqual("deny", _level("bash", {"command": FORCE_PUSH}))
        self.assertIsNone(_level("Read", {"file_path": str(REPO_ROOT / DOT_ENV)}))
        self.assertIsNone(_level("Grep", {"pattern": FORCE_PUSH}))
        self.assertIsNone(_level("Bash", {}))


class FileProbeTests(unittest.TestCase):
    def _forms(self, relative: str) -> list[str]:
        absolute = REPO_ROOT / relative
        forms = [relative, "./" + relative, str(absolute), absolute.as_posix(), str(absolute).upper()]
        if os.name == "nt":
            posix = absolute.as_posix()
            forms += [posix.replace("/", "\\"), f"/{posix[0].lower()}{posix[2:]}"]
        return forms

    def test_protected_paths_are_denied_for_every_write_tool(self) -> None:
        for relative in FILE_DENY:
            for form in self._forms(relative):
                for tool in WRITE_TOOLS:
                    key = "notebook_path" if tool == "NotebookEdit" else "file_path"
                    with self.subTest(tool=tool, path=form):
                        self.assertEqual("deny", _level(tool, {key: form}, cwd=REPO_ROOT))

    def test_gate_and_client_configs_ask_for_every_write_tool(self) -> None:
        for relative in FILE_ASK:
            for form in self._forms(relative):
                for tool in WRITE_TOOLS:
                    key = "notebook_path" if tool == "NotebookEdit" else "file_path"
                    with self.subTest(tool=tool, path=form):
                        self.assertEqual("ask", _level(tool, {key: form}, cwd=REPO_ROOT))

    def test_kimi_style_path_key_is_gated(self) -> None:
        # Kimi Code's Write/Edit tools name the target "path" instead of "file_path".
        for tool in ("Write", "Edit"):
            with self.subTest(tool=tool):
                self.assertEqual("deny", _level(tool, {"path": str(REPO_ROOT / "docs" / "kb" / "chunks.json")}))
                self.assertIsNone(_level(tool, {"path": str(REPO_ROOT / "docs" / "kb" / "README.md")}))

    def test_ordinary_paths_pass(self) -> None:
        for relative in FILE_ALLOW:
            for form in (relative, str(REPO_ROOT / relative)):
                with self.subTest(path=form):
                    self.assertIsNone(_level("Write", {"file_path": form}, cwd=REPO_ROOT))

    def test_written_content_is_not_parsed_as_a_patch(self) -> None:
        content = _patch("*** Update File: docs/kb/chunks.json")
        self.assertIsNone(_level("Write", {"file_path": "docs/notes.md", "content": content}, cwd=REPO_ROOT))

    def test_relative_paths_resolve_against_the_session_cwd(self) -> None:
        self.assertEqual("deny", _level("Edit", {"file_path": "kb/chunks.json"}, cwd=REPO_ROOT / "docs"))
        self.assertEqual("deny", _level("Edit", {"file_path": f"../{REPO_ROOT.name}/graphify-out/x"}, cwd=REPO_ROOT))
        self.assertIsNone(_level("Edit", {"file_path": "kb/README.md"}, cwd=REPO_ROOT / "docs"))

    def test_outside_checkout_only_unanchored_rules_apply(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            outside = Path(tmp)
            self.assertIsNone(_level("Write", {"file_path": str(outside / "graphify-out" / "x.json")}))
            self.assertEqual("deny", _level("Write", {"file_path": str(outside / DOT_ENV)}))

    def test_repo_relative_normalization(self) -> None:
        gate = _gate()
        self.assertEqual("docs/kb/chunks.json", gate.repo_relative(str(REPO_ROOT / "docs" / "kb" / "chunks.json")))
        self.assertEqual(".", gate.repo_relative(str(REPO_ROOT)))
        if os.name == "nt":
            posix = REPO_ROOT.as_posix()
            self.assertEqual("src/x.zig", gate.repo_relative(f"/{posix[0].lower()}{posix[2:]}/src/x.zig"))
            self.assertEqual("src/x.zig", gate.repo_relative("\\\\?\\" + str(REPO_ROOT / "src" / "x.zig")))


class PatchProbeTests(unittest.TestCase):
    """Codex edits through apply_patch; FILE rules apply to the paths named in its headers."""

    def test_patch_targets_come_from_every_header_in_any_string(self) -> None:
        gate = _gate()
        payload = {
            "input": _patch("*** Add File: a.txt", "*** Update File: b.zig", "*** Move to: c/d.zig"),
            "nested": [{"x": _patch("*** Delete File: e f.md")}],
            "count": 3,
        }
        self.assertEqual(["a.txt", "b.zig", "c/d.zig", "e f.md"], gate.patch_targets(payload))
        self.assertEqual(["x.zig"], gate.patch_targets("*** Begin Patch\r\n*** Update File: x.zig \r\n*** End Patch\r\n"))
        self.assertEqual([], gate.patch_targets({"command": "rg '*** Update File: docs/kb/chunks.json'"}))

    def test_generated_and_secret_targets_are_denied(self) -> None:
        cases = [
            {"command": _patch("*** Update File: docs/kb/chunks.json")},
            {"input": _patch("*** Update File: src/x.zig", "*** Move to: graphify-out/x.json")},
            {"patch": _patch("*** Delete File: build.zig.zon.json")},
            {"command": [APPLY_PATCH, _patch("*** Add File: config/" + DOT_ENV + ".local")]},
            {"input": _patch("*** Update File: " + str(REPO_ROOT / "vendor" / "glad" / "src" / "gl.c"))},
            {"input": _patch("*** Update File: src/terminal/Terminal.zig", "*** Update File: docs/kb/chunks.json")},
        ]
        for tool_input in cases:
            with self.subTest(tool_input=tool_input):
                self.assertEqual("deny", _level(APPLY_PATCH, tool_input, cwd=REPO_ROOT))
        self.assertEqual("deny", _level("Apply_Patch", cases[0], cwd=REPO_ROOT))
        self.assertEqual("deny", _level(APPLY_PATCH, {"input": _patch("*** Update File: kb/chunks.json")}, cwd=REPO_ROOT / "docs"))

    def test_gate_configs_ask_and_ordinary_targets_pass(self) -> None:
        self.assertEqual("ask", _level(APPLY_PATCH, {"input": _patch("*** Add File: .claude/hooks/x.py")}, cwd=REPO_ROOT))
        self.assertEqual("ask", _level(APPLY_PATCH, {"input": _patch("*** Update File: .codex/config.toml")}, cwd=REPO_ROOT))
        for tool_input in (
            {"input": _patch("*** Update File: src/terminal/Terminal.zig")},
            {"command": _patch("*** Add File: docs/notes.md", "*** Delete File: scripts/old.py")},
            {"command": "no patch headers here"},
            {},
        ):
            with self.subTest(tool_input=tool_input):
                self.assertIsNone(_level(APPLY_PATCH, tool_input, cwd=REPO_ROOT))


class ProtocolTests(unittest.TestCase):
    """Run the gate as a process and check both client protocols byte for byte."""

    def _gate_run(self, protocol: str, tool: str, tool_input: dict):
        return _run([sys.executable, str(GATE_PATH), "--protocol", protocol], {"tool_name": tool, "tool_input": tool_input})

    def test_claude_protocol_reports_deny_and_ask(self) -> None:
        for command, expected in ((FORCE_PUSH, "deny"), (HARD_RESET, "ask")):
            with self.subTest(expected=expected):
                result = self._gate_run("claude", "Bash", {"command": command})
                self.assertEqual(0, result.returncode, result.stderr)
                payload = _decision(result)
                specific = payload["hookSpecificOutput"]
                self.assertEqual({"hookSpecificOutput"}, set(payload))
                self.assertEqual("PreToolUse", specific["hookEventName"])
                self.assertEqual(expected, specific["permissionDecision"])
                self.assertTrue(specific["permissionDecisionReason"].strip())

    def test_codex_protocol_never_asks_and_fits_the_codex_schema(self) -> None:
        cases = (
            ("Bash", {"command": FORCE_PUSH}),
            ("Bash", {"command": HARD_RESET}),
            (APPLY_PATCH, {"input": _patch("*** Update File: docs/kb/chunks.json")}),
            (APPLY_PATCH, {"input": _patch("*** Update File: .codex/config.toml")}),
        )
        for tool, tool_input in cases:
            with self.subTest(tool=tool, tool_input=tool_input):
                result = self._gate_run("codex", tool, tool_input)
                self.assertEqual(0, result.returncode, result.stderr)
                payload = _decision(result)
                self.assertLessEqual(set(payload), CODEX_OUTPUT_KEYS)
                specific = payload["hookSpecificOutput"]
                self.assertLessEqual(set(specific), CODEX_SPECIFIC_KEYS)
                self.assertEqual("PreToolUse", specific["hookEventName"])
                self.assertEqual("deny", specific["permissionDecision"])
                self.assertTrue(specific["permissionDecisionReason"].strip())
                self.assertNotIn('"ask"', result.stdout.decode("utf-8"))
        asked = _decision(self._gate_run("codex", "Bash", {"command": HARD_RESET}))
        self.assertIn("不支持 ask", asked["hookSpecificOutput"]["permissionDecisionReason"])

    def test_allowed_calls_print_nothing(self) -> None:
        for protocol in ("claude", "codex"):
            for tool, tool_input in (("Bash", {"command": f"{GIT} status"}), (APPLY_PATCH, {"input": _patch("*** Add File: x.md")})):
                with self.subTest(protocol=protocol, tool=tool):
                    result = self._gate_run(protocol, tool, tool_input)
                    self.assertEqual((0, b""), (result.returncode, result.stdout), result.stderr)

    def test_unreadable_payload_fails_closed(self) -> None:
        # The hooks are registered for guarded tools only, so a payload that is not a JSON object blocks.
        for script in (GATE_PATH, CODEX_ADAPTER_PATH):
            for raw in (b"not json", b"[]", b"null", b'"Bash"', b"", b"\n", "\u00ff".encode("latin-1")):
                with self.subTest(script=script.name, raw=raw):
                    result = _run([sys.executable, str(script)], raw)
                    self.assertEqual(2, result.returncode)
                    self.assertEqual(b"", result.stdout)
                    self.assertTrue(result.stderr.strip())

    def test_bad_arguments_fail_closed(self) -> None:
        for script in (GATE_PATH, CODEX_ADAPTER_PATH):
            with self.subTest(script=script.name):
                result = _run([sys.executable, str(script), "--no-such-option"], {"tool_name": "Bash"})
                self.assertEqual(2, result.returncode)
                self.assertEqual(b"", result.stdout)

    def test_slow_evaluation_ends_before_the_client_timeout(self) -> None:
        # A hook timeout allows the call, so the watchdog must end a pathological evaluation
        # first; the registered commands turn its non-zero status into a blocking 2.
        gate = _gate()
        self.assertLessEqual(2 * gate.EVALUATION_DEADLINE_SECONDS + 5, 30, "block_dangerous.sh may try two interpreters")
        runner = (
            "import importlib.util, sys\n"
            "sys.dont_write_bytecode = True\n"
            "spec = importlib.util.spec_from_file_location('gate', sys.argv[1])\n"
            "gate = importlib.util.module_from_spec(spec)\n"
            "spec.loader.exec_module(gate)\n"
            "gate.EVALUATION_DEADLINE_SECONDS = 0.5\n"
            "raise SystemExit(gate.main([]))\n"
        )
        quadratic = "sudo " + " ".join(["Copy-Item"] * 3000)
        started = time.monotonic()
        result = _run([sys.executable, "-c", runner, str(GATE_PATH)], {"tool_name": "Bash", "tool_input": {"command": quadratic}})
        self.assertLess(time.monotonic() - started, 5)
        self.assertEqual(1, result.returncode, "faulthandler exits 1; 0 means the probe finished before the deadline")
        self.assertEqual(b"", result.stdout)
        self.assertIn(b"Timeout", result.stderr)


class FailClosedTests(unittest.TestCase):
    """A broken policy or a missing gate must block Bash, file writes and patches, not allow them."""

    def _layout(self, conf: bytes | None, *, with_gate: bool = True) -> Path:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        hooks = root / ".claude" / "hooks"
        hooks.mkdir(parents=True)
        shutil.copy2(WRAPPER_PATH, hooks / WRAPPER_PATH.name)
        if with_gate:
            shutil.copy2(GATE_PATH, hooks / GATE_PATH.name)
        if conf is not None:
            (hooks / CONF_PATH.name).write_bytes(conf)
        codex_hooks = root / ".codex" / "hooks"
        codex_hooks.mkdir(parents=True)
        shutil.copy2(CODEX_ADAPTER_PATH, codex_hooks / CODEX_ADAPTER_PATH.name)
        return root

    def test_broken_policy_blocks_guarded_tools_only(self) -> None:
        guarded = (
            ("Bash", {"command": f"{GIT} status"}),
            *((t, {"file_path": "a.txt"}) for t in WRITE_TOOLS),
            (APPLY_PATCH, {"input": _patch("*** Add File: a.txt")}),
        )
        for name, conf in (("malformed", b"SHELL\tonly-three\tcolumns\n"), ("missing", None), ("not utf-8", b"\xff\xfe\x00")):
            root = self._layout(conf)
            gate = root / ".claude" / "hooks" / GATE_PATH.name
            for tool, tool_input in guarded:
                with self.subTest(case=name, tool=tool):
                    result = _run([sys.executable, str(gate)], {"tool_name": tool, "tool_input": tool_input}, cwd=root)
                    self.assertEqual(2, result.returncode)
                    self.assertTrue(result.stderr.strip())
            for tool in ("Read", ""):
                with self.subTest(case=name, tool=tool or "<none>"):
                    result = _run([sys.executable, str(gate)], {"tool_name": tool, "tool_input": {}}, cwd=root)
                    self.assertEqual(0, result.returncode)

    def test_crlf_policy_copy_still_gates(self) -> None:
        text = CONF_PATH.read_text(encoding="utf-8-sig").replace("\r\n", "\n").replace("\n", "\r\n")
        root = self._layout(text.encode("utf-8"))
        gate = root / ".claude" / "hooks" / GATE_PATH.name
        result = _run([sys.executable, str(gate)], {"tool_name": "Bash", "tool_input": {"command": FORCE_PUSH}}, cwd=root)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("deny", _decision(result)["hookSpecificOutput"]["permissionDecision"])

    def test_codex_adapter_fails_closed_without_gate(self) -> None:
        root = self._layout(CONF_PATH.read_bytes(), with_gate=False)
        adapter = root / ".codex" / "hooks" / CODEX_ADAPTER_PATH.name
        result = _run([sys.executable, str(adapter)], {"tool_name": "Bash", "tool_input": {"command": f"{GIT} status"}}, cwd=root)
        self.assertEqual(2, result.returncode)
        self.assertEqual(b"", result.stdout)
        self.assertTrue(result.stderr.strip())

    def test_codex_adapter_fails_closed_when_the_gate_crashes(self) -> None:
        root = self._layout(CONF_PATH.read_bytes(), with_gate=False)
        gate = root / ".claude" / "hooks" / GATE_PATH.name
        gate.write_text("def main(argv):\n    raise RuntimeError('boom')\n", encoding="utf-8")
        adapter = root / ".codex" / "hooks" / CODEX_ADAPTER_PATH.name
        result = _run([sys.executable, str(adapter)], {"tool_name": "Bash", "tool_input": {"command": f"{GIT} status"}}, cwd=root)
        self.assertEqual(2, result.returncode)
        self.assertEqual(b"", result.stdout)
        self.assertIn(b"boom", result.stderr)

    def test_wrapper_fails_closed_without_python(self) -> None:
        bash = find_bash()
        self.assertIsNotNone(bash, "Git Bash / bash is required to exercise block_dangerous.sh")
        root = self._layout(CONF_PATH.read_bytes())
        empty_bin = root / "empty-bin"
        empty_bin.mkdir()
        env = dict(os.environ, PATH=str(empty_bin))
        wrapper = root / ".claude" / "hooks" / WRAPPER_PATH.name
        result = _run([bash, str(wrapper)], {"tool_name": "Bash", "tool_input": {"command": f"{GIT} status"}}, cwd=root, env=env)
        self.assertEqual(2, result.returncode, result.stderr)
        self.assertEqual(b"", result.stdout)
        self.assertTrue(result.stderr.strip())

    def test_wrapper_propagates_an_unreadable_payload(self) -> None:
        bash = find_bash()
        self.assertIsNotNone(bash, "Git Bash / bash is required to exercise block_dangerous.sh")
        for raw in (b"not json", b""):
            with self.subTest(raw=raw):
                result = _run([bash, str(WRAPPER_PATH)], raw, env=_bash_env())
                self.assertEqual(2, result.returncode, result.stderr)
                self.assertEqual(b"", result.stdout)
                self.assertTrue(result.stderr.strip())

    def test_wrapper_falls_back_from_a_broken_python3(self) -> None:
        bash = find_bash()
        self.assertIsNotNone(bash, "Git Bash / bash is required to exercise block_dangerous.sh")
        root = self._layout(CONF_PATH.read_bytes())
        fake_bin = root / "fake-bin"
        fake_bin.mkdir()
        python = Path(sys.executable).as_posix()
        for name, body in (("python3", "exit 9\n"), ("python", f'exec "{python}" "$@"\n')):
            script = fake_bin / name
            script.write_bytes(f"#!/bin/sh\n{body}".encode("utf-8"))
            script.chmod(0o755)
        env = dict(os.environ, PATH=str(fake_bin), PYTHONDONTWRITEBYTECODE="1")
        wrapper = root / ".claude" / "hooks" / WRAPPER_PATH.name
        result = _run([bash, str(wrapper)], {"tool_name": "Bash", "tool_input": {"command": FORCE_PUSH}}, cwd=root, env=env)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("deny", _decision(result)["hookSpecificOutput"]["permissionDecision"])


class RegisteredEntryTests(unittest.TestCase):
    """Run each configured hook command verbatim through bash, the way the clients do."""

    PROBES = [
        ("Bash", {"command": FORCE_PUSH}, {"claude": "deny", "zcode": "deny", "codex": "deny"}),
        ("Bash", {"command": HARD_RESET}, {"claude": "ask", "zcode": "ask", "codex": "deny"}),
        ("Bash", {"command": f"{GIT} status"}, {"claude": None, "zcode": None, "codex": None}),
        ("Write", {"file_path": str(REPO_ROOT / "docs" / "kb" / "chunks.json")}, {"claude": "deny", "zcode": "deny", "codex": "deny"}),
        ("Edit", {"file_path": str(REPO_ROOT / "src" / "main.zig")}, {"claude": None, "zcode": None, "codex": None}),
        (APPLY_PATCH, {"input": _patch("*** Update File: " + str(REPO_ROOT / "docs" / "kb" / "chunks.json"))},
         {"claude": "deny", "zcode": "deny", "codex": "deny"}),
        (APPLY_PATCH, {"input": _patch("*** Update File: " + str(REPO_ROOT / "src" / "terminal" / "Terminal.zig"))},
         {"claude": None, "zcode": None, "codex": None}),
    ]
    GUARDED_STATUS = {"tool_name": "Bash", "tool_input": {"command": f"{GIT} status"}}

    def _bash(self) -> str:
        bash = find_bash()
        self.assertIsNotNone(bash, "bash (Git Bash on Windows) is required; this test must not be skipped")
        return bash

    def _assert_gates(self, result: subprocess.CompletedProcess, expected: str | None) -> None:
        self.assertEqual(0, result.returncode, result.stderr.decode("utf-8", "replace"))
        decision = _decision(result)
        if expected is None:
            self.assertIsNone(decision)
        else:
            self.assertEqual(expected, decision["hookSpecificOutput"]["permissionDecision"])

    def _assert_blocks(self, result: subprocess.CompletedProcess) -> None:
        self.assertEqual(2, result.returncode, result.stderr.decode("utf-8", "replace"))
        self.assertEqual(b"", result.stdout)
        self.assertTrue(result.stderr.strip())

    def test_bash_is_available(self) -> None:
        self._bash()

    def test_registered_commands_are_exact(self) -> None:
        self.assertEqual(
            [("claude", CLAUDE_HOOK_COMMAND), ("zcode", ZCODE_HOOK_COMMAND), ("codex", CODEX_HOOK_COMMAND)],
            _registered_commands(),
        )

    def test_registered_commands_gate_as_configured(self) -> None:
        bash = self._bash()
        env = _bash_env()
        for client, command in _registered_commands():
            for cwd in (REPO_ROOT, REPO_ROOT / "src"):
                for tool, tool_input, expected in self.PROBES:
                    with self.subTest(client=client, cwd=cwd.name, tool=tool, expected=expected[client]):
                        payload = {"tool_name": tool, "tool_input": tool_input, "cwd": str(cwd)}
                        self._assert_gates(_run([bash, "-c", command], payload, cwd=cwd, env=env), expected[client])

    def test_outside_the_checkout_only_claude_project_dir_keeps_gating(self) -> None:
        bash = self._bash()
        with tempfile.TemporaryDirectory() as tmp:
            outside = Path(tmp).resolve()
            ceiling = {"GIT_CEILING_DIRECTORIES": str(outside.parent)}
            # $(git rev-parse --show-toplevel) is empty outside a checkout: the entry must block, not exit 127.
            for client, command in _registered_commands():
                with self.subTest(client=client, project_dir=None):
                    payload = dict(self.GUARDED_STATUS, cwd=str(outside))
                    self._assert_blocks(_run([bash, "-c", command], payload, cwd=outside, env={**_bash_env(), **ceiling}))
            # Claude Code exports CLAUDE_PROJECT_DIR (a Windows path on Windows), so its entry works from anywhere.
            for project_dir in dict.fromkeys((str(REPO_ROOT), REPO_ROOT.as_posix())):
                env = {**_bash_env(project_dir=project_dir), **ceiling}
                for tool, tool_input, expected in self.PROBES:
                    with self.subTest(project_dir=project_dir, tool=tool, expected=expected["claude"]):
                        payload = {"tool_name": tool, "tool_input": tool_input, "cwd": str(outside)}
                        self._assert_gates(_run([bash, "-c", CLAUDE_HOOK_COMMAND], payload, cwd=outside, env=env), expected["claude"])

    def test_unreadable_payload_blocks_through_every_entry(self) -> None:
        bash = self._bash()
        for client, command in _registered_commands():
            for raw in (b"not json", b""):
                with self.subTest(client=client, raw=raw):
                    self._assert_blocks(_run([bash, "-c", command], raw, env=_bash_env()))

    def test_missing_interpreters_block_through_every_entry(self) -> None:
        bash = self._bash()
        git = shutil.which("git")
        self.assertIsNotNone(git)
        with tempfile.TemporaryDirectory() as tmp:
            fake_bin = Path(tmp)
            _write_shim(fake_bin, "git", git)
            _write_shim(fake_bin, "bash", bash)
            env = dict(_bash_env(), PATH=str(fake_bin))
            for client, command in _registered_commands():
                with self.subTest(client=client):
                    self._assert_blocks(_run([bash, "-c", command], self.GUARDED_STATUS, env=env))

    def test_large_write_payload_finishes_well_inside_the_hook_timeout(self) -> None:
        bash = self._bash()
        payload = {
            "tool_name": "Write",
            "tool_input": {"file_path": str(REPO_ROOT / "docs" / "kb" / "chunks.json"), "content": "x" * 2_000_000},
        }
        started = time.monotonic()
        result = _run([bash, "-c", CLAUDE_HOOK_COMMAND], payload, env=_bash_env())
        elapsed = time.monotonic() - started
        self.assertEqual(0, result.returncode, result.stderr.decode("utf-8", "replace"))
        self.assertEqual("deny", _decision(result)["hookSpecificOutput"]["permissionDecision"])
        self.assertLess(elapsed, 20, "the registered hook times out after 30 s")


class WindowsEntryTests(unittest.TestCase):
    """Codex runs command_windows through PowerShell on Windows; run it verbatim the same way."""

    def test_codex_windows_command_gates_under_powershell(self) -> None:
        shells = _powershells()
        if not shells:
            if os.name == "nt":
                self.fail("neither powershell.exe nor pwsh was found, so command_windows cannot be exercised")
            self.skipTest("no PowerShell on this non-Windows host; Codex only runs command_windows on Windows")
        codex = tomllib.loads(CODEX_CONFIG.read_text(encoding="utf-8"))
        command = codex["hooks"]["PreToolUse"][0]["hooks"][0]["command_windows"]
        force = {"tool_name": "Bash", "tool_input": {"command": FORCE_PUSH}}
        status = {"tool_name": "Bash", "tool_input": {"command": f"{GIT} status"}}
        base = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
        base.pop("CLAUDE_PROJECT_DIR", None)
        with tempfile.TemporaryDirectory() as tmp:
            outside = Path(tmp).resolve() / "outside"
            outside.mkdir()
            no_python_bin = Path(tmp) / "bin"
            no_python_bin.mkdir()
            no_python_path = _path_without_python(no_python_bin)
            self.assertIsNone(shutil.which("python3", path=no_python_path))
            self.assertIsNone(shutil.which("python", path=no_python_path))
            cases = [
                ("deny payload", force, REPO_ROOT, base, 0, "deny"),
                ("allowed payload", status, REPO_ROOT, base, 0, None),
                ("empty payload", b"", REPO_ROOT, base, 2, None),
                ("cwd outside the checkout", status, outside, dict(base, GIT_CEILING_DIRECTORIES=str(outside.parent)), 2, None),
                ("python3 missing", status, REPO_ROOT, dict(base, PATH=no_python_path), 2, None),
            ]
            for name, shell in shells:
                for case, payload, cwd, env, code, expected in cases:
                    with self.subTest(shell=name, case=case):
                        result = _run([shell, "-NoProfile", "-Command", command], payload, cwd=cwd, env=env)
                        self.assertEqual(code, result.returncode, result.stderr.decode("utf-8", "replace"))
                        if code == 2:
                            self.assertEqual(b"", result.stdout)
                            self.assertTrue(result.stderr.strip())
                        elif expected is None:
                            self.assertEqual(b"", result.stdout)
                        else:
                            self.assertEqual(expected, _decision(result)["hookSpecificOutput"]["permissionDecision"])


class AdapterIntegrityTests(unittest.TestCase):
    def test_registered_python_scripts_are_python(self) -> None:
        checked = 0
        for client, command in _registered_commands():
            interpreter, script = _script_of(command)
            if interpreter.startswith("python"):
                with self.subTest(client=client):
                    self.assertTrue(script.is_file(), script)
                    ast.parse(script.read_text(encoding="utf-8"), filename=str(script))
                    checked += 1
        self.assertGreaterEqual(checked, 1)

    def test_registered_bash_scripts_pass_bash_n(self) -> None:
        bash = find_bash()
        self.assertIsNotNone(bash, "bash (Git Bash on Windows) is required; this test must not be skipped")
        checked = 0
        for client, command in _registered_commands():
            interpreter, script = _script_of(command)
            if interpreter == "bash":
                with self.subTest(client=client):
                    self.assertTrue(script.is_file(), script)
                    result = subprocess.run([bash, "-n", str(script)], capture_output=True, timeout=60, check=False)
                    self.assertEqual(0, result.returncode, result.stderr)
                    checked += 1
        self.assertGreaterEqual(checked, 2)

    def test_every_hook_script_parses(self) -> None:
        for script in [*HOOKS_DIR.glob("*.py"), *CODEX_ADAPTER_PATH.parent.glob("*.py")]:
            with self.subTest(script=script.name):
                ast.parse(script.read_text(encoding="utf-8"), filename=str(script))

    def test_hook_files_are_not_git_ignored(self) -> None:
        for path in (GATE_PATH, CONF_PATH, WRAPPER_PATH, CODEX_ADAPTER_PATH):
            relative = path.relative_to(REPO_ROOT).as_posix()
            with self.subTest(path=relative):
                result = subprocess.run(
                    ["git", "check-ignore", "--no-index", "-q", relative], cwd=REPO_ROOT, timeout=60, check=False
                )
                self.assertEqual(1, result.returncode, f"{relative} is ignored by git")


class ClaudeConfigTests(unittest.TestCase):
    def setUp(self) -> None:
        self.settings = json.loads(CLAUDE_SETTINGS.read_text(encoding="utf-8"))
        self.permissions = self.settings["permissions"]

    def test_permission_shape(self) -> None:
        self.assertEqual("acceptEdits", self.permissions["defaultMode"])
        self.assertNotIn("ask", self.permissions, "ask rules prompt in every mode and no allow can override them")
        for rule in ("Read(./.env)", "Read(./**/.env)", "Read(./**/*.pem)", "Read(./.git/**)"):
            self.assertIn(rule, self.permissions["deny"])
        allow = self.permissions["allow"]
        for rule in ("Read(./**)", "Edit(./**)", "Glob", "Grep", "WebSearch", "WebFetch", "Agent", "Skill"):
            self.assertIn(rule, allow)
        self.assertNotIn("Bash", allow, "Bash stays scoped to explicit command prefixes")
        for rule in allow:
            with self.subTest(rule=rule):
                # Write/MultiEdit/NotebookEdit path rules are never consulted; Edit covers them.
                self.assertIsNone(re.match(r"(?:Write|MultiEdit|NotebookEdit)\(", rule))
                if rule.startswith("Bash"):
                    self.assertRegex(rule, r"^Bash\([^()*]+ \*\)$|^Bash\([^()*]+/\*\)$")

    def test_pre_tool_use_hook(self) -> None:
        blocks = self.settings["hooks"]["PreToolUse"]
        self.assertEqual(1, len(blocks))
        self.assertEqual(CLIENT_MATCHER, blocks[0]["matcher"])
        self.assertEqual(
            [{"type": "command", "command": CLAUDE_HOOK_COMMAND, "timeout": 30}], blocks[0]["hooks"]
        )
        self.assertTrue(WRAPPER_PATH.is_file())

    def test_reviewer_is_read_only_and_uses_the_resolver(self) -> None:
        meta, body = _frontmatter(CLAUDE_REVIEWER)
        self.assertEqual("code-reviewer", meta["name"])
        self.assertTrue(meta["description"])
        self.assertEqual({"Read", "Grep", "Glob", "Bash"}, {t.strip() for t in meta["tools"].split(",")})
        self.assertLessEqual({"Edit", "Write"}, {t.strip() for t in meta["disallowedTools"].split(",")})
        self.assertEqual("inherit", meta["model"])
        for needle in ("rules-review", "--task review", "docs/AGENT_RULES/code-review.md", "严重", "中", "轻", "结论"):
            self.assertIn(needle, body)

    def test_rules_are_thin_resolver_pointers(self) -> None:
        rules = sorted(CLAUDE_RULES_DIR.glob("*.md"))
        self.assertEqual(["framework.md", "product-code.md", "release-safety.md"], [p.name for p in rules])
        for path in rules:
            meta, body = _frontmatter(path)
            with self.subTest(rule=path.name):
                self.assertTrue(meta.get("description"))
                self.assertIsInstance(meta.get("paths"), list)
                self.assertTrue(meta["paths"])
                self.assertIn("just rules", body)
                self.assertLessEqual(len(body.splitlines()), 2)

    def test_every_rule_glob_matches_a_git_visible_file(self) -> None:
        files = _git_visible_files()
        for path in sorted(CLAUDE_RULES_DIR.glob("*.md")):
            meta, _ = _frontmatter(path)
            for pattern in meta["paths"]:
                with self.subTest(rule=path.name, pattern=pattern):
                    regex = _glob_regex(pattern)
                    self.assertTrue(any(regex.match(name) for name in files), f"{pattern} matches no Git-visible file")


class CodexConfigTests(unittest.TestCase):
    def setUp(self) -> None:
        self.config = tomllib.loads(CODEX_CONFIG.read_text(encoding="utf-8"))

    def test_policy_and_environment(self) -> None:
        self.assertEqual("never", self.config["approval_policy"])
        self.assertEqual("danger-full-access", self.config["sandbox_mode"])
        policy = self.config["shell_environment_policy"]
        self.assertEqual("all", policy["inherit"])
        self.assertLessEqual({"*KEY*", "*SECRET*", "*TOKEN*", "*PASSWORD*"}, set(policy["exclude"]))

    def test_hooks_are_arrays_of_tables_with_second_timeouts(self) -> None:
        events = self.config["hooks"]["PreToolUse"]
        self.assertIsInstance(events, list)
        self.assertEqual(1, len(events))
        self.assertEqual(CODEX_MATCHER, events[0]["matcher"])
        for tool in ("Bash", APPLY_PATCH):
            self.assertRegex(tool, events[0]["matcher"])
        self.assertNotRegex("Edit", events[0]["matcher"])
        self.assertIsInstance(events[0]["hooks"], list)
        self.assertEqual(
            [{"type": "command", "command": CODEX_HOOK_COMMAND, "command_windows": CODEX_WINDOWS_HOOK_COMMAND, "timeout": 30}],
            events[0]["hooks"],
        )
        # Windows PowerShell 5.1 cannot parse "||"; codex 0.160 also accepts the camelCase commandWindows.
        self.assertNotIn("||", CODEX_WINDOWS_HOOK_COMMAND)
        text = CODEX_CONFIG.read_text(encoding="utf-8")
        self.assertNotRegex(text, r"(?m)^\s*commandWindows\s*=")
        self.assertNotRegex(text, r"(?m)^\s*(?:timeout_ms|timeoutMs)\s*=")
        self.assertRegex(text, r"(?m)^\[\[hooks\.PreToolUse\]\]$")
        self.assertRegex(text, r"(?m)^\[\[hooks\.PreToolUse\.hooks\]\]$")

    def test_reviewer_is_registered_read_only(self) -> None:
        agent = self.config["agents"]["gx_ghostty_reviewer"]
        self.assertEqual("agents/gx-ghostty-reviewer.toml", agent["config_file"])
        self.assertTrue(agent["description"])
        path = CODEX_CONFIG.parent / agent["config_file"]
        self.assertTrue(path.is_file())
        reviewer = tomllib.loads(path.read_text(encoding="utf-8"))
        self.assertEqual("gx_ghostty_reviewer", reviewer["name"])
        self.assertTrue(reviewer["description"])
        self.assertEqual("read-only", reviewer["sandbox_mode"])
        for needle in ("--task review", "rules-review", "docs/AGENT_RULES/code-review.md"):
            self.assertIn(needle, reviewer["developer_instructions"])


class ZcodeConfigTests(unittest.TestCase):
    def test_hooks_enabled_with_millisecond_timeouts(self) -> None:
        hooks = json.loads(ZCODE_CONFIG.read_text(encoding="utf-8"))["hooks"]
        self.assertIs(True, hooks["enabled"], "a missing or false flag silently disables every hook")
        self.assertEqual(30000, hooks["timeoutMs"])
        blocks = hooks["events"]["PreToolUse"]
        self.assertEqual(1, len(blocks))
        self.assertEqual(CLIENT_MATCHER, blocks[0]["matcher"])
        self.assertEqual([{"type": "command", "command": ZCODE_HOOK_COMMAND, "timeoutMs": 30000}], blocks[0]["hooks"])


if __name__ == "__main__":
    unittest.main()
