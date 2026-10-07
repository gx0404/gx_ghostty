#!/usr/bin/env bash
# Claude Code / ZCode PreToolUse adapter: runs the shared gate with the Claude
# protocol. Policy: dangerous_patterns.conf; decision logic: pre_tool_use_gate.py.
# Apart from an optional cat, only bash builtins run before Python starts, so the
# adapter still fails closed (instead of crashing) on a minimal PATH.
set -u

script="${BASH_SOURCE[0]}"
case "$script" in
  */* | *\\*) hook_dir="${script%[/\\]*}" ;;
  *) hook_dir="." ;;
esac
gate="$hook_dir/pre_tool_use_gate.py"

# Buffer the hook payload so a second interpreter can be tried if the first one
# cannot run (for example a Windows Store "python3" stub that exits 9009).
# cat reads large Write payloads in bulk; the read builtin is the fallback.
payload=""
if command -v cat >/dev/null 2>&1; then
  payload="$(cat)"
else
  IFS= read -r -d '' payload || true
fi

for python in python3 python; do
  command -v "$python" >/dev/null 2>&1 || continue
  "$python" "$gate" --protocol claude "$@" <<<"$payload"
  status=$?
  # 0: decision made (silent allow or JSON on stdout); 2: the gate failed closed.
  # Any other status means this interpreter could not run the gate, or the gate's
  # evaluation watchdog fired (status 1); either way try the next interpreter.
  case "$status" in
    0 | 2) exit "$status" ;;
  esac
done

echo "block_dangerous.sh: 没有 Python（python3 或 python）能完成判定（缺失、无法运行或判定超时），已按失败关闭拦截" >&2
exit 2
