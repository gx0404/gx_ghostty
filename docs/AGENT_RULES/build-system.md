# build-system：Zig 构建图、选项、版本与生成物

## 范围

- 构建入口：`build.zig`、`build.zig.zon` 及生成的 `build.zig.zon.{json,nix,txt}`、`src/build/**`、`src/build_config.zig`、构建期程序 `src/helpgen.zig` 与 `src/main_build_data.zig`。
- 依赖与环境：`pkg/**`、`vendor/**`、`nix/**`、`flake.nix`、`flake.lock`、`default.nix`、`shell.nix`、`.envrc`；以及上游的 `Makefile`、`CMakeLists.txt`、`HACKING.md`、`.gitignore`、`.gitattributes`。
- 交叉部分取并集：源码包与安装资源 → `packaging-dist.md`；`GhosttyLibVt.zig`、CMake、示例 → `libghostty-vt.md`；`GhosttyLib.zig` → `libghostty-embedding.md`；`GhosttyI18n.zig`、`gtk.zig` → `apprt-gtk.md`；Xcode → `macos-app.md`；`GhosttyBench.zig`、`nix/tests.nix`、`pkg/afl++` → `testing.md`；钉版工具链 → `development.md`。

## 符号真源

### 构建步骤（`build.zig::build`）

| 步骤 | 内容 | 条件 |
|---|---|---|
| `install`（默认） | 安装到 `zig-out/` | Windows 只有库：`ghostty-vt` 动态/静态库，非 lib-vt 模式另有 `ghostty-internal` |
| `run` / `run-valgrind` | 运行 app / valgrind 下运行 | `app-runtime` 不为 `none`；macOS 的 `run` 打开原生 app |
| `test` | 以 `src/main.zig` 为根的 `ghostty-test`（Debug、baseline CPU） | `-Demit-lib-vt` 时为空步骤 |
| `test-lib-vt` / `test-lib-vt-build` | `ghostty-vt`、`ghostty-vt-c` 两个模块的测试 / 只编译 | 始终定义 |
| `test-lib-vt-schema` | `python3` 运行 `src/terminal/c/types-schema-verify.py` 校验 ABI 清单 | native freestanding 目标报错 |
| `test-valgrind` | valgrind 下跑 `ghostty-test` | 需 valgrind（Linux） |
| `update-translations` | 重写 `po/` 的 pot 与 po | i18n 关闭时报错 |
| `dist` / `distcheck` | 源码包 / 解包验证 | 见 `packaging-dist.md` |

`run-<fuzzer>` 只在 `test/fuzz-libghostty/build.zig`（`testing.md`）。`-Dtest-filter`（`build.zig::build` 声明）可重复给出，只作用于 Zig 测试。

### 关键选项（`src/build/Config.zig::init`）

- 目标：`-Dtarget`、`-Dcpu`、`-Doptimize`。Windows 目标未写 ABI 时强制 `msvc`（GNU ABI 产出的 COMDAT 会被 MSVC 链接器拒绝）；iOS 只允许 `-Demit-lib-vt`。
- 编译期接口：`-Dapp-runtime`（默认见 `src/apprt/runtime.zig::Runtime.default`：Linux/FreeBSD 为 `gtk`，其余为 `none`）、`-Drenderer`、`-Dfont-backend`。
- 产物：`-Demit-lib-vt`（作为依赖构建时默认开启，并改变 exe、docs、macOS app 的默认值）、`-Dvt-features`，以及 `-Demit-exe`、`-Demit-bench`、`-Demit-docs`（需 pandoc）、`-Demit-xcframework` 等 `-Demit-*` 开关。
- 特性、二进制与版本：`-Dsimd`、`-Dsentry`、`-Dgtk-x11`、`-Dgtk-wayland`、`-Dflatpak`、`-Dsnap`、`-Dpie`、`-Dstrip`、`-Dpatch-interp`、`-Dpatch-rpath`、`-Dversion-string`、`-Dlib-version-string`；`-Di18n` 默认只在 macOS/iOS 与 glibc 的 Linux/FreeBSD 开启，Windows、musl 默认关闭。
- 系统库：`--system <包目录>` 进入系统包模式（不联网取包、依赖默认动态链接、默认 PIE）；`-fsys=<名>` / `-fno-sys=<名>` 逐项切换，名单登记在 `Config.init` 与 `src/build/SharedDeps.zig::addSimd`。

选项全集与默认值以 `just zig build --help` 为准，文档不抄默认值。

### 版本推导（`Config.init` 与 `src/build/GitVersion.zig::detect`）

1. 基线是 `build.zig.zon` 的 `.version`；源码包里改用根目录 `VERSION` 文件（`build.zig::build` 读取）。
2. 给了 `-Dversion-string` 就原样使用（须为合法 SemVer）；作为依赖被构建时只取 `X.Y.Z`。
3. 否则探测 git：没有 git 或不在仓库内得到 `X.Y.Z-dev+0000000`；HEAD 在以 `v` 开头的 tag 上时，tag 必须等于 `vX.Y.Z`（得到 `X.Y.Z`），否则 `@panic`；`tip` 与 fork 补丁 GX-0001 覆盖的非 `v` 前缀 tag（如 `gx-v0.1.0`）跳过该检查；其余得到 `X.Y.Z-<分支名>+<短 hash>`，分支名中 `[0-9A-Za-z-]` 以外的字符换成 `-`，本分支即 `1.3.2-gx-ghostty+<hash>`。
4. `Config.addOptions` 把预发布段非空的版本标为 `tip` 渠道，否则 `stable`；`+version` 打印 `src/build_config.zig::version_string` 与 `release_channel`。
5. libghostty-vt 版本是常量 `build.zig::lib_version`，只能用 `-Dlib-version-string` 覆盖；该选项的帮助文本称会用 git，实现并不探测。

fork 发布版本串与 tag 见 `ci-release.md`，GX-0001 的原因与移除条件见 `docs/FORK_PATCHES.md`。

### Zig 版本与依赖

- Zig 版本真源是 `build.zig.zon` 的 `.minimum_zig_version`；`build.zig` 编译期调用 `src/build/zig.zig::requireZig`，主次版本必须相同、补丁号不得更低，即只接受 0.16.x。同一版本号还硬编码在 `flake.nix`、`nix/package.nix`、`nix/libghostty-vt.nix`（`zig_0_16`）、`snap/snapcraft.yaml`、`flatpak/dependencies.yml`（以上随上游同步更新），以及 fork 的 `scripts/setup_zig.py::ZIG_VERSION` 与各平台 sha256 钉版 `PINS`（同步时手动升级，步骤见 `development.md`）。
- 根 `build.zig.zon` 的 URL 依赖都带 `.hash`，大多取自上游镜像 `deps.files.ghostty.org`；`pkg/*/build.zig.zon` 再各自引入 C 源码包。完整清单（含传递依赖）是生成的 `build.zig.zon.txt`，少数来自 GitHub、Codeberg 与 freedesktop GitLab。
- 经 zigw 运行时全局缓存默认在 `.local/zig-cache/global`；Zig 0.16 把依赖解包副本放在项目根 `zig-pkg/`，它与 `.zig-cache/`、`zig-out/` 都被上游 `.gitignore` 忽略，不入库。
- `pkg/<名>/` 是独立 Zig 包（自带 `build.zig` 与 `build.zig.zon`），根清单以 `.path` 引用、大多为 lazy，由 `src/build/SharedDeps.zig::add` 统一挂到 exe、lib 与测试上；`override/` 放构建期配置头，`pkg/breakpad/vendor/`、`pkg/simdutf/vendor/` 是第三方源码副本；部分包有自己的 `test` 步骤（上游 CI 只跑 `pkg/wuffs`）。

### 生成物登记表

| 产物 | 生成器 | 检查 |
|---|---|---|
| `build.zig.zon.{json,nix,txt}`、`flatpak/zig-packages.json` | `./nix/build-support/check-zig-cache.sh --update`（zon2nix 等，需 Nix devShell） | 同一脚本不带参数；上游 `nix.yml` 的检查已随归档停用 |
| `vendor/glad/` | `Makefile` 的 `glad` 目标解压 gen.glad.sh 生成的 `glad.zip`（只含 GL loader；EGL 部分 `glad_egl.*` 与 `include/EGL/eglplatform.h` 来自另一次生成，`make glad` 先 `rm -rf vendor/glad` 会删掉它们） | 审 diff |
| `po/` 的 pot 与 po | `zig build update-translations` | 见 `apprt-gtk.md` |
| help 字符串、Unicode 表、`+boo` 动画帧、terminfo、补全与编辑器语法、GTK gresource | `src/build/` 的 `HelpStrings`、`UnicodeTables`、`GhosttyFrameData`、`GhosttyResources` 等 | 只在 `.zig-cache/`；gresource 与动画帧另由 `dist` 预生成进源码包 |
| `graphify-out/` 入库部分、`docs/kb/chunks.json` | `just graph`、`just kb` | 见 `development.md` |

`nix/zigCacheHash.nix` 不被任何 Nix 表达式引用（`HACKING.md` 对它的说明与脚本不符）；`nix/build-support/update-mirror.nu` 向上游镜像上传依赖，fork 不用。

### 平台

- Windows 原生构建需要人类安装 Visual Studio（Build Tools 即可）的 C++ 工具集与 Windows SDK，`just doctor` 检查前者。`x86_64-windows-msvc` 不能从 Linux 交叉编译（归档的上游 `test.yml` 注释：缺 MSVC 头文件）；显式写 `x86_64-windows-gnu` 不受强制 msvc 影响，可以交叉。
- `nix/devShell.nix`（经 `flake.nix` 与 `.envrc` 的 `use flake` 加载）是上游 CI 的统一环境，带 zon2nix、valgrind、pandoc、blueprint-compiler 等；gx-ci 与本机都不用 Nix。

## 不变量

- 构建逻辑写在 `src/build/` 的模块里，`build.zig` 只做编排；新 `-D` 选项在 `Config.init` 声明，需要编译期常量时经 `Config.addOptions` 与 `src/build_config.zig` 暴露。
- `build.zig.zon` 的依赖一变（URL、hash、增删），就在有 Nix 的 Linux/macOS 上跑 `check-zig-cache.sh --update`，生成文件与清单进同一提交；fork CI 不查新鲜度，漏跑会让 Nix、Flatpak 与离线打包静默失效。
- 生成物默认只检查；只有有意变更时才用登记表中的生成器重建，并审 diff。
- `test` 不依赖 `test-lib-vt`（`build.zig::build` 中那条依赖被注释掉），二者是独立的门，互不代证。
- 产品版本只随上游同步变化：fork 不改 `build.zig.zon` 的 `.version` 与 `nix/package.nix` 等处的硬编码版本；fork 版本只体现在 `CHANGELOG.md` 与发布时的 `-Dversion-string`。
- `src/build/Config.zig` 上唯一的 fork 改动是带 `fork(gx)` 标记的 GX-0001；再改上游构建文件须按 GX-NNNN 登记（`development.md`），不顺手重排或重格式化。
- fork 内经 just 配方调用钉版 Zig。`CMakeLists.txt` 的 `find_program`、`distcheck` 的内层命令与 CMake 示例都从 PATH 找 `zig`；PATH 上没有 0.16.x 时这些路径记 PENDING。

## 禁止项

- 不手改 `build.zig.zon.{json,nix,txt}`、`flatpak/zig-packages.json`、`vendor/glad/`；`pkg/*/vendor/` 的第三方源码只随上游同步更新。
- 不为绕过 `requireZig` 改 `minimum_zig_version` 或 `src/build/zig.zig`，不用其他版本的 Zig 构建。
- 不改 `build.zig.zon` 的 `.version`、`.fingerprint`，不把依赖 URL 指向 fork 私有镜像，不运行 `update-mirror.nu`。
- 不改上游 `Makefile`（fork 入口是 `justfile`），不为本机换行问题改 `.gitattributes`。

## 验证

- 改构建逻辑或选项：`just zig build --help`、`just build`、`just build-vt`，再 `just test -Dtest-filter=<名>` 与 `just test-vt`，收尾 `just ci-check`。
- 改版本推导：分支 HEAD 上 `just zig build --help` 成功；按 `docs/FORK_PATCHES.md` 中 GX-0001 的「验证」步骤，在 `.local/tmp/` 的临时 clone 里打 `gx-v0.0.0` tag 做正反证（不在真实仓库打 tag）；再跑 `python -m unittest scripts.test_fork_patches`。
- 改依赖：在 Nix 主机上 `nix develop -c ./nix/build-support/check-zig-cache.sh` 通过；本机没有 Nix 时记 PENDING 并附该命令。
- 改 `pkg/<名>`：该包有 `test` 步骤时在 `pkg/<名>/` 下运行 `python ../../scripts/zigw.py build test`（Linux/macOS 用 `python3`），再用 `just build` 或 `just test-vt` 覆盖用到它的产物。
- 跨平台改动：`just build-vt -Dtarget=<triple>` 交叉编译通过；只影响 Windows MSVC 的改动以本机原生构建或 gx-ci `windows` job 为证据。
