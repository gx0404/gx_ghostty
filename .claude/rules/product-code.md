---
description: 产品源码入口（Zig 核心、C 头文件、macOS app、pkg 包装、示例与构建脚本）
paths:
  - "src/**"
  - "include/**"
  - "macos/**"
  - "pkg/**"
  - "example/**"
  - "build.zig"
  - "build.zig.zon"
---

动手前对本轮全部触及路径运行 `just rules <paths...>`（即 `python scripts/resolve_agent_rules.py <paths...>`），读完列出的领域文档与上游嵌套 `AGENTS.md` 再改；规则正文只在 `docs/AGENT_RULES/`。
