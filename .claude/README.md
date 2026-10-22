# .claude（团队共享，fork 维护）

入口是根 `CLAUDE.md`，首行 `@AGENTS.md` 导入公共规则。领域正文只在 `docs/AGENT_RULES/`，由 `just rules <paths...>` 解析；`rules/*.md` 仅作按路径触发的提醒。

- `settings.json` 保留 `defaultMode: acceptEdits`、原有 allow/deny 与无 ask 列表的权限基线。`Edit(...)` 权限同时约束 Write 与 NotebookEdit，不另造 Write 路径规则。
- PreToolUse 匹配 Bash、Read、Edit、Write、MultiEdit、NotebookEdit，经 `hooks/block_dangerous.sh` 调用共享门。Read 的 `file_path` 复用 FILE 策略，补齐环境密钥变体及 `.p12`、`.pfx` 的读取保护；模板与公钥例外沿用同一策略。
- `hooks/dangerous_patterns.conf` 是唯一模式真源，仍只有原有四类核心防线，不新增 ask。`hooks/pre_tool_use_gate.py` 只检查工具参数，不读取待操作文件内容。
- 注册命令优先使用 `CLAUDE_PROJECT_DIR`，缺失时从 Git 根定位脚本。包装器依次尝试 `python3`、`python`；输入无效、策略损坏或解释器无法完成判定时 exit 2。判定看门狗限于 10 秒，早于客户端的 30 秒超时。
- 注册命令依赖 POSIX shell，Windows 使用 Git Bash。当前配置不添加需要较新 Claude Code 的 `onFailure` 字段；具体版本与真实加载状态见验证账本。
- `agents/code-reviewer.md` 继承模型，保留 Read、Grep、Glob、Bash 工具及只读审核职责；提示词与工具名单不等于操作系统级只读隔离。

`settings.local.json`、认证、会话与日志留在本机。改配置或 hook 后运行 `python scripts/run_unittests.py test_ai_tool_hooks`；注册命令探针不代证新会话内的配置加载和拦截。见 [AI 工具接入与验证账本](../docs/AI_TOOLS.md)。
