---
description: CI、发版与 CHANGELOG 安全入口
paths:
  - ".github/**"
  - "CHANGELOG.md"
  - "scripts/gx_release.py"
  - "docs/RELEASE.md"
---

动手前运行 `just rules <paths...>`，发版或上游同步任务再加 `--task release` 或 `--task sync`（例：`just rules --task release CHANGELOG.md`），读完列出的领域文档再改；规则正文只在 `docs/AGENT_RULES/`。
