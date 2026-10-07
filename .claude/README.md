# .claude（团队共享，fork 维护）

Claude Code 的项目配置面。入口是根 `CLAUDE.md`（首行 `@AGENTS.md` 导入根规则）；领域规则由 `just rules <paths...>` 解析，正文只在 `docs/AGENT_RULES/`。入库范围以根 `.gitignore` fork 段白名单为准，`settings.local.json`、会话与日志留在本机。

- `settings.json`：`defaultMode: acceptEdits`；allow 放行仓内 Read/Edit、Glob/Grep、WebSearch/WebFetch、Agent/Skill 与常用命令前缀（常规 git、`just`、`python scripts/*`、unittest、`zig build`/`zig fmt`、`gh run list`/`gh run view`、`actionlint`）；deny 读取 `.env`、`*.pem` 与 `.git/`；不设 ask 列表。
- PreToolUse hook 命令是 `bash "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}/.claude/hooks/block_dangerous.sh" || exit 2`：优先用 Claude Code 导出的 `CLAUDE_PROJECT_DIR`，会话 cwd 在仓库外也能找到脚本；脚本仍找不到时 `|| exit 2` 把 127 转成拦截，而不是放行。
- `hooks/dangerous_patterns.conf`：危险模式唯一真源（SHELL / FILE 两段，deny / ask 两级）。
- `hooks/pre_tool_use_gate.py`：判定逻辑；`hooks/block_dangerous.sh`：Claude Code 与 ZCode 共用的协议适配器，依次尝试 `python3`、`python`，都不可用时 exit 2 失败关闭；hook 输入不是 JSON 对象时共享门同样 exit 2。判定超过 10 秒由看门狗以非 0 结束，再经 `|| exit 2` 转成拦截，不会拖到客户端 30 秒超时后放行。
- 上述 hook 命令依赖 POSIX shell（`${…:-…}` 与 `||`）；Windows 上需经 Git Bash 执行，真实会话尚未实测（PENDING，见 `docs/AI_TOOLS.md`）。
- `rules/*.md`：带 `paths:` 的薄提醒，只让 agent 先跑 resolver。
- `agents/code-reviewer.md`：只读评审员，工具限 Read、Grep、Glob、Bash，禁用 Edit/Write/NotebookEdit，模型继承主会话。

`hooks/`、`settings.json` 与 `settings.local.json` 本身受安全门保护：用编辑工具或 shell（重定向、`tee`、`sed -i`、`cp`、`mv`、`rm` 等）改它们都要人工确认。不写 `Write(...)` 路径规则：Claude Code 只按 `Read(...)`/`Edit(...)` 判定文件权限，`Edit` 规则同时覆盖 Write 与 NotebookEdit。改 hook、策略或本目录配置后运行 `python -m unittest scripts.test_ai_tool_hooks`；接入差异与验证账本见 `docs/AI_TOOLS.md`。
