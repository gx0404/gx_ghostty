@AGENTS.md

## Claude Code 薄适配

- 规则只来自上面导入的 `AGENTS.md` 与 resolver：开工前和 scope 扩大后对全部触及路径运行 `just rules <paths...>`，审核任务用 `just rules-review <paths...>`。`.claude/rules/*.md` 只是按路径触发的同一提醒，不含规则正文。
- `.claude/settings.json` 的 PreToolUse hook 经 `.claude/hooks/block_dangerous.sh` 执行共享安全门（策略真源 `.claude/hooks/dangerous_patterns.conf`）。被拒时换用合规做法，不绕过，也不为放行去改策略。
- 只读复审交给 `.claude/agents/code-reviewer.md`：它跑 `--task review` 的 resolver，按 `docs/AGENT_RULES/code-review.md` 的四段格式输出。
- 各客户端的接入差异与验证账本见 `docs/AI_TOOLS.md`。
