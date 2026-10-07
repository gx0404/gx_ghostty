---
description: AI 协作框架自身入口（规则路由、脚本、工具配置、命令入口）
paths:
  - "docs/AGENT_RULES/**"
  - "scripts/**"
  - ".claude/**"
  - ".codex/**"
  - ".zcode/**"
  - "justfile"
  - "AGENTS.md"
  - "CLAUDE.md"
---

动手前对本轮全部触及路径运行 `just rules <paths...>`（即 `python scripts/resolve_agent_rules.py <paths...>`），读完列出的领域文档再改；规则正文只在 `docs/AGENT_RULES/`。
