# .zcode（团队共享，fork 维护）

ZCode 的项目配置面，只挂 PreToolUse 安全门。规则入口是根 `AGENTS.md`（ZCode 不经 `CLAUDE.md` 间接读取，根文件必须自足），领域规则由 `just rules <paths...>` 解析。

- `config.json`：`hooks.enabled: true` 与毫秒单位的 `timeoutMs` 缺一不可（缺失或误用秒单位的 `timeout` 时 hook 静默不执行）。
- 安全门复用 `.claude/hooks/block_dangerous.sh`（Claude 协议），策略真源 `.claude/hooks/dangerous_patterns.conf`；协议分叉时只加适配器，不复制策略。
- hook 命令是 `bash "$(git rev-parse --show-toplevel)/.claude/hooks/block_dangerous.sh" || exit 2`：会话 cwd 在仓库外时找不到脚本，`|| exit 2` 让受控调用一律被拦，而不是以 127 放行。ZCode 没有文档化的项目目录变量，所以不像 Claude Code 那样读环境变量。
- 这条命令是 POSIX 写法。如果 ZCode 在 Windows 上经 PowerShell 执行 hook，Windows PowerShell 5.1 会拒绝 `||`，PowerShell 7 里失败只剩 exit 1，都等于放行（Codex 因此另配了 `command_windows`）。ZCode 有没有对应字段未知，这里不臆造，记 PENDING。
- `config.json` 本身受安全门保护：用编辑工具或 shell 改它都要人工确认。
- 本机未安装 ZCode：协议兼容只由 `scripts/test_ai_tool_hooks.py` 的离线探针证明，真实会话中的加载与拦截记 PENDING（见 `docs/AI_TOOLS.md`）。

plans、tmp、认证与 provider 等个人状态不入库（根 `.gitignore` 只放行 `config.json` 与本文件）。
