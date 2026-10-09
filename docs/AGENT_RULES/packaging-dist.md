# packaging-dist：源码包、安装资源、下游渠道与 fork 发布资产

## 范围

- 构建侧：`src/build/GhosttyDist.zig`（`dist`/`distcheck`）、`src/build/GhosttyResources.zig`（安装资源）。
- 上游打包面：`PACKAGING.md`、`flatpak/**`、`snap/**`、`nix/package.nix`、`images/**`。
- `dist/**`：`linux/` 桌面集成模板（与 `apprt-gtk.md` 共管）、`macos/` appcast 脚本（与 `macos-app.md` 共管）、`windows/` 顶层编进 exe 的 rc、ico 与 manifest（与 `apprt-win32.md` 共管）、fork 的 `windows/gx/`（Inno Setup 脚本 `ghostty-gx.iss` 与随包许可证）、`cmake/` 与 `doxygen/`（规则见 `libghostty-vt.md`）。
- fork 打包脚本：`scripts/gx_windows_package.py`（`just package-windows`）、`scripts/gx_package.py`（`just stage`）、`scripts/gx_linux_build.py`、`scripts/gx_icon.py` 及其测试。
- fork 发布资产的内容与命名；`gx-release` 流程、`$VS` 版本串与 tag 见 `ci-release.md` 与 `docs/RELEASE.md`。

## 符号真源

### 源码包（`src/build/GhosttyDist.zig::init`）

- `zig build dist` 调用 `git archive --format=tgz … HEAD`：只打包已提交的 HEAD，工作树改动不进包。顶层目录与文件名都是 `<名>-<版本>`：完整包 `ghostty-<版本>.tar.gz`，`-Demit-lib-vt=true` 时 `libghostty-vt-<版本>.tar.gz`，安装到 `zig-out/dist/`。`<版本>` 是 `Config.version`（app 版本，含 `+<hash>` 构建段），lib-vt 包也用它而不是 `lib_version`。
- 包内追加根目录 `VERSION`（同一版本串，解包后由 `build.zig::build` 读作基线）与 `src/build/GhosttyDist.zig::Resource` 预生成资源：GTK 的 `src/apprt/gtk/ghostty_resources.{c,h}`（`src/build/SharedDeps.zig::gtkNgDistResources`）和 `src/build/framegen/framedata.compressed`（`src/build/GhosttyFrameData.zig::distResources`），打包者因此不需要 blueprint-compiler。`Resource.exists` 在含 `.git` 的目录里告警并忽略这些文件。lib-vt 包不带它们，并按 `src/build/GhosttyDist.zig::lib_vt_excludes` 排除路径（见 `libghostty-vt.md`）。
- 生成 GTK 资源需要 blueprint-compiler 与 libadwaita 开发文件，完整 `dist` 只能在装好 GTK 构建依赖的 Linux（或上游 Nix devShell）上做；lib-vt 包没有这个要求。
- `distcheck`：`tar xvzf` 把包解到 Zig 缓存，在解包目录运行 `zig build test`；lib-vt 模式改跑 `zig build test-lib-vt -Demit-lib-vt=true`，再用 `cmake -B`、`cmake --build` 验证 CMake 包装；`addCheckFile` 确认预生成资源在包内的位置。内层命令按名字从 PATH 找 `zig`、`tar`、`cmake`，与外层共享 Zig 缓存（非密封），也不继承外层的 `-Dversion-string`。

### 安装资源（`src/build/GhosttyResources.zig::init`）

- 只在产出 app exe（`app-runtime` 不为 `none`）或 macOS xcframework/app 构建时安装：`tic` 编译的 terminfo 数据库，以及受 `-Demit-terminfo`、`-Demit-termcap` 控制的源文件与 termcap（Windows 只装源文件，FreeBSD 用 `site-terminfo`）、`share/ghostty/shell-integration`、`share/ghostty/themes`（`iterm2_themes` 依赖，受 `-Demit-themes` 控制）、fish/zsh/bash 补全、vim 与 neovim 插件、bat 用的 sublime 语法；后几类由 `src/main_build_data.zig::Action` 生成。
- Linux 另由 `src/build/GhosttyResources.zig::addLinuxAppResources` 安装 desktop、D-Bus service、systemd user unit、AppStream metainfo、Dolphin 与 Nautilus 扩展，以及取自 `images/gnome/` 的 hicolor 图标。应用 ID：ReleaseFast/ReleaseSmall 为 `com.mitchellh.ghostty`，Debug/ReleaseSafe 加 `-debug`。`dist/linux/*.in` 是 CMake 风格模板（`@NAME@`、`@APPID@`、`@GHOSTTY@`），经 `addConfigHeader` 展开、`tail -n +2` 去掉首行。
- `-Dflatpak` 改用 `dbus.service.flatpak.in`，省略 systemd unit 与 1024 像素图标；systemd unit 在系统包模式装到 `lib/`，否则 `share/`。

### 下游渠道（上游维护，fork 原样保留）

- `PACKAGING.md`：打包者以源码包为输入，唯一联网步骤是 `nix/build-support/fetch-zig-cache.sh`（按 `build.zig.zon.txt` 逐个 `zig fetch`），之后用 `DESTDIR=… zig build --prefix /usr --system <缓存>/p -Doptimize=ReleaseFast -Dcpu=baseline` 离线构建。它的「Zig Version」一节已过时（指向 `build.zig` 中已不存在的 `required_zig` 常量，并写着 Zig 0.14.0），真源见 `build-system.md`。另据归档的上游 `test.yml` 的 System Build 注释，Zig 0.16 起全局缓存只存压缩包，`--system` 要指向解包后的 `zig-pkg/` 式目录，`<缓存>/p` 的写法早于这一变化（本机未验证）。
- Flatpak：`flatpak/com.mitchellh.ghostty.yml`（ReleaseFast）与 `com.mitchellh.ghostty-debug.yml`（Debug）以仓库目录为源，用 `-Dflatpak=true --system $PWD/vendor/p` 构建，依赖源取自生成的 `flatpak/zig-packages.json`；`flatpak/dependencies.yml` 用 sha256 钉住 Zig 0.16.0 官方包。
- Snap：`snap/snapcraft.yaml` 从 ziglang.org 下载 Zig 0.16.0（不校验摘要），用 `craftctl set version=$(cat VERSION)` 取版本，所以输入必须是源码包；`-Dsnap -Doptimize=ReleaseFast -Dcpu=baseline`，classic confinement，启动器 `snap/local/launcher`。
- Nix：`nix/package.nix` 以 `build.zig.zon.nix` 为离线依赖，传硬编码的 `-Dversion-string=1.3.2-dev+<rev>-nix` 与 `-Dcpu=baseline`，只声明 Linux 平台。
- 其余：`dist/macos/update_appcast_*.py` 属上游 Sparkle appcast 流程；fork 的 exe 编入 `dist/windows/gx/ghostty-gx.rc`（GX-0026），不用上游 `dist/windows/ghostty.rc` 与其图标，manifest 仍取上游。图标：`images/gnome/` 供 Linux 安装、GTK gresource 与 `Doxyfile`，`images/icons/icon_512.png` 供 snap，`images/Ghostty.icon` 由 Xcode 工程引用。

### fork 发布资产（`gx-release`）

| 资产 | 产出 job | 说明 |
|---|---|---|
| `libghostty-vt-$VS.tar.gz` | `source`：`zig build distcheck -Demit-lib-vt=true` | lib-vt 源码包，≤5 MiB |
| `libghostty-vt-$VS-<target>.tar.gz` | `libvt` | `x86_64-linux-gnu`、`aarch64-linux-gnu`、`x86_64-linux-musl`、`wasm32-freestanding`，在 ubuntu 交叉编译 |
| `libghostty-vt-$VS-x86_64-windows-msvc.zip` | `libvt` | windows-2025 原生构建 |
| `ghostty-$VS.tar.gz` | `linux-gtk`：`zig build dist` | 完整源码包，含预生成资源 |
| `ghostty-gx-$VS-x86_64-linux-debian13.tar.gz` | `linux-gtk` | 在 debian:13 解包上一行并以 `--prefix /usr` 构建；`+version` 必须等于 `$VS` |
| `ghostty-gx-$VS-x86_64-windows.zip`、`ghostty-gx-$VS-x86_64-windows-setup.exe` | `windows-app` | win32 app 的 ReleaseFast 便携包与 Inno Setup 安装包，见下文 |
| `libghostty-vt-$VS-xcframework.zip`、`ghostty-gx-$VS-universal-macos-unsigned.zip` | `libvt-macos`、`macos` | 仅 `macos=true`；未签名、未公证 |
| `SHA256SUMS`、`manifest.json` | `verify` | 资产集合、包内布局与摘要 |

资产名、包内必需文件与源码包内的 `VERSION` 由 `scripts/gx_release.py::expected_assets` 定义，`scripts/test_gx_release.py` 锁定。

### Windows 便携包与安装包（`scripts/gx_windows_package.py`）

- `just package-windows`（`--build`）先把 ReleaseFast 的 win32 app 装进前缀（`-Dtarget=x86_64-windows-gnu`、`-Dversion-string=$VS`），再在 `zig-out/dist/` 产出 `ghostty-gx-$VS-x86_64-windows.zip`（单一顶层目录：`ghostty.exe`、随包 ConPTY 的 `conpty.dll` 与 `OpenConsole.exe`、软件渲染 `mesa/`、`share/`、`fonts/`、`licenses/`、中英文 `README.txt`）与 Inno Setup 7.1 安装包；`--skip-installer` 只出 zip。
- 第三方输入（ConPTY 1.24.261001001、Mesa llvmpipe、JetBrainsMono Nerd Font 6 款与 Noto Sans CJK 2 款、许可证文本）在模块文档里钉 SHA-256，下载到缓存（默认 `.local/cache/gx-package`，`--offline` 不联网），任一不符即失败。ISCC 依次取 `--iscc`、`$ISCC`、`.local/tools/innosetup/ISCC.exe`（`just setup --innosetup`）与 `PATH`。报告成功前两个产物都按 `expected_assets` 核对。
- 安装包（`dist/windows/gx/ghostty-gx.iss`）：欢迎页（`DisableWelcomePage=no`）与「应用和功能」的 `AppComments` 写明非官方分支声明；默认按用户装到 `%LOCALAPPDATA%\Programs\Ghostty GX`，也可为所有用户安装；开始菜单、可选桌面图标、App Paths、可选的资源管理器右键菜单；字体按用户安装，已存在就跳过，卸载时保留；卸载不删用户配置。`just stage windows <新目录>` 用同一棵树生成 GX Shell 的 Windows stage。

### Ghostty GX 图标（`scripts/gx_icon.py`）

- Ghostty 维护者要求非官方构建不用 Ghostty 品牌，Windows 产物因此用 `dist/windows/gx/ghostty-gx.ico`（16～256 像素）：只用标准库的 `python scripts/gx_icon.py` 生成，`--check` 逐像素比对，`--png <目录>` 导出供审阅；改图案改生成器，不手改 ico。
- 使用者：exe 资源、安装包的 `SetupIconFile`（`scripts/gx_windows_package.py::ICON`）与 Windows stage 的 `build-inputs/ghostty.ico`（GX Shell 安装包图标，stage 契约不变）。
- Linux 保持上游图标：GTK 窗口图标取应用 ID `com.mitchellh.ghostty`，只换 deb stage 启动器的图标会与窗口不一致，所以 deb stage 仍取 `images/gnome/`。

### GX Shell 组件 stage（`scripts/gx_package.py`、`scripts/gx_linux_build.py`）

- `gx_package.py windows|deb --stage-dir DIR` 生成 schema 3 的 stage，`verify-stage` 复核，`test-deb` 把 deb stage 打成一次性测试包。契约（`stage-manifest.json` 的键与布局、GX Shell 的消费方命令、所需工具与网络）只写在该模块文档里，由 `scripts/test_gx_package.py` 与 `scripts/test_gx_workflows.py` 锁定。`--build` 先构建：windows 为 win32 ReleaseFast（`-Dtarget=x86_64-windows-gnu`），deb 调 `gx_linux_build.py build`。
- `gx_linux_build.py` 是 Ubuntu 24.04 配方：按清单检查或安装 apt 依赖，要求 patchelf 0.18.0，用钉版 Zig 与 sha256 钉版的 blueprint-compiler 0.16.0，或改从 dist 源码包构建（自带预生成资源）；ReleaseFast、`-fno-sys=gtk4-layer-shell`，`-Dpatch-rpath='$ORIGIN/../lib'` 让随包的 `libgtk4-layer-shell.so` 不靠 `LD_LIBRARY_PATH` 加载，`check-prefix` 在不设它时跑 `+version`。
- `gx-release` 的 `linux-gtk-noble` 在 `ubuntu:24.04` 容器跑模块文档里的 deb 命令，只上传证据 artifact `evidence-linux-gtk-noble`，不产出发布资产。

## 不变量

- 源码包是下游打包与 fork 发布共同的输入：要进包的改动必须先提交；预生成资源只由 `dist` 生成，永不提交到 Git。
- 从源码包构建时 `VERSION` 只提供 `X.Y.Z` 基线，探测不到 git 时版本退化为 `X.Y.Z-dev+0000000`。所有发布构建都必须显式传 `-Dversion-string=$VS`，app 用 `+version` 核对；lib-vt 库内报告的是 `lib_version`，不随 `$VS` 变化（见 `libghostty-vt.md`）。
- distcheck 内层构建在解包目录探测 git：本地缓存在仓库内时会读到外层仓库的分支与 tag（GX-0001 让 `gx-v*` tag 不再 panic），缓存在仓库外（如 CI 的 `$RUNNER_TEMP`）时得到 `dev` 版本。两者都不影响测试结论，内层版本号不作发布证据。
- lib-vt 源码包不超过 5 MiB；lib-vt 构建、`test-lib-vt` 与 CMake 包装用到的路径不能落进 `lib_vt_excludes`。
- 应用 ID、`src/build_config.zig::bundle_id`、desktop 文件名、D-Bus 名与图标名在 fork 中保持上游值：它们分散在多处，只改一处会让 D-Bus 激活、portal 与图标失配。fork 资产靠文件名中的 `gx` 区分。
- Linux 集成沿用上游约束：systemd unit 名必须以 `app-` 开头（xdg-desktop-portal 据此识别应用），Nautilus 扩展必须名为 `ghostty.py`，Flatpak 图标不超过 512 像素。
- fork 资产没有上游 minisign 签名（签名密钥是上游 secrets），完整性靠 `SHA256SUMS`、`manifest.json` 与 GitHub 资产 digest。fork 的 release 是正式版（不是 prerelease，自 0.0.1 起），以名称 `Ghostty GX X.Y.Z` 与资产名里的 `gx` 区别于上游，不冒充上游发布。
- 安装包的 `AppId` 是升级与卸载认的身份，不得改动；Windows 包里的 ConPTY、Mesa 与字体只取钉住摘要的版本，升级时同步改钉版、许可证与 `expected_assets`。
- debian13 的 GTK app 包动态链接 Debian 13 的 GTK4 与 libadwaita，只承诺在同代发行版运行。Flatpak、Snap、Nix 渠道由上游维护，fork 不向 Flathub、Snap Store 或 cachix 发布。
- GX Shell stage 里唯一的符号链接是 `root/usr/bin/ghostty-gx`：前缀 `share/` 内指向自身树的链接（tic 的 `terminfo/g/ghostty`）复制成文件，别的链接一律拒绝；`root/usr/lib/ghostty-gx/lib/` 恰好是二进制实际加载的库，RUNPATH 只能是 `$ORIGIN/../lib`。键集、布局或消费方命令有变就升 schema，并告知 GX Shell 的 release.yml 一起改。

## 禁止项

- 不提交 `zig-out/dist/` 下的 tarball 或任何 dist 预生成资源；不手改 `flatpak/zig-packages.json`。
- 发布构建不省略 `-Dversion-string`；不手工改资产名，不绕过 `verify` 补传资产。
- 不改应用 ID、bundle ID、`dist/linux` 模板里的标识或 `images/` 下的图标；不为 fork 重新启用归档的 flatpak、snap 与 release workflow。
- 不在 fork 资产或文档中引用上游 minisign 公钥声称已签名，不把 fork 资产说成上游官方发布；不用「Ghostty for Windows」「Windows 版 Ghostty」这类暗示 Ghostty 团队出品或认可的说法，写作「基于 Ghostty 的非官方分支 Ghostty GX」。
- 不为适配 fork 改 `PACKAGING.md`、`flatpak/`、`snap/`、`nix/package.nix` 等上游打包文件；发现过时内容（如 `PACKAGING.md` 的 Zig 版本）写进交付说明，留待上游修正。

## 验证

- 改 `GhosttyDist.zig` 或 lib-vt 包含范围：`just dist-vt`，确认 `zig-out/dist/libghostty-vt-<版本>.tar.gz` 生成且不超过 5 MiB；再 `just zig build distcheck -Demit-lib-vt=true`（PATH 上要有 0.16.x 的 `zig`、`tar`、`cmake`，缺则记 PENDING）。
- 改完整源码包或 GTK 资源：在装好 GTK 构建依赖的 Linux 上跑 `zig build distcheck`（上游形态 `nix develop -c zig build distcheck`）；本机 Windows 记 PENDING，交 `gx-release` 以 `publish=false` 运行的 `linux-gtk` job 验收。
- 改 `GhosttyResources.zig` 或 `dist/linux/`：Linux 上 `just build` 后检查 `zig-out/share/` 的安装布局；GUI 可见的影响按 `testing.md` 走 `gtk-smoke`。
- 改资产命名或集合：`just framework-test`（含 `scripts/test_gx_release.py`），再以 `publish=false` 运行 `gx-release` 看 `verify`，未运行前记 PENDING。
- 改图标：`python scripts/run_unittests.py test_gx_icon`，`--png` 导出读图，再构建并截图任务栏。
- 改 Windows 打包或 `dist/windows/gx/`：`python scripts/run_unittests.py test_gx_package test_gx_release`，再 `just package-windows`（先 `just setup --innosetup`；首次要下载钉版输入）；解压的 zip 与装到临时目录的安装包各按 `apprt-win32.md` 启动并截图读图。CI 证据是 `gx-release`（`publish=false`）的 `gx-windows-app` artifact。
- 改 GX Shell stage 或 Ubuntu 配方：`python scripts/run_unittests.py test_gx_package test_gx_linux_build`（Windows 未开开发者模式时 deb stage 用例跳过，在 WSL 克隆里用 `python3` 补跑）；真实验收在全新 `ubuntu:24.04` 容器按模块文档的 deb 命令构建、`verify-stage`，再在另一个全新容器装 `test-deb` 的包并截图读图；CI 证据是 `gx-release`（`publish=false`）的 `evidence-linux-gtk-noble`，读回截图前记 PENDING。
- 改 `flatpak/`、`snap/`、`nix/package.nix`（仅随上游同步）：Nix 主机上 `nix build .#ghostty-releasefast`（上游 `build-nix` 形态）；Flatpak 与 Snap 需要 Linux 上的 `flatpak-builder` 与 `snapcraft`，本机记 PENDING。
