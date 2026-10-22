# .zcode（团队共享，fork 维护）

ZCode 的规则入口是根 `AGENTS.md`，领域规则由 `just rules <paths...>` 解析，不经 `CLAUDE.md` 间接加载。

当前 [ZCode 官方 hooks 文档](https://zcode.z.ai/en/docs/hooks) 明确：项目 `.zcode/config.json` 或 `zcode.json` 中的 hooks 会被整体忽略。仓内 `config.json` 因此保留为空对象，不声称提供已生效的项目安全门。

需要启用安全门时，由用户选择在 `~/.zcode/cli/config.json` 配置，或安装受信任的 hook 插件；本仓更新不写用户配置、权限、provider 或认证。用户级配置可以引用共享脚本，不复制模式：

```json
{
  "hooks": {
    "enabled": true,
    "events": {
      "PreToolUse": [{
        "matcher": "Bash|Read|Edit|Write|MultiEdit|NotebookEdit",
        "hooks": [{
          "type": "process",
          "command": "<verified-python>",
          "args": ["-B", "<checkout>/.claude/hooks/pre_tool_use_gate.py", "--protocol", "claude"],
          "timeoutMs": 30000
        }]
      }]
    }
  }
}
```

示例中的解释器与 checkout 须替换为本机已验证的绝对路径，并按字段合并到原配置。`process` 直接按 argv 执行，避免 Windows shell 的引号差异；共享门依赖仓库中的 `dangerous_patterns.conf`。此示例不是已安装配置，也不证明 ZCode 已加载或拦截。

hook 配置在新会话开始时取快照。启用后分别验证普通调用、核心防线、模板例外与 Plan 边界；客户端、插件及用户级接入状态见 [AI 工具接入与验证账本](../docs/AI_TOOLS.md)。plans、tmp、认证、provider 与日志均不入库。
