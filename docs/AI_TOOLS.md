# AI 工具接入与验证账本

项目有两份真源：根 `AGENTS.md` 与 `docs/AGENT_RULES/` 定义开发规则，`scripts/resolve_agent_rules.py` 按路径加载；`.claude/hooks/dangerous_patterns.conf` 定义危险模式，`.claude/hooks/pre_tool_use_gate.py` 统一求值。客户端目录只做薄适配，不复制领域正文。

认证、会话与本机覆盖不入库；白名单见根 `.gitignore`，`.kimi-code/` 整目录忽略。以下契约与本机检查更新至 2026-10-22。配置文件存在或离线探针通过，都不证明真实会话已经加载、信任并调用 hook。

## 客户端入口

| 客户端 | 规则与配置 | 项目 hook | 角色与限制 |
|---|---|---|---|
| Claude Code | `CLAUDE.md` 导入根规则；`.claude/rules/` 按路径提醒 resolver；`.claude/settings.json` | `Bash|Read|Edit|Write|MultiEdit|NotebookEdit` → `block_dangerous.sh` | `.claude/agents/code-reviewer.md`；只读职责靠工具集合与指令，不把角色当独立权限沙箱 |
| Codex | 原生根 `AGENTS.md`；受信任后加载 `.codex/config.toml` | `^(Bash|apply_patch)$` → `pre_tool_use_policy.py` | 定义四个角色，按 `.codex/agents/*.toml` 的 `name` 协议发现；实际项目发现见账本，不再用旧 `config_file` 注册 |
| Kimi Code | 会话注入根规则；项目 skills 扫描 `.agents/skills/` | 无项目级 hook | 用户级 hook 可选；出错或超时按放行处理 |
| ZCode | 根 `AGENTS.md`；`.zcode/config.json` 保留空对象 | 官方明确忽略项目级 hooks | 需要时由人类配置用户级或插件 hook，本仓不自动安装 |

Codex 角色只声明职责。模型与推理档由父会话依用户级路由显式选择，provider、认证和权限继承宿主；角色里的文字不建立独立沙箱。已移除角色中的固定模型、推理档以及 reviewer 的 `sandbox_mode` / `approval_policy` 覆盖，项目不保存个人模型策略。

上游 `.agents/skills/writing-commit-messages` 保持原样，只用于准备回馈上游；fork 提交遵守根规则的 `type(scope): 中文描述`。`.agents/commands/review-branch` 可作为只读提示，输出服从 `code-review` 域。

## 共享安全门

### 最小核心防线

2026-10 授权保留四类 deny，未新增 ask。SHELL 三条与 FILE 两条的精确正则以策略文件为准：

| 类别 | 处理范围 |
|---|---|
| force push | `-f`、`--force`、`--mirror`、`+refspec`，含引号、包装器与全局 git 参数；现行正则未拒绝 `--force-with-lease`，根规则仍禁止 force push |
| 根/家目录删除 | `rm`、PowerShell 删除命令及别名以根、家目录、盘符根和对应通配符为操作数；普通具体目录不因此被拒绝 |
| 凭据读取 | shell 读取命令、解释器，以及 Claude 原生 `Read` 的目标路径；`.env` 变体、私钥与 `.ssh/` 按共享规则判定 |
| 凭据写入 | Claude 文件工具与 Codex 补丁头路径；模板例外为 `.env.example`、`.env.sample`、`.env.template`，`.envrc` 不匹配凭据规则 |

本轮将原生 `Read` 接入同一 FILE 策略，补齐此前 shell 读取与原生读取之间的变体缺口；嵌套 `tool_input.file_path`、`path`、`notebook_path` 均由共享门提取，先按仓库根相对化再匹配。`.pub` 只按相应私钥模式的例外处理，不把整个 `.ssh/` 目录视为可读。

推送 `upstream`、跳过 hook、强制暂存、发布触发、系统级安装、修改生成物与安全门等，已不在 hook 拒绝集合；根规则的授权、治理与生成流程仍有效。hook 不是完整 shell 解析器，也不是操作授权来源。

### 协议与执行

- SHELL 匹配真实命令位置，并处理续行、包装器与带引号命令。文本提及通常放行，但引号或 heredoc 中看起来像命令的片段可能被保守拒绝；边界用成对探针锁定。
- Codex `apply_patch` 不提供普通 `file_path`，共享门提取 `*** Add/Update/Delete File:`、`*** Move to:` 的路径；shell 调用补丁工具时同样提取。普通 Write/Edit 正文不当作补丁解析。
- 已受控的调用遇到策略缺失/损坏、非法 JSON、缺解释器或共享门失败，注册入口转为 exit 2，并向 stderr 写原因。非受控工具不参与此判定。
- Claude 注册命令使用 `${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}` 和 Git Bash；Codex POSIX 使用 `command`，Windows 使用 PowerShell 的 `command_windows`，通过 `$?` 与 `$LASTEXITCODE` 统一转 exit 2。不能把 POSIX `|| exit 2` 直接搬到 Windows PowerShell。
- `block_dangerous.sh` 依次尝试可运行的 `python3`、`python`。共享引擎的 C 级看门狗限制单次求值 10 秒，客户端注册 timeout 为 30 秒；测试覆盖病态长选项与失败关闭，不由此承诺所有 shell 文本都可精确识别。
- Claude 输出 `hookSpecificOutput.permissionDecision`；Codex 适配器只出 deny，保留的 ask 机制映射为 deny。扁平 `permissionDecision/reason` 不是本仓采用的 Codex schema。

当前策略没有 ask。修改入口或 matcher 时同步更新 `scripts/test_ai_tool_hooks.py`，既测拒绝，也测合法命令、模板与纯文本放行；使用真实工具 payload 和原样注册命令，不能只直调引擎。

## 权限与加载边界

- Claude 项目保留 `acceptEdits` 与整工具 Bash allow；原生权限 deny 是补充，Read/写入的凭据变体由共享 FILE 门完整判定。不加 Write 路径规则或 ask 白名单。
- Codex 项目保留已授权的 `approval_policy = "never"`、`sandbox_mode = "danger-full-access"`，不改变父会话的实际权限边界。环境继承排除 `*KEY*`、`*SECRET*`、`*TOKEN*`、`*PASSWORD*`；这不构成读取凭据的授权。
- Codex 的项目配置受项目信任控制，非托管 hook 还需审阅当前 hash。不得自动授予信任，不读取私人会话或全层配置 RPC。角色发现、`hooks=true` 与 `git status` 成功都不能代证拦截。
- Kimi 的用户级 `[[hooks]]` 与 ZCode 用户级/插件 hooks 仅为可选接入，不在本任务自动写入。尤其 ZCode 项目 `{}` 不应被解释为已经保护工具调用。

## 验证账本

### 2026-10-22 本轮

本机版本：Codex `0.163.0-alpha.11`、Claude Code `2.1.76`。本轮证据在 `.local/evidence/ai-refresh-20261022/ai-config/`，不提交私人配置或会话。

| 检查 | 状态与边界 |
|---|---|
| hook 定向回归 | PASS：`python scripts/run_unittests.py test_ai_tool_hooks`，68 tests / 13 units，wall 5.43 s；日志 `targeted-tests.txt` |
| 原生 Read 变体与模板 | PASS：修复前子例失败、修复后上述回归通过；`read-regression-before.txt` 保留失败证据 |
| 原样注册入口 | PASS：上述回归包含 Git Bash、Windows PowerShell 5.1 与 PowerShell 7 的命令、失败关闭和协议 |
| Claude 项目角色发现 | PASS：`claude agents --setting-sources project` exit 0，列出项目 code-reviewer；只证明角色发现 |
| Codex 严格诊断组合 | 不支持：本机 `--strict-config features list`、`--strict-config debug prompt-input` 均 exit 1；`native-config-checks.json` 记录错误，不能用这两种组合签署严格配置通过 |
| Codex 非 strict 原生诊断 | PASS：features list exit 0、hooks 开关可见；debug prompt-input exit 0 且 JSON 含根规则，见 `native-config-readonly.json`；不证明未知字段会被拒绝 |
| Codex 项目角色发现 | PENDING：隔离无凭据 CODEX_HOME 的诊断未列出四个项目角色，原因未单独确定；未改变信任 |
| 当前新会话角色真实使用 | PENDING：尚未进行模型调用 |
| 当前项目/hook 信任与原生拦截 | PENDING：未改变信任状态，尚无真实 shell / Read / apply_patch 拦截结论 |
| ZCode 项目 hook | N/A：官方忽略项目级配置；用户级/插件接入未配置、未验收 |
| MCP | N/A：本仓无项目级 MCP |

配置代理的后续原生只读诊断与完整框架门须按实际结果补证，不能从上述版本号或解析结果外推。

### 历史证据

历史结果只对当时版本与策略有效：

- 2026-10-07：Git Bash 与最小 cmd PATH 下，旧 `test_ai_tool_hooks` 各 62 项通过；cmd 探针从 `git --exec-path` 找 Git Bash。2026-10-21 最小防线策略的同组测试为 64 项通过。
- 2026-10-07，Kimi Code 2.1.1：新会话在调用工具前复述了 fork 三条规则，之后只运行只读 git status，证明自动注入；当时“Windows 只有 lib-vt”的第三条已经过时，不能沿用为现状。未验证 hook 或信任流程。
- 同日，Codex 0.160.0：真实 `codex exec --strict-config --ephemeral` 短调用 exit 0，根规则已注入；启动显示 read-only 不能证明项目配置没加载。项目配置来源与 hook 信任仍未确认。
- 同日，Codex 两条旧拦截探针 FAIL：`gh pr create --help` 进入 gh 后因配置访问拒绝退出 1，`git clean -n -d` 实际执行并 exit 0。两条命令已在 2026-10-21 放开，不能用作当前拒绝探针，也不能据旧失败断定新配置已修复。
- Codex 0.160 的数组表、`command_windows`/`commandWindows` 类型与输出 schema 曾做离线核对；`features list` 中的 `hooks=true` 从未证明实际调用。当前入口仍需原生补验。
- 当时 Claude 与 ZCode 的 `command -v` 均未发现客户端；该历史安装状态已被本轮 Claude 版本检查更新，旧 ZCode 适配器离线 PASS 也不代表官方支持项目 hook。

## 补验方式

由人类从仓库根开对应客户端的新会话，先只读查看来源；不由 agent 自动 trust。

1. Claude 用 `/context` 或 `/memory` 核对导入；Codex 用客户端支持的 `/debug-config`、`/hooks` 核对项目层和当前 hash。复述规则后再调用工具，分别记录角色发现、规则加载和 hook 状态。
2. 在不接触真实凭据的临时输入上测试 shell force-push dry-run、原生 Read `.env.probe.txt`、写入同名探针的拒绝，以及模板和普通 git status 的放行。漏拦时只处理测试产物，保留失败证据。
3. Codex 实际运行 `apply_patch`，核对真实 tool_name、payload 与 FILE 拒绝；Windows 要确认走 `command_windows`。Claude 核对 Git Bash 注册入口与原生 Read。步骤和离线协议通过互不代证。
4. 每项注明客户端版本、命令、退出码和证据路径；未完成继续 PENDING。ZCode 只有在用户明确配置用户级/插件 hook 后，才进行其原生接入验收。

## 官方资料

2026-10-22 核对的能力说明：

- [Codex 子智能体与角色发现](https://learn.chatgpt.com/docs/agent-configuration/subagents)
- [Codex hooks](https://developers.openai.com/codex/hooks/)
- [ZCode hooks：项目级配置被忽略](https://zcode.z.ai/en/docs/hooks)
- [Kimi skills](https://www.kimi.com/code/docs/en/kimi-code-cli/customization/skills.html) 与 [hooks](https://www.kimi.com/code/docs/en/kimi-code-cli/customization/hooks.html)
