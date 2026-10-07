# macos-app：macOS Swift 应用、GhosttyKit 与 Darwin 专用代码

## 范围

- `macos/**`：Swift/AppKit/SwiftUI 源码 `Sources/`、单元测试 `Tests/`、UI 测试 `GhosttyUITests/`、`Ghostty.xcodeproj`、`Ghostty.xctestplan`、AppleScript 定义 `Ghostty.sdef`、Info.plist 与 entitlements、`build.nu`、`macos/.swiftlint.yml`，以及上游指令 `macos/AGENTS.md`。
- 核心侧边界 `include/ghostty.h`、`include/module.modulemap`、`src/apprt/embedded.zig`；构建 `src/build/GhosttyXCFramework.zig`、`src/build/GhosttyXcodebuild.zig`。
- Darwin 专用代码 `src/os/macos.zig`、`src/os/cf_release_thread.zig`、`src/input/KeymapDarwin.zig`，绑定 `pkg/macos/**`、`pkg/apple-sdk/**`；另有上游 Sparkle appcast 脚本 `dist/macos/**` 与根 `.swiftlint.yml`。
- 并集：C ABI 细则归 libghostty-embedding，构建与 `pkg/**` 归 build-system，`src/os/**` 归 termio-pty-os，`src/input/**` 归 input，`dist/**` 归 packaging-dist，`.swiftlint.yml` 归 ci-release；本文只写 macOS 专属约束。

## 符号真源

### 构建链

- macOS 上 `-Dapp-runtime` 默认是 `none`（`src/apprt/runtime.zig::Runtime.default`）：`zig build` 不产出可执行文件，产出的是 libghostty-internal。`src/build/GhosttyXCFramework.zig::init` 把它打成 `macos/GhosttyKit.xcframework`（默认 universal，`-Dxcframework-target=native` 只编本机架构；该目录被 `macos/.gitignore` 忽略）。头目录只放 `ghostty.h` 与 `module.modulemap`，不带 `include/ghostty/`，以免 Clang 报 umbrella header 告警。
- `src/build/Config.zig::init`：在 macOS 宿主上构建 macOS 目标时，`emit-xcframework` 默认开启，`emit-macos-app` 默认随之开启；`-Demit-macos-app=false` 只构建库与 `zig-out/share` 资源。
- `src/build/GhosttyXcodebuild.zig::init`：以只保留 `PATH` 的环境调 `xcodebuild -target Ghostty`，Zig 的 `Debug` 对应 Xcode `Debug`，其余优化级别对应 `ReleaseLocal`。`run` 步骤强制 native xcframework，并设 `GHOSTTY_LOG=stderr,macos`、`GHOSTTY_MAC_LAUNCH_SOURCE=zig_run`。未给 `-Dtest-filter` 时，`zig build test` 还会挂上 `xcodebuild test`（跳过 `GhosttyUITests`）。
- `macos/build.nu` 用 `env -i`（只留 `HOME` 与系统 `PATH`）调 `xcodebuild -scheme`，以避开 Nix 环境变量；产物在 `macos/build/<configuration>/Ghostty.app`。
- Xcode 工程以文件夹引用把 `../zig-out/share/` 下的 `ghostty`、`locale`、`man`、`terminfo` 与各 shell、编辑器集成目录打进 app bundle。`build.zig` 在 emit-xcframework 时总会安装 resources 与 i18n，`src/build/GhosttyDocs.zig::installDummy` 保证 `share/man` 存在。

### Swift ↔ C 边界

- `include/module.modulemap` 把 `ghostty.h` 包成 Clang 模块 `GhosttyKit`，Swift 只经 `import GhosttyKit` 访问核心；`ghostty.h` 的文件头注明它是只供 macOS app 使用的 libghostty-internal。桥接头 `macos/Sources/App/ghostty-bridging-header.h` 只导入 app 自带的 ObjC 辅助（`ObjCExceptionCatcher.h`、`VibrantLayer.h`）。
- 启动顺序见 `macos/Sources/App/main.swift`：`ghostty_init` → `ghostty_cli_try_action`（`+action` 形式的 CLI 在此执行并退出）→ `NSApplicationMain`。
- `macos/Sources/Ghostty/Ghostty.App.swift::App` 以 `ghostty_runtime_config_s` 注册回调后调 `ghostty_app_new`。`App.wakeup` 可能来自任意线程，只用 `DispatchQueue.main.async` 调度 `ghostty_app_tick`；`App.action` 按 `ghostty_action_tag_e` 分派，Zig 侧 `src/apprt/action.zig::Action.Key` 注明与之同步。
- `macos/Sources/Ghostty/Ghostty.Config.swift::Config` 按字符串 key 调 `ghostty_config_get` 读配置。
- `src/apprt/embedded.zig` 提供 `App.Options`（C 名 `ghostty_runtime_config_s`）、`Platform`（macOS 传 `nsview`，iOS 传 `uiview`）与 `CAPI`；导出流程与头文件规则见 `libghostty-embedding.md`。

### Darwin 专用 Zig 与绑定

- `src/os/macos.zig`：`isAtLeastVersion`、`appSupportDir`/`cacheDir`（系统目录下的 `<bundle_id>/…`）、`setQosClass`、`pthread_setname_np`。
- `src/os/cf_release_thread.zig`：独立的 xev 线程批量执行 `CFRelease`，让 CoreText shaper（`src/font/shaper/coretext.zig`）的释放回调不阻塞热路径。`Mailbox` 是定容 `BlockingQueue`，生产者 push 后须 `wakeup.notify()`；线程异常退出后进入 drain 模式。
- `src/input/KeymapDarwin.zig`：只在 macOS 由 `src/input.zig::Keymap` 选用。embedded apprt 惰性初始化它，经 `src/apprt/embedded.zig::App.keyboardLayout` 调 `sourceId` 识别当前键盘布局；Swift 收到布局变化通知后调 `ghostty_app_keyboard_changed`，触发 `App.reloadKeymap`。它的 `translate`（TIS input source 与 `UCKeyTranslate`）目前没有调用方，按键文本由 Swift 随 `ghostty_surface_key` 传入。
- `pkg/macos`：CoreFoundation、CoreGraphics、CoreText、CoreVideo、QuartzCore、IOSurface（macOS 目标另加 Carbon），以及 dispatch、`os/log`、`os/signpost` 的 translate-c 绑定与 Zig 包装，模块名 `macos`。
- `pkg/apple-sdk`：
  - `pkg/apple-sdk/build.zig::pathsForTarget` 与 `addPaths` 在 Darwin 宿主上经 xcrun（`std.zig.LibCInstallation.findNative`）定位 SDK；在非 Darwin 宿主交叉编译到 macOS 时，退回 Zig 自带的 Darwin 头文件（只够 libc，不含系统框架）。
  - `pkg/apple-sdk/include/math.h` 是 Xcode 27 SDK 与 Zig 0.16 自带 Clang 头不兼容时的临时垫片，移除条件写在 `pathsForTarget` 的注释里。
  - `addPaths` 定义 `_LIBCPP_HAS_VENDOR_AVAILABILITY_ANNOTATIONS`，防止旧版 macOS 启动时 dyld 因缺符号而中止；`pkg/apple-sdk/native_link.zig` 构造调用 Apple 原生链接器的命令。

### 工程、更新与 lint

- Xcode 工程：targets 为 `Ghostty`、`GhosttyTests`、`GhosttyUITests`、`DockTilePlugin`；配置为 `Debug`、`Release`、`ReleaseLocal`，App 在三者中都用 ad-hoc 签名（`CODE_SIGN_IDENTITY` 为 `-`），各配一份 entitlements。App 的 bundle id 在 `Debug` 下为 `com.mitchellh.ghostty.debug`，其余为 `com.mitchellh.ghostty`。Sparkle 以 SPM 远程包引入。App target 的 `MACOSX_DEPLOYMENT_TARGET` 与 `src/build/Config.zig::osVersionMin` 的 macOS 下限当前都是 13.0。
- 自动更新：`macos/Sources/Features/Update/UpdateDelegate.swift::feedURLString` 按 `auto-update-channel` 指向上游 appcast（`tip.files.ghostty.org` 或 `release.files.ghostty.org`），`Ghostty-Info.plist` 带上游的 `SUPublicEDKey`。`dist/macos/update_appcast_{tag,tip}.py` 是上游签名发版流程生成 appcast 的脚本，由已归档的 `release-tag.yml`、`release-tip.yml` 调用。
- Lint：根 `.swiftlint.yml` 只有 `included: macos`，并以 `macos/.swiftlint.yml` 为 child config（排除 `build`，关闭若干规则）。

## 不变量

- **唯一边界**：Swift 只经 `GhosttyKit` 访问核心。桥接头只放 app 自己的 ObjC 辅助，不得导入核心头文件或 `include/ghostty/` 来绕过模块。
- **契约同改**：改 `ghostty.h` 的函数签名、结构体或枚举时，同一提交内同时改 Zig 导出（`src/apprt/embedded.zig::CAPI`、`src/main_c.zig` 或 `src/config/CApi.zig`）与全部 Swift 调用方；`ghostty_action_tag_e` 与 `Action.Key` 必须逐项对应。Swift 用字符串 key 读配置，错配在编译期发现不了，所以重命名配置字段或改其类型时，要 grep `macos/Sources` 一并修改。
- **主线程**：调用 `ghostty_*` 与操作 AppKit/SwiftUI 都在主线程（main actor）上；核心回调需要动 UI 时先切回主线程。`macos/Sources/Ghostty/Ghostty.Surface.swift` 的 `Ghostty.Surface` 在非主线程 deinit 时改用 `Task.detached { @MainActor … }` 释放 surface，可作范式。
- **构建顺序**：改了 `macos/` 之外的代码，要先重建底层库再构建 app（命令见 `macos/AGENTS.md`）。xcframework 与 `zig-out/share` 必须出自同一次 Zig 构建，否则打进 app 的资源与库不一致。
- **共享标识**：`src/build_config.zig::bundle_id` 的注释要求它与 App 的 bundle id 一致，它还决定 `appSupportDir`/`cacheDir` 的路径与 gettext domain，fork 不改名。部署目标的两处（Xcode 与 `osVersionMin`）要同步调整。
- **本地化现状**：Swift 源码里没有 `NSLocalizedString`，也不调 `ghostty_translate`；`po/README_CONTRIBUTORS.md` 声明 macOS 尚未实现本地化。Xcode 工程虽然打包了 `zig-out/share/locale`，核心也刻意不给 embedded 运行时翻译：`src/config/Config.zig::RepeatableCommand.init` 只在 `app_runtime == .gtk` 时翻译默认命令面板条目，以免未本地化的 UI 里出现本地化的命令面板。i18n 规则见 `apprt-gtk.md`。
- **fork 的更新渠道**：fork 发布的版本串带预发布段（如 `1.3.2-gx.0.1.0`），`src/build/Config.zig::addOptions` 因此把 `release_channel` 设为 `tip`。fork 构建的 app 若检查更新，查询的是上游 tip appcast，校验用的也是上游公钥。

## 禁止项

- 不用 `zig build` 构建或运行 app 来代替 `macos/build.nu`；`zig build` 只用来重建底层库（`macos/AGENTS.md`）。
- 不手改、不提交 `macos/GhosttyKit.xcframework`、`macos/build/` 与 `zig-out/` 下的产物。
- 不在 Swift 中绕过 `GhosttyKit` 直接声明或链接核心符号，不在非主线程调 `ghostty_*`。
- fork 不做正式签名与公证，也不发布 Sparkle appcast：不把 `dist/macos/*.py` 接进 `gx-release`，不替换 `SUPublicEDKey`、feed URL 或 bundle id。确需修改时按上游补丁流程，加 `fork(gx): GX-NNNN` 标记并登记 `docs/FORK_PATCHES.md`。
- 不打乱 `Ghostty.sdef` 的顶层定义顺序（规则在 `macos/AGENTS.md`）。

## 上游指令

`macos/AGENTS.md` 是本域的上游指令。resolver 对 `macos/**` 路径会输出它，动手前必须读并按原文执行，此处不复制。它规定了 swiftlint、核心改动后重建底层库、`macos/build.nu` 的用法与产物位置、单元测试命令，以及 AppleScript 相关要求（`Ghostty.sdef` 顶层顺序、`macos-applescript` 配置守卫、osascript 测试步骤）。

## 验证

- **本机 Windows**：没有 Xcode、macOS SDK、Metal Toolchain 与 nushell，库和 app 都构建不了，Swift 也无法 lint。macOS 验证项一律记 **PENDING**，不记 N/A。本机只跑 `just rules <改动路径>`，改了 Zig 再跑 `just fmt-check`。
- **macOS 机器**（Xcode 26 与 macOS 26 SDK，见 `HACKING.md`）：
  - 库：`just build -Demit-macos-app=false`，可加 `-Dxcframework-target=native` 提速。
  - App 与单测：`macos/build.nu`，`macos/build.nu --action test`。
  - Swift：在仓库根跑 `swiftlint lint --strict`；fork CI 不跑 swiftlint，没跑过就不得声称通过。
  - Darwin 专用 Zig：`just test --filter <name>`，例如 `src/os/macos.zig` 的 `cacheDir paths`（在非 Darwin 上不会真正执行）。`just test` 只跑 `ghostty-test`，不含上游 `zig build test` 不带 `-Dtest-filter` 时挂上的 `xcodebuild test`，app 单测仍用上一条的 `macos/build.nu --action test`。
  - AppleScript：按 `macos/AGENTS.md` 的 osascript 步骤。
- **CI**：手动触发 gx-ci 并打开 `macos` 输入，运行 `macos` job。它只跑 `zig build test-lib-vt`：证明 libghostty-vt 在 macOS 上能构建并通过单测，不构建 app，不代证签名、公证与交互。`gx-release` 只在输入 `macos=true` 时产出未签名的 app zip。job 定义以 `.github/workflows/gx-ci.yml`、`gx-release.yml` 为准，首跑之前一律 PENDING。
