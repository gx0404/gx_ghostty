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

- 项目层配置只在 Codex 信任本项目后加载；非托管 hook 首次出现或内容变更后要由人类在 `/hooks` 里审阅并信任当前 hash，未信任前 Codex 会跳过它。离线脚本失败关闭不保证未加载或未信任的客户端也能拦截；保留现有 sandbox、model 与审批配置，不通过改权限掩盖漏拦。
- `apply_patch` 的 FILE 判定是尽力而为：共享门从补丁头（`*** Add File:`、`*** Update File:`、`*** Delete File:`、`*** Move to:`）提取路径。真实会话里的 FILE 拦截仍未实测；SHELL 段也只有在 hook 确实加载、受信任且收到匹配调用时才参与判定。
- 本目录的 `config.toml` 与 `hooks/` 属于安全门配置，策略要求拒绝 Codex 用编辑工具或 shell 改它们；不得把这项策略当成已验证的客户端保障。
- 2026-10-07，Codex 0.160.0 的 `codex exec --strict-config --ephemeral` 短真实调用 exit 0，根 `AGENTS.md` 自动注入 PASS；项目层实际生效 PENDING。启动头的 `read-only` 是 `exec` 默认值，不能单凭它判断项目配置未加载。
- 同次真实 shell 探针 FAIL：`gh pr create --help` 进入 gh 后因 gh 配置 `Access denied` 退出 1，`git clean -n -d` 实际执行、exit 0，均没有预期的 hook deny。`git status` 成功与 `codex features list` 的 `hooks=true` 都不证明 hook 参与。[官方文档](https://developers.openai.com/codex/hooks/)说明 `exec_command` 也匹配 `Bash`，当前 matcher 正确；具体漏拦原因 PENDING。
- 离线已验证 `command_windows` 的解析以及 Windows PowerShell 5.1、PowerShell 7 的脚本行为；真实会话是否选用它、项目与当前 hook hash 的信任流程仍待补验。由人类用 `/debug-config`、`/hooks` 只读核对配置来源和加载状态，再决定是否信任并重跑安全探针；agent 不自动 trust，不读取私有配置或会话，不使用 `config/read` 全层 RPC。完整账本见 `docs/AI_TOOLS.md`。

改 hook 或配置后运行 `python -m unittest scripts.test_ai_tool_hooks`；各客户端的验证状态见 `docs/AI_TOOLS.md`。
