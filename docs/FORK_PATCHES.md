# fork 补丁登记

本文件登记 gx_ghostty 对上游源码的全部修改（fork 补丁），也是 `scripts/test_fork_patches.py` 解析的机器可读真源。fork 自有的新路径，以及根 `AGENTS.md`、`.gitignore`、`.prettierignore` 末尾带标记的追加段，不是源码补丁，不在此登记。

## 规则

- 范围：`src/`、`include/`、`pkg/`、`macos/` 下的文件与 `build.zig`。改动这些上游文件必须登记；能用新路径或构建参数解决的问题，不改上游源码。
- 编号：`GX-NNNN`，四位数字，按登记顺序递增，永不复用。
- 标记：每处改动紧邻处写英文注释 `fork(gx): GX-NNNN <说明>`（Zig、C、Swift 用 `//`）。一个补丁改多个文件时，每个文件都要有标记，并在登记表中各占一行。
- 最小化：只改必要的行，不重排、不重新注释上游正文，让上游同步时的冲突面最小。
- 提交：补丁单独成一个提交（例如 `fix(build): 非 v 前缀 tag 不再触发版本号 panic`），不与框架或文档改动混在一起。
- 移除：删掉改动与标记，把登记行的状态改为 `removed`，补丁小节保留作历史。

## 登记表

格式约定（`scripts/test_fork_patches.py` 按此解析）：

- 表格位于 `fork-patches:begin` 与 `fork-patches:end` 两行注释之间，表头固定为 `ID | 文件 | 标记 | 状态`。
- `ID` 形如 `GX-0001`；`文件` 是仓库相对的 POSIX 路径；`标记` 必须等于 `fork(gx): <ID>`；`文件` 与 `标记` 写在反引号里。
- `状态` 取 `active`（标记必须存在于该文件）或 `removed`（标记必须已从该文件消失）。
- 同一个 (ID, 文件) 只登记一行；每个 ID 在下文都有以 `## <ID>` 开头的小节。

<!-- fork-patches:begin -->
| ID | 文件 | 标记 | 状态 |
|---|---|---|---|
| GX-0001 | `src/build/Config.zig` | `fork(gx): GX-0001` | active |
<!-- fork-patches:end -->

闭集：范围内的 Git 可见文件（已跟踪的文件，加上未跟踪但未被忽略的文件）中，每个 `fork(gx)` 都必须写成 `fork(gx): GX-NNNN`，且 (ID, 文件) 在表中为 `active`。新增补丁不登记，测试就会失败。

## GX-0001 非 v 前缀 tag 不再触发版本号 panic

- 文件：`src/build/Config.zig`，`Config.init` 版本推导块中检查 `vsn.tag` 的分支。
- 标记：`fork(gx): GX-0001`。
- 状态：active，未回馈上游。
- 改动量：改 1 行判断条件，加 2 行注释。

### 原因

fork 的发布 tag 是 `gx-vX.Y.Z`（见 `docs/RELEASE.md`）。未传 `-Dversion-string`、也不是作为依赖构建时，`src/build/Config.zig::init` 用 `src/build/GitVersion.zig::detect` 读取 HEAD 上的 tag（`git describe --exact-match --tags`）。上游规定：除 `tip` 外，任何 tag 都必须等于 `v<X.Y.Z>`，X.Y.Z 取自 `build.zig.zon`（源码包里取 `VERSION` 文件），否则 `@panic("tagged releases must be in vX.Y.Z format matching build.zig")`。

`build.zig` 的 `build()` 开头就调用 `Config.init`，所以 HEAD 打了 `gx-v*` tag 之后，连 `zig build --help` 都会 panic：开发者与 CI 在发布提交上做的任何未显式传版本串的构建都无法进行。

### 行为

| HEAD 上的 tag | 补丁前 | 补丁后 |
|---|---|---|
| 无，或 `tip` | 分支预发布版本 `X.Y.Z-<branch>+<hash>` | 不变 |
| `vX.Y.Z`，且与产品版本一致 | 正式版本 `X.Y.Z` | 不变 |
| 其他以 `v` 开头的 tag | panic | 不变，仍然 panic |
| 不以 `v` 开头的 tag，如 `gx-v0.1.0` | panic | 分支预发布版本 `X.Y.Z-<branch>+<hash>` |

- 传了 `-Dversion-string` 时直接使用它；作为依赖构建时跳过 git 推导。这两条路径都不受补丁影响，`gx-release` 的构建本来就显式传 `-Dversion-string=<X.Y.Z>-gx.<fork 版本>`。
- `<branch>` 来自 `git rev-parse --abbrev-ref HEAD`，其中不属于 `[0-9A-Za-z-]` 的字符替换为 `-`：在 `gx_ghostty` 分支上是 `gx-ghostty`，分离 HEAD（例如 CI 检出 tag）时是 `HEAD`。

### 上游状态

未回馈上游。上游只使用 `vX.Y.Z` 与 `tip` 两种 tag，这个补丁只服务 fork 的发布命名。如需回馈，由人类按上游流程处理；agent 不创建 issue 或 PR。

### 同步冲突处理

上游改动这段版本推导时，先取上游版本，再按同一语义重新施加补丁：`tip` 与以 `v` 开头的 tag 保持上游行为，不以 `v` 开头的 tag 跳过发布校验、回退到分支预发布版本；保留 `fork(gx): GX-0001` 标记。之后跑下方的测试锁定与验证。如果上游已经不会因这类 tag panic，按「移除条件」处理。

### 移除条件

上游版本推导不再因非 `v` 前缀 tag panic（或不再从 tag 推导版本），并且去掉补丁后，下方验证的第一步仍然成功。移除时删除改动与标记，把登记行改为 `removed`，并删掉 `scripts/test_fork_patches.py` 中针对 GX-0001 的形状断言。

### 验证

先用 `just setup` 装好钉版 Zig。在仓库根目录（Git Bash 或 Linux shell；Linux/macOS 把 `python` 换成 `python3`）用临时 clone 加轻量 tag 复现：

```bash
git clone --quiet . .local/tmp/gx0001
cp src/build/Config.zig .local/tmp/gx0001/src/build/Config.zig
git -C .local/tmp/gx0001 tag gx-v0.0.0
(cd .local/tmp/gx0001 && python ../../../scripts/zigw.py build --help)
git show "$(git merge-base HEAD main):src/build/Config.zig" > .local/tmp/gx0001/src/build/Config.zig
(cd .local/tmp/gx0001 && python ../../../scripts/zigw.py build --help)
rm -rf .local/tmp/gx0001
```

- 第一次 `zig build --help` 使用带补丁的 `Config.zig`，应成功并列出构建选项。
- 第二次换回最近一次合入的上游版本（`HEAD` 与 `main` 的 merge-base 上的 `Config.zig`，`main` 只镜像上游），应 panic：`tagged releases must be in vX.Y.Z format matching build.zig`。
- clone 位于 gitignored 的 `.local/` 下，tag 只打在 clone 里，不影响本仓；`scripts/zigw.py` 不改变工作目录，所以构建的是 clone，用的是本仓钉版 Zig 与 `.local/zig-cache/global` 缓存。

### 测试锁定

`scripts/test_fork_patches.py` 随 `just framework-test` 运行；单独运行用 `python -m unittest scripts.test_fork_patches -v`。它锁定：

- 登记表格式合法，每个 active 标记都存在于对应文件；
- 闭集：范围内全部 `fork(gx)` 标记都已登记；
- GX-0001 的形状：`Config.zig` 中只有一行 `std.mem.startsWith(u8, tag, "v")` 守卫，它与 `tip` 判断写在同一个条件里，紧邻其上有标记注释，位置在 `if (vsn.tag) |tag|` 之内、上游 panic 之前；上游的 `vX.Y.Z` 比较、panic 与分支预发布回退都原样保留。
