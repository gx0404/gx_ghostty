# 版本与发布

本文是 `gx0404/gx_ghostty` 的发版手册：版本号从哪里来、怎样定版、`gx-release` 每个 job 做什么、产出哪些资产、出错时怎样处理。规则约束见 `docs/AGENT_RULES/ci-release.md`，命令清单见 [MAKE_COMMANDS.md](MAKE_COMMANDS.md)。

## 两套版本

| | 产品版本（上游体系） | fork 版本（本框架） |
|---|---|---|
| 真源 | `build.zig.zon` 的 `.version`，当前为 `1.3.2-dev` | 根 `CHANGELOG.md` 中数值最大的 `## X.Y.Z(YYYY-MM-DD\|TBD)` 标题，当前为 `0.1.0` |
| 读取 | `src/build/Config.zig::init` | `scripts/version.py::current`；`just version` 打印，`just version-check` 校验 |
| fork 是否修改 | 不改，随上游同步变化 | 每次发版前定版、发版后开新版本 |

两者在发版时组合，互不同步：

- tag：`gx-vX.Y.Z`；release 名：`Ghostty GX X.Y.Z`（X.Y.Z 为 fork 版本）。
- 构建版本串：`VS = <产品版本的 X.Y.Z>-gx.<fork 版本>`。产品版本去掉预发布与构建元数据部分，所以当前是 `1.3.2-gx.0.1.0`。
- `gx-release` 的每个 `zig build` 都传 `-Dversion-string=$VS`。产物里 `ghostty +version` 输出 `  - version: 1.3.2-gx.0.1.0`；因为版本带预发布段，`src/build/Config.zig::addOptions` 把发布通道设为 `tip`。

不传 `-Dversion-string` 时，版本按 `src/build/Config.zig::init` 推导，优先级如下：

1. 构建根目录有 `VERSION` 文件（源码包里才有）时，用它代替 `build.zig.zon` 的 `.version` 作为基础版本（`build.zig::build`）。
2. 作为别的工程的依赖构建时，直接用基础版本的 X.Y.Z。
3. 否则由 `src/build/GitVersion.zig::detect` 读 Git：分支构建得到 `X.Y.Z-<分支>+<短 hash>`，分支名中 `[0-9A-Za-z-]` 以外的字符换成 `-`（`gx_ghostty` 变成 `gx-ghostty`）；不在 Git 仓库里时得到 `X.Y.Z-dev+0000000`。HEAD 恰好有 tag 时，上游只接受 `tip` 与 `v<X.Y.Z>`，其余 tag 会 panic；`gx-v*` 这类非 `v` 前缀 tag 由补丁 GX-0001 改为按分支版本处理，见 [FORK_PATCHES.md](FORK_PATCHES.md)。

libghostty-vt 的库版本是另一条线：`build.zig` 的常量 `lib_version`（当前 `0.1.0-dev`），可用 `-Dlib-version-string` 覆盖，fork 不改。发版资产的文件名统一用 `$VS`。

## CHANGELOG 规则

- 根 `CHANGELOG.md` 只记 fork 的可观察变更：框架、开发流程、构建补丁、发布链。上游 Ghostty 没有 CHANGELOG，这里也不转述上游的产品变更。
- 版本标题只有 `## X.Y.Z(YYYY-MM-DD)` 与 `## X.Y.Z(TBD)` 两种；二级标题只用于版本，小节用 `### Added` / `### Changed` / `### Fixed`。
- 数值最大的标题就是当前 fork 版本，与书写顺序无关。它还是 `(TBD)` 时，新条目写在它下面；它已定版时，先加新的 `(TBD)` 标题再写。
- `just version-check`（`version.py --check`）要求全部标题合法、版本不重复、至少一个；`version.py --release` 另外要求最大版本已带日期。发布模式的 prepare 也做同样的日期检查。
- `CHANGELOG.md` 的开头 6000 字符（`scripts/build_agent_kb.py::CHANGELOG_HEAD_CHARS`）是知识库语料，版本标题与新条目都落在这一段。所以每次改 CHANGELOG（加条目、定版、开新版本）都要接着运行 `just kb`，把重建的 `docs/kb/chunks.json` 与 CHANGELOG 放进同一个提交，提交前用 `just kb-check` 确认；漏掉时 `gx-ci` 的 `framework` job 在 KB 新鲜度检查上失败，依赖它的 job 全部跳过。

## 发版步骤

1. **定版提交**：把最大版本的 `(TBD)` 改成当天日期，然后依次运行 `just graph`、`just kb`、`just generated-check`。定版的 CHANGELOG、重建后的 `graphify-out/` 与 `docs/kb/chunks.json` 一起提交为 `chore(release): 定版 X.Y.Z`。图谱或 KB 不新鲜时 prepare 会拒绝发版。提交后可在干净检出上运行 `python scripts/gx_release.py prepare`（Linux/macOS 用 `python3`）预演：它跑完四道发版门，并打印将使用的 SHA、tag 与版本串。
2. **push**：由用户把 `gx_ghostty` push 到 `origin`，等 `gx-ci` 变绿。
3. **构建验收**：Actions → gx-release → Run workflow。分支选 `gx_ghostty`，`ref` 保持默认 `gx_ghostty`（也可以填完整提交 SHA），`publish` 关闭，`macos` 按需。等价命令：`gh workflow run gx-release.yml --ref gx_ghostty -f ref=gx_ghostty -f publish=false -f macos=false`。跑完后从该运行的 Artifacts 下载 `verified-release` 检查产物（保留 14 天）。
4. **发布**：同样的输入再运行一次，把 `publish` 打开。这次运行会从头重新构建，发布的是本次运行构建并校验过的产物，不复用第 3 步的 artifact。
5. **开新版本**：在 `CHANGELOG.md` 顶部加下一个 `## X.Y.Z(TBD)` 标题，运行 `just kb`，把 CHANGELOG 与重建的 `docs/kb/chunks.json` 一起提交（KB 语料包含 CHANGELOG 开头，见「CHANGELOG 规则」）。

agent 可以准备定版提交并在本地验证；push、运行 workflow 与发布由用户决定。不要手工创建 `gx-v*` tag 或 GitHub release，tag 只由 publish job 创建。

## gx-release 的 job

所有 job 都只在 `gx0404/gx_ghostty` 上通过 `workflow_dispatch` 运行；同一时间只跑一个发版（`concurrency: gx-release`，不取消进行中的运行）。输入只经 `env:` 传给脚本，`run:` 里不内插 `${{ }}`。

| job | runner | 做什么 |
|---|---|---|
| `prepare` | ubuntu-24.04 | 检出 `ref`，运行 `scripts/gx_release.py prepare`，输出 `sha`、`version`、`tag`、`version_string`、`zig` |
| `source` | ubuntu-24.04 | `zig build distcheck -Demit-lib-vt=true -Dversion-string=$VS`，产出 libghostty-vt 源码包并检查不超过 5 MiB |
| `libvt` | ubuntu-24.04 / windows-2025 | 矩阵构建 libghostty-vt：Linux 三个目标与 wasm32 在 ubuntu 上交叉编译，`x86_64-windows-msvc` 在 windows-2025 上原生构建 |
| `libvt-macos` | macos-15 | 仅 `macos=true`：构建 libghostty-vt XCFramework |
| `linux-gtk` | ubuntu-24.04 中的 `debian:13` 容器 | `zig build dist` 产出完整源码包，再从该源码包构建 GTK app 并检查 `+version` |
| `linux-gtk-noble` | ubuntu-24.04 中的 `ubuntu:24.04` 容器 | 按 GX Shell 的消费方命令从检出构建 GTK app 并生成、校验 deb stage，再装成一次性测试包，检查 `+version` 并截图；只上传证据 artifact `evidence-linux-gtk-noble`，不产出发布资产 |
| `macos` | macos-26 | 仅 `macos=true`：构建 `Ghostty.app`。macos-15（Xcode 26.3）编不过 `images/Ghostty.icon` 的资源目录（2026-10-07 run 37587740223），上游也在 macOS 26 上构建 app |
| `verify` | ubuntu-24.04 | 收集全部产物，运行 `scripts/gx_release.py verify`，写出 `manifest.json` 与 `SHA256SUMS`；只构建模式也运行 |
| `publish` | ubuntu-24.04 | 仅 `publish=true`：运行 `scripts/gx_release.py publish`；唯一拥有 `contents: write` 的 job |

`prepare` 依次检查：

1. 检出干净（`git status --porcelain --untracked-files=all` 为空），HEAD 是完整 SHA。
2. 读 CHANGELOG 与 `build.zig.zon`，`scripts/setup_zig.py` 的 `ZIG_VERSION` 必须等于 `build.zig.zon` 的 `minimum_zig_version`。
3. 发布模式要求最大版本已带日期。
4. 四道发版门：`resolve_agent_rules.py --check`、`version.py --check`、`build_agent_kb.py`（KB 新鲜度）、`graphify.py check`（图谱指纹）。图谱检查只在这里与上游同步后强制，不进 push CI。
5. 发布模式再确认 `origin` 指向本仓，`git ls-remote --tags origin` 查不到该 tag，`gh release view` 查不到该 release。prepare 只有只读 token，看不到草稿；草稿由 publish 用写 token 再查一遍。

构建 job 的 Zig 由 `mlugg/setup-zig` 按 prepare 输出的版本安装，关闭它的缓存；`ZIG_GLOBAL_CACHE_DIR` 与 `ZIG_LOCAL_CACHE_DIR` 都放在 `$RUNNER_TEMP`。这是为 `distcheck` 准备的：`src/build/GhosttyDist.zig::init` 用 `git archive` 打包 HEAD（只含已提交内容，并写入 `VERSION` 文件），再把包解压到本地缓存目录里，执行 `zig build test-lib-vt -Demit-lib-vt=true` 和一次 CMake 构建。这个内层构建没有 `-Dversion-string`，会对解压目录运行 `git -C`；缓存在检出目录之外时它找不到任何仓库，版本退回 `X.Y.Z-dev+0000000`，与真正拿到源码包的用户一致。若缓存留在检出目录内（Zig 默认的 `.zig-cache`），内层构建会读到外层仓库的分支和 tag。

`linux-gtk` 的依赖取自 `src/build/docker/debian/Dockerfile`，另加 `git`、`ca-certificates`、`xz-utils` 与提供 `msgfmt` 的 `gettext`（i18n 编译 `.po`，见 `src/build/GhosttyI18n.zig::init`）。容器以 root 运行而工作区属于 runner 用户，所以检出后要把工作区加入 `safe.directory`，否则 `git archive` 会拒绝执行。完整源码包内含预生成的 `src/apprt/gtk/ghostty_resources.{c,h}` 与 `src/build/framegen/framedata.compressed`（`src/build/GhosttyDist.zig::Resource`），从源码包构建不再需要 blueprint-compiler。

`linux-gtk-noble` 验证 GX Shell 在 Ubuntu 24.04 上要用的构建链，命令与 `scripts/gx_package.py` 模块文档「Consumer contract」一字不差（`scripts/test_gx_workflows.py` 锁定）：检出前只装 `ca-certificates`、`git`、`python3`，然后 `gx_package.py deb --build --install-deps` 与 `verify-stage`。构建配方是 `scripts/gx_linux_build.py`：apt 依赖按它的清单检查并安装；Ubuntu 24.04 的 blueprint-compiler 只有 0.12，配方下载 sha256 钉版的 0.16.0（GNOME GitLab 的 tag 归档，失败时用 GNOME 的 GitHub 镜像）并用 meson 装进 `.local/tools/`；这个 job 不用 `mlugg/setup-zig`，Zig 由 `scripts/setup_zig.py` 按 sha256 钉版安装，与没有 setup-zig 的消费方一致；Ubuntu 24.04 没有 `libgtk4-layer-shell-dev`，所以用 `-fno-sys=gtk4-layer-shell` 把它编成随包的 `libgtk4-layer-shell.so`，再用 `-Dpatch-rpath='$ORIGIN/../lib'`（patchelf 0.18.0）把可执行文件的 RUNPATH 换成相对路径，不需要 `LD_LIBRARY_PATH`。之后用 `test-deb` 把 stage 打成一次性测试包，在同一容器 `apt-get install` 后检查 `ghostty-gx +version`，并以与 `gtk-smoke` 相同的 Xvfb 参数截图。证据（stage 日志、`stage-manifest.json`、`readelf -d`、测试包信息、`+version`、截图与日志）以 artifact `evidence-linux-gtk-noble` 上传，名字不以 `gx-` 开头，`verify` 不收集它；`verify` 要求这个 job 成功。真正的 deb 由 GX Shell 用 stage 的 `root/` 与 `deb_depends` 构建。

## 资产

`$VS` 即构建版本串。默认 8 个构建产物，加上 `manifest.json` 与 `SHA256SUMS` 共 10 个文件；`macos=true` 时再多 2 个。

| 资产 | job | 内容 |
|---|---|---|
| `libghostty-vt-$VS.tar.gz` | `source` | libghostty-vt 源码包，顶层目录 `libghostty-vt-$VS/`，排除 `src/build/GhosttyDist.zig::lib_vt_excludes` 列出的目录与带 `export-ignore` 属性的文件 |
| `ghostty-$VS.tar.gz` | `linux-gtk` | 完整源码包，顶层目录 `ghostty-$VS/`，同样不含带 `export-ignore` 属性的文件 |
| `libghostty-vt-$VS-x86_64-linux-gnu.tar.gz` | `libvt` | `include/ghostty/`、`lib/libghostty-vt.so*`、`lib/libghostty-vt.a`、`share/pkgconfig/` |
| `libghostty-vt-$VS-aarch64-linux-gnu.tar.gz` | `libvt` | 同上 |
| `libghostty-vt-$VS-x86_64-linux-musl.tar.gz` | `libvt` | 同上 |
| `libghostty-vt-$VS-wasm32-freestanding.tar.gz` | `libvt` | `bin/ghostty-vt.wasm`（ReleaseSmall，默认启用 simd128） |
| `libghostty-vt-$VS-x86_64-windows-msvc.zip` | `libvt` | `ghostty-vt.dll` 及导入库、`lib/ghostty-vt-static.lib`、`include/ghostty/` |
| `ghostty-gx-$VS-x86_64-linux-debian13.tar.gz` | `linux-gtk` | 实验性 GTK app，顶层目录下是 `usr/`（`--prefix /usr` 安装），可执行文件为 `usr/bin/ghostty` |
| `libghostty-vt-$VS-xcframework.zip` | `libvt-macos` | `ghostty-vt.xcframework`：macOS universal，SDK 存在时另含 iOS 与 iOS 模拟器切片（`src/build/GhosttyLibVt.zig::initStaticAppleUniversal`） |
| `ghostty-gx-$VS-universal-macos-unsigned.zip` | `macos` | `Ghostty.app`，用 Xcode 的 `ReleaseLocal` 配置构建（`src/build/GhosttyXcodebuild.zig::init`）；该配置在 `macos/Ghostty.xcodeproj` 中只做 ad-hoc 签名 |
| `manifest.json` | `verify` | 仓库、tag、三种版本、Zig 版本、源码提交，以及每个资产的类型、目标、大小与 SHA-256 |
| `SHA256SUMS` | `verify` | 上面所有文件（不含自身）的 `sha256sum` 格式校验和 |

使用注意：

- 两个源码包都由 `git archive` 打包已提交的内容，fork 文件（`scripts/`、`docs/`、工具配置等）也随之进包。体积最大的 fork 文件、知识库产物 `docs/kb/chunks.json` 由 `docs/kb/.gitattributes` 标为 `export-ignore`，不进任何源码包，GitHub 为分支与 tag 自动生成的 Source code（zip / tar.gz）同样不含它；需要 KB 时用 Git 检出（KB 已入库，`just kb` 也能重建）。libghostty-vt 源码包有 5 MiB 上限（`source` job 与 `verify` 都检查），新增大的 fork 文件前先估算它会不会把源码包推过上限，必要时同样用所在 fork 目录的 `.gitattributes` 标 `export-ignore`，不改上游的根 `.gitattributes`。
- 预编译库构建时用 `--prefix` 安装到 runner 临时目录，`share/pkgconfig/*.pc` 里的 `prefix=` 是这个构建时路径（`src/build/GhosttyLibVt.zig` 用安装前缀生成 `.pc`）；用 pkg-config 前先改成解压位置，或直接用 `include/` 与 `lib/`。
- GTK app 动态链接系统的 GTK 4、libadwaita 与 gtk4-layer-shell，只在 Debian 13 上构建与检查过；Ubuntu 24.04 不用这个包，而由 GX Shell 从 `linux-gtk-noble` 验证过的 stage 构建自己的 deb。资源目录按 `src/os/resourcesdir.zig::resourcesDir` 查找：从可执行文件所在目录向上找 `share/terminfo`，也可用 `GHOSTTY_RESOURCES_DIR` 指定。
- macOS 包没有 Developer ID 签名，也没有公证；首次打开会被 Gatekeeper 拦截，需要用户自行放行。

## 校验

`verify` 在构建验收与发布两种模式下都运行，检查：

- 目录里恰好是预期的资产集合（`scripts/gx_release.py::expected_assets`），每个都是非空普通文件；
- 每个归档的成员都在约定的顶层目录下，没有绝对路径、`..` 或越界链接，并含有该资产必需的文件；
- 两个源码包里的 `VERSION` 等于 `$VS`，libghostty-vt 源码包不超过 5 MiB；
- 检出的 HEAD 等于 prepare 的 SHA，`$VS` 与该检出推导的版本一致；
- 生成确定性的 `manifest.json`（排序键、LF、无时间戳）与 `SHA256SUMS`；文件已存在时必须逐字节一致，不覆盖。

用户下载后可以这样校验：Linux 用 `sha256sum -c SHA256SUMS`，macOS 用 `shasum -a 256 -c SHA256SUMS`，Windows PowerShell 用 `Get-FileHash <文件> -Algorithm SHA256` 对照。也可以在同一提交的干净检出上重跑本地校验：`python scripts/gx_release.py verify --sha <完整 SHA> --artifacts <目录>`（含 macOS 资产时加 `--macos`）。

`publish` 的顺序：

1. 确认运行在本仓手动触发的 `gx-release` 里（`GITHUB_REPOSITORY`、`GITHUB_EVENT_NAME`、`GITHUB_WORKFLOW_REF`、`GX_PUBLISH=true`），否则拒绝执行任何远端操作。
2. 对下载的 `verified-release` 重跑全部本地校验。
3. tag、release 与同名草稿都必须不存在。
4. `gh release create` 创建草稿：`--draft --prerelease --target <SHA> --title "Ghostty GX X.Y.Z"`。
5. `gh release upload` 上传全部文件，不带 `--clobber`。
6. 用 `gh api` 读回资产列表，名称集合、`state`、大小与 `digest`（`sha256:`）必须与本地逐一相等；再确认草稿仍绑定同一 SHA，tag 仍不存在。
7. 把草稿改为正式的 prerelease；GitHub 此时在该 SHA 上创建 tag，脚本再用 `git ls-remote` 确认 tag 指向该 SHA。

## 拒绝与回滚

- prepare 拒绝：检出不干净、发布模式下版本仍是 `(TBD)`、任一发版门失败、tag 或 release 已存在。修复后提交、push，再重新运行 workflow；不要重跑旧运行指望它用到新代码。
- verify 拒绝：资产缺失、多余、为空、结构不对、版本不符，或已有的 `manifest.json`、`SHA256SUMS` 与本次结果不同。
- publish 在第 4 步之后失败会留下草稿，不会自动删除，也不会发布。到 Releases 页面检查草稿，确认后手工删除，再重新运行；脚本发现同名草稿时一律拒绝，不续传。
- 已发布的版本不覆盖、不删后重建，tag 不移动、不重用。发现问题就在 `CHANGELOG.md` 加新版本重新走流程；需要撤下时由人类在 GitHub 上编辑或删除该 release，版本号视为已用掉。
- 代码层面的回滚用 `git revert` 生成新提交，再按新版本发布。

## 首次启用（手动步骤）

- **启用 Actions**：fork 默认不运行 workflow。在 fork 的 Actions 页面点击 “I understand my workflows, go ahead and enable them”，或在 Settings → Actions → General 允许运行。只读确认：`gh api repos/gx0404/gx_ghostty/actions/permissions`。
- **默认分支**：`workflow_dispatch` 要求 workflow 文件在默认分支上，fork 的默认分支应为 `gx_ghostty`（本地 `refs/remotes/origin/HEAD` 记录的正是 `origin/gx_ghostty`）。
- **权限**：仓库默认的 `GITHUB_TOKEN` 权限可以保持只读。`publish` 在 job 内显式申请 `contents: write`，其余 job 都是只读。不需要配置任何 secret。

## workflow 归档与上游同步

- `.github/workflows/` 只启用 `gx-ci.yml` 与 `gx-release.yml`；上游 15 个 workflow 用 `git mv` 原样放在 `.github/workflows-archive/`，清单与归档原因见该目录的 `README.md`。`scripts/test_gx_workflows.py` 锁定两边的文件集合以及 workflow 的权限、触发器、钉版与传参形状。
- 同步上游后：上游新增的 workflow `git mv` 进归档；上游修改已归档的文件时，改动通常经 Git 重命名检测直接落到归档路径；上游删除时跟着删除归档副本，并更新 `test_gx_workflows.py` 的归档清单。
- 两个 gx workflow 复用上游已钉的 action 提交 SHA（`actions/checkout`、`actions/upload-artifact`、`actions/download-artifact`、`mlugg/setup-zig`）；上游升级钉版后，同步时把 `gx-*.yml` 改成同一 SHA，测试会核对。
- `.github/dependabot.yml` 原样保留；GitHub 对 fork 默认不开启 Dependabot version updates，所以 action 升级只随上游同步进行。
- 同步流程本身（`main` 快进、`chore(sync)` 合并、冲突处理）见 [DEVELOPMENT.md](DEVELOPMENT.md)。

## 与上游发布链的边界

上游的 `release-tag.yml`、`release-tip.yml`、`publish-tag.yml` 负责 minisign 签名的源码包、macOS 签名与公证、DMG、Sparkle appcast、上传 R2（`release.files.ghostty.org`、`tip.files.ghostty.org`）、Sentry 符号上传，`flatpak.yml` 与 `snap.yml` 负责 Flatpak 与 Snap。这些都依赖上游的 runner 与 secrets，已经归档，fork 不运行。

`gx-release` 不做签名、不公证、不生成 appcast、不上传 R2，只在 fork 的 GitHub Releases 发布 prerelease。`PACKAGING.md` 里的源码包地址与 minisign 公钥属于上游正式版本，不适用于 fork 资产；fork 资产以 `SHA256SUMS` 与 `manifest.json` 为准。

## 首跑记录与仍待确认

Actions 已启用，以下首跑结果都在 2026-10-07 取得：

- `gx-ci` push：旧布局首跑约 22 min；新布局首跑 run 37582059213 约 14.4 min，`ghostty-test` 在 Linux 上分 4 路运行 3909 条用例全部通过。文档提交 `8d46309d8` 的 push run 37592253122 也已 success；缓存新实现的后续验收另列如下，不由这些历史结果代证。
- `gx-ci` 手动触发（run 37587736223，打开 `gtk_smoke` 与 `macos`）全部通过：`gtk-smoke` 在 `debian:13` 容器里构建 ReleaseFast 的 GTK app，在 Xvfb 下用 Mesa 软件渲染（OpenGL 4.5）启动；截图已下载读回，窗口标题栏、标签与菜单按钮、bash 提示符和光标都正常绘制。`macos` job 在 macos-15 上 `zig build test-lib-vt` 通过。
- `gx-release` 只构建运行（run 37589505152，`publish=false`、`macos=true`）全部通过：`verify` 校验了 12 个发布文件与 `SHA256SUMS`，包括 libghostty-vt 五个目标与 XCFramework、libghostty-vt 源码包、完整源码包、Linux GTK 包、未签名的 macOS app 和 `manifest.json`；libghostty-vt 源码包 4,518,520 字节，低于 5 MiB 上限。之前的 run 37587740223 里 `macos` job 在 macos-15 上失败，见上表 `macos` 行。

缓存新实现的真实验收：同一提交 `48b73e018` 的 [push 37601186564](https://github.com/gx0404/gx_ghostty/actions/runs/37601186564) 与 [手动 37603432582](https://github.com/gx0404/gx_ghostty/actions/runs/37603432582)（`cache_probe=true`）均全绿。三个测试 job 的工具链 exe/lib 路径两轮一致，第二轮恢复目录字节数与首轮结束值逐项相等，`stable-toolchain-v1` 缓存和完整 timings 确实恢复，post 均 `keeping intact`、未清空。同 runner probe 全 cached，分别为 0.315、0.416、1.094 s，且没有重复执行用例。固定路径、实际恢复与同机复建记 **PASS**；构建和用例明细见 [TESTING.md](TESTING.md)「两轮真实 CI 验收」。

仍待确认（PENDING）：

- **跨 runner 完整复用与缓存增长控制**：第二轮首次构建只有 10/45、49/100、10/45 节点 cached，translate-c 与测试编译仍未 cached，`o` 分区继续增长。`linux-vt`、`windows` 的 CPU 从 AMD EPYC 9V74 换成 7763 已由快照确认；`linux-main` 同为 9V74，仍有 miss。源码能解释工具产物差异如何经 `Run.artifact` hash 向下游传播，但初始 native 工具差异原因未定。旧 run 37587736223 的 `linux-vt` 曾达 5,078,327,232 字节、超过 4096 MiB 被清空，下一轮只恢复 186 字节；新实现不删除旧 cache，也未提高上限，未来仍可能超限。本次 PASS 不能写成跨运行全命中或所有缓存问题已解决，更不能代证全 CI 两分钟。
- 第一次 `publish=true`：GitHub 资产 `digest` 字段的读回、草稿发布时 tag 的创建。本轮未公开发布，也不为补验触发发布。
- `linux-gtk-noble` 的首跑：同样的命令已在本机 WSL 的全新 `ubuntu:24.04` podman 容器里跑通（2026-10-09，见 [TESTING.md](TESTING.md)），GitHub runner 上的结果与截图要等用户以 `publish=false` 运行 `gx-release` 后读回 artifact。
