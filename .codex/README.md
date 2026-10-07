# .codex（团队共享，fork 维护）

Codex 的项目配置面。规则入口是根 `AGENTS.md`（Codex 原生读取），领域规则由 `just rules <paths...>` 解析；入库范围以根 `.gitignore` fork 段白名单为准，`auth.json`、会话与本机状态不入库。

- `config.toml`：`approval_policy = "never"` + `sandbox_mode = "danger-full-access"`（用户授权的基线），`[shell_environment_policy]` 排除 `*KEY*`、`*SECRET*`、`*TOKEN*`、`*PASSWORD*`，注册只读评审员，挂 PreToolUse 安全门（matcher `^(Bash|apply_patch)$`）。
- hooks 必须写成数组表 `[[hooks.PreToolUse]]` + `[[hooks.PreToolUse.hooks]]`，`timeout` 单位是秒；形状由 `scripts/test_ai_tool_hooks.py` 锁定。
- Codex 只把 exit 2（stderr 写明原因）当拦截，`python3` 缺失、判定超时等其他退出码只记 hook 失败、工具照常执行，所以两条命令都把失败统一转成 exit 2：
  - POSIX 的 `command` 以 `|| exit 2` 结尾。
  - Windows 上 Codex 经 PowerShell 执行 `command_windows`（0.160 也认 `commandWindows`），它以 `; if (-not $? -or $LASTEXITCODE -ne 0) { exit 2 }` 结尾。PowerShell 不能用 `||`：Windows PowerShell 5.1 解析失败，PowerShell 7 的失败只剩 exit 1，都等于放行。`$?` 覆盖 `python3` 找不到的情况，此时 `$LASTEXITCODE` 不会被设置。
  - `scripts/test_ai_tool_hooks.py` 用 powershell.exe 与 pwsh 原样执行 `command_windows`。
- `hooks/pre_tool_use_policy.py`：Codex 协议适配器，加载 `.claude/hooks/pre_tool_use_gate.py`，策略真源只有 `.claude/hooks/dangerous_patterns.conf`。Codex 的 PreToolUse 不支持 ask，ask 级规则按 deny 返回；共享门加载失败、运行出错或 hook 输入不是 JSON 对象时 exit 2 失败关闭。
- `agents/gx-ghostty-reviewer.toml`：`sandbox_mode = "read-only"` 的评审员，只跑 resolver（`--task review`）与只读 git 命令，按 `docs/AGENT_RULES/code-review.md` 输出。

已知边界：

- 项目层配置只在 Codex 信任本项目后加载；非托管 hook 首次出现或内容变更后要在 `/hooks` 里审阅并信任，未信任前 Codex 会跳过它。
- `apply_patch` 的 FILE 判定是尽力而为：共享门从补丁头（`*** Add File:`、`*** Update File:`、`*** Delete File:`、`*** Move to:`）提取路径。真实会话里 hook 是否以 `apply_patch` 触发、补丁文本放在哪个键里尚未实测；对不上时生成物的 shell 写入仍由 SHELL 段兜底。
- 本目录的 `config.toml` 与 `hooks/` 属于安全门配置，Codex 用编辑工具或 shell 改它们一律被拒，由人工修改。
- 离线已验证 Codex 0.160 接受 `command_windows` 键，`command_windows` 在 Windows PowerShell 5.1 与 PowerShell 7 下的行为也已验证。真实会话中 Codex 是否选用它、用哪个 PowerShell 执行，尚未实测（PENDING，见 `docs/AI_TOOLS.md`）。

改 hook 或配置后运行 `python -m unittest scripts.test_ai_tool_hooks`；各客户端的验证状态见 `docs/AI_TOOLS.md`。
