# 已归档的上游 workflow

本目录用 `git mv` 原样保存上游 `ghostty-org/ghostty` 的 15 个 GitHub Actions workflow，内容一字未改。GitHub 只加载 `.github/workflows/` 下的文件，所以这里的文件在本 fork 上不会触发，只用于上游同步和查阅。

本 fork 启用的只有两个 workflow：

- `.github/workflows/gx-ci.yml`：push 与 PR 到 `gx_ghostty` 时运行，也可手动触发。
- `.github/workflows/gx-release.yml`：只能手动触发，构建、校验并按需发布。

两者的说明见 [docs/RELEASE.md](../../docs/RELEASE.md)，规则真源见 [docs/AGENT_RULES/ci-release.md](../../docs/AGENT_RULES/ci-release.md)。启用集合与本目录的文件集合由 `scripts/test_gx_workflows.py` 锁定。

## 为什么归档

上游 job 大多跑在 Namespace 提供的 `namespace-profile-ghostty-*` runner 上，依赖 `CACHIX_AUTH_TOKEN`、`VOUCH_APP_*`、R2 与 Apple 签名公证等上游 secrets，另有定时任务和机器人流程。fork 上没有这些资源，保持启用只会让 job 一直排队或失败。`test.yml` 的 `required` job 用 `if: always()` 汇总全部检查，也挂在 namespace runner 上，在 fork 上同样无法完成。

| 文件 | 上游用途 |
|---|---|
| `test.yml` | 主 CI：构建、测试、lint 与汇总门 `required` |
| `nix.yml` | 检查 zon2nix 生成的 zig 依赖哈希是否最新 |
| `release-tip.yml` | `main` 每次通过 Test 后发布 tip（nightly）构建 |
| `release-tag.yml` | `vX.Y.Z` tag 的正式构建：源码包签名、macOS 签名公证、appcast |
| `publish-tag.yml` | 核对下载站上的正式版本文件，再上线 appcast |
| `flatpak.yml`、`snap.yml` | 用源码包构建 Flatpak 与 Snap |
| `clean-artifacts.yml` | 定时清理旧 artifact |
| `update-colorschemes.yml` | 定时更新 iTerm2 配色依赖并开 PR |
| `milestone.yml` | 给合并的 PR 和关闭的 issue 设置 milestone |
| `vouch-*.yml`（5 个） | vouch 贡献者审核，维护 `CODEOWNERS` 与 `.github/VOUCHED.td` |

## 维护规则

- 不编辑本目录的 `*.yml`，也不把它们移回 `.github/workflows/`。这里保存的就是上游原文。
- 上游同步后检查 `.github/workflows/`：上游新增的 workflow 用 `git mv` 原样移进本目录；上游修改已归档的文件时，Git 的重命名检测通常会把改动直接落到这里；上游删除某个 workflow 时，跟着用 `git rm` 删除归档副本。归档文件有增删时，同步更新 `scripts/test_gx_workflows.py` 的 `ARCHIVED` 清单和上表。
- 合并后启用集合必须仍然只有 `gx-ci.yml` 与 `gx-release.yml`，否则 `just framework-test` 中的 `scripts/test_gx_workflows.py` 会失败。
- 本 fork 的 workflow 复用这里已经钉住的 action 提交 SHA。上游升级钉版后，同步时把 `gx-*.yml` 的 SHA 一并改成新值，`scripts/test_gx_workflows.py` 会检查两边一致。
