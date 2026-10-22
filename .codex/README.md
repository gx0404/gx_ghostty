# .codex（团队共享，fork 维护）

规则入口是根 `AGENTS.md`，领域规则由 `just rules <paths...>` 解析。本目录只放项目共享配置、职责与 hook；模型、provider、认证和会话留在用户层。

- `config.toml` 保留已授权的 `approval_policy = "never"`、`sandbox_mode = "danger-full-access"` 与环境变量排除项。安全门只有在项目配置已加载、当前 hook 已受信任且收到调用时才参与判定。
- `agents/*.toml` 以 `name` 字段定义角色，不使用旧 `config_file` 注册。角色不固定模型或推理档；主协调者按用户级路由显式传入。
- 评审员保留只读职责及 resolver 审核流程。所有角色的权限、provider 与 MCP 继承父会话；角色提示词不构成独立只读沙箱。
- PreToolUse 使用数组表 `[[hooks.PreToolUse]]` 与 `[[hooks.PreToolUse.hooks]]`，`timeout` 单位为秒。`^(Bash|apply_patch)$` 匹配 shell 与补丁工具；`exec_command` 使用 `Bash` 名称。
- `hooks/pre_tool_use_policy.py` 复用 `.claude/hooks/pre_tool_use_gate.py`；策略仅来自 `.claude/hooks/dangerous_patterns.conf`。`ask` 在 Codex PreToolUse 中不受支持，适配器按 deny 返回。
- POSIX 注册命令用 `|| exit 2` 将启动失败转成阻断。Windows 的 `command_windows` 经 PowerShell 执行，用 `$?` 与 `$LASTEXITCODE` 处理缺解释器和非零退出，兼容 Windows PowerShell 5.1 与 PowerShell 7。

配置解析、注册命令探针、新会话加载、hook 信任与真实工具拦截分别验收。文件存在或 `features.hooks=true` 不证明拦截生效；`apply_patch` 的 FILE 判定仅从补丁头提取路径。新会话用 `/debug-config`、`/hooks` 只读核对来源和状态，信任操作由人类决定。

改配置或 hook 后运行 `python scripts/run_unittests.py test_ai_tool_hooks`。实际客户端版本、历史失败与待验项见 [AI 工具接入与验证账本](../docs/AI_TOOLS.md)。接口依据：[Subagents](https://learn.chatgpt.com/docs/agent-configuration/subagents)、[Hooks](https://learn.chatgpt.com/docs/hooks)。
