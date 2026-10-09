# apprt-gtk：GTK 应用运行时、i18n 与 Linux 桌面集成

## 范围

- Linux/FreeBSD 默认的 GTK 运行时（`src/apprt/runtime.zig::Runtime.default`）：`src/apprt/gtk.zig` 与 `src/apprt/gtk/**`，含 `class/` 下的 GObject 类、`ui/<major>.<minor>/*.blp` Blueprint 模板、`css/`、`winproto/`（X11/Wayland）、`ipc/`（D-Bus）、portal、cgroup 与 Flatpak 辅助、`build/` 下的构建期小程序。
- i18n：`src/os/i18n.zig`、`src/os/i18n_locales.zig`、`src/build/GhosttyI18n.zig`、`po/**`，以及 Apple 平台捆绑的 `pkg/libintl/**`。
- 其余：`src/build/gtk.zig`、`pkg/gtk4-layer-shell/**`、`dist/linux/**`、`src/os/cgroup.zig`、`src/os/flatpak.zig`，检查脚本 `.github/scripts/check-translations.sh` 与 `nix/build-support/check-blueprints.sh`。
- 这些路径同时命中 app-core、build-system、packaging-dist、termio-pty-os、ci-release，通用规则以那些文档为准，本文只写 GTK 专属约束。

## 符号真源

本文中没写全的 `.zig` 路径（如 `class/…`、`build/…`、`winproto.zig`）都相对 `src/apprt/gtk/`；其它目录一律写全路径。

### 入口与主循环

- `src/apprt/gtk.zig` 导出 apprt 必需的 `App`、`Surface`、`resourcesDir`（即 `src/apprt/gtk/flatpak.zig::resourcesDir`），另导出 `class`、`WeakRef`、`pre_exec`、`post_fork`。`App.zig::App` 是外壳，工作委托给 `class/application.zig::Application`（GObject 名 `GhosttyApplication`，父类 `adw.Application`）；`Surface.zig` 同样转发给 `class/surface.zig::Surface`。
- `Application.new` 的顺序：加载配置（失败用默认配置并记诊断）→ 按 `language` 配置改写 `LANG` 并保存原值 → `i18n.initGlobalDomain` → `setGtkEnv` → `adw.init` → 选 app id（合法的 `class` 配置优先，否则 `build/info.zig::application_id`）→ `winproto.App.init`（失败退回 `none`）。
- `Application.run` 取代 `gio.Application.run`：注册、按 `initial-window` 决定是否 activate、非主实例直接返回、`systemd.notify.ready()`，然后循环执行 `glib.MainContext.iteration` 与 `core_app.tick`。`Application.wakeup` 只调 `glib.MainContext.wakeup(null)`。

### GObject、Blueprint 与资源

- `class.zig::Common`：`as`（编译期保证安全的上转）、`ref`/`unref`、`private`、私有字段属性访问器、`Class.bindTemplateChildPrivate`、`Class.bindTemplateCallback`。另有 `weak_ref.zig::WeakRef` 与 `ext/actions.zig`（action 名在编译期校验）。
- `build/gresource.zig::blueprints` 是 UI 模板登记表，目录名即模板要求的最低 libadwaita 版本；`build/gresource.zig::blueprint` 在编译期把登记项映射为资源路径，未登记即 `@compileError`。同文件登记 `css` 与 `icon_sizes`（取自 `images/gnome/`）。
- `build/blueprint.zig` 构建期检查 libadwaita 头文件版本，以及 `blueprint-compiler` 不低于 `required_blueprint_version`（当前 0.16.0）。
- `src/build/SharedDeps.zig::gtkNgDistResources` 逐个 `blueprint-compiler compile`，再用 `glib-compile-resources` 生成 `ghostty_resources.{c,h}`。源码包内它们是预生成的 dist 资源（`src/build/GhosttyDist.zig::Resource`），Git 检出里出现会被忽略并告警。
- `build/info.zig`：`application_id` 在 Debug/ReleaseSafe 下追加 `-debug`，另有 `resource_path`、`object_path`。
- 版本门 `adw_version.zig`、`gtk_version.zig`：`atLeast` 同查编译期头文件与运行期库，用于影响代码生成的分支；`runtimeAtLeast` 只查运行期，用于只影响行为的分支。

### 窗口系统与系统集成

- `winproto.zig::App`、`winproto.zig::Window` 是 `none`/`wayland`/`x11` 的 tagged union，后端是否编入取决于 `build_options.wayland`/`x11`；`-Dgtk-x11`、`-Dgtk-wayland` 默认值来自 `src/build/gtk.zig::targets`（pkg-config 失败时全为 false，保证无 GTK 也能 `zig build --help`）。Wayland 协议在 `src/build/SharedDeps.zig::addGtkNg` 注册，含仓内 `winproto/wayland/protocols/vicinae-hotkey-v1.xml`。
- quick terminal 依赖 gtk4-layer-shell：`src/build/Config.zig::init` 把它的系统集成默认设为 true（链接系统 `gtk4-layer-shell-0`），`-fno-sys=gtk4-layer-shell` 时构建并安装 `pkg/gtk4-layer-shell` 的动态库。
- `ipc/*.zig` 经 D-Bus `org.gtk.Actions.Activate` 调用运行中实例的 app action，action 在 `Application.startupActionMap` 注册（`new-window`、`new-tab`、`toggle-quick-terminal` 等）。
- cgroup：`src/apprt/gtk/cgroup.zig::createScope` 经 systemd `StartTransientUnit` 建 scope；父进程侧 `post_fork.zig::postFork`，子进程侧 `pre_exec.zig::preExec`（最多等 250ms，hard-fail 以 127 退出），二者由 `src/termio/Exec.zig` 经 `@hasDecl(apprt.runtime, …)` 探测后挂到 `src/Command.zig` 的 `rt_post_fork`/`rt_pre_exec`；`src/os/cgroup.zig::current` 读 `/proc/<pid>/cgroup`。
- Flatpak：`src/os/flatpak.zig::isFlatpak` 运行期检测 `/.flatpak-info`，`FlatpakHostCommand` 经 `org.freedesktop.Flatpak.Development` 在宿主执行命令；只有 `-Dflatpak` 构建链接 `gio_c`。
- `dist/linux/*.in` 是 cmake 风格模板（`@NAME@`、`@APPID@`、`@GHOSTTY@`），由 `src/build/GhosttyResources.zig::addLinuxAppResources` 渲染安装 desktop entry、D-Bus service（Flatpak 用 `dbus.service.flatpak.in`）、systemd user service（仅非 Flatpak）与 AppStream metainfo，另装 Dolphin/Nautilus 右键菜单与图标。

### i18n

- `src/os/i18n.zig`：`init` 由 `src/global.zig` 以资源目录调用，把 gettext domain 绑到资源目录同级的 `locale/`（Windows 直接返回）；`initGlobalDomain` 只给完整拥有应用的 apprt 用；`_` 在 comptime 调用时原样返回 msgid，`N_` 只做标记；`canonicalizeLocale` 依赖 `pkg/libintl` 导出的 `_libintl_locale_name_canonicalize`。
- `src/os/i18n_locales.zig::locales`：受支持的 locale 列表，顺序有语义（只知语言码时取第一个匹配）；单独成文件是为减少构建程序的传递依赖。
- `src/build/GhosttyI18n.zig`：`init` 对每个 locale 跑 `msgfmt`，装到 `share/locale/<locale>/LC_MESSAGES/com.mitchellh.ghostty.mo`。`createUpdateStep` 用 `xgettext --language=C --keyword=_ --keyword=N_ --keyword=C_:1c,2` 扫描已登记的 `.blp`、`src/apprt/gtk` 下全部 `.zig`（排序后）与 `src/input/command.zig`，再以 Python 模式扫 `dist/linux/ghostty_nautilus.py`，合并写回 `po/com.mitchellh.ghostty.pot`，并对每个 locale `msgmerge --no-fuzzy-matching`。`build.zig` 把它挂在 `update-translations` 步骤，i18n 关闭时该步骤报错。
- `-Di18n` 默认（`src/build/Config.zig::init`）：macOS/iOS 开；Linux/FreeBSD 只在 glibc 开；其余关。musl 要开需 gettext-tiny 一类 stub（`po/README_CONTRIBUTORS.md`），`src/os/i18n.zig` 手写 gettext extern 声明也是因为 musl 未必有 `libintl.h`。`language` 配置项只对 GTK 生效，且不能运行时重载。
- `pkg/libintl` 用 GNU gettext 源码构建静态 libintl，只在 Darwin 目标由 `src/build/SharedDeps.zig` 链接；它的 `config.h` 在 macOS 上手工生成，升级 gettext 时要复核末尾手工补的 `xlocale.h` include。

## 不变量

- **主线程**：GTK、GLib、libadwaita 对象只在 `Application.run` 所在的主线程上操作，私有状态 `running` 只由主循环写。termio、渲染线程不调 GTK，只向核心 mailbox 投递；`src/App.zig` 投递后调 `rt_app.wakeup()`，主循环在下一次 `core_app.tick` 处理。
- **渲染交接**：`class/render_surface.zig::RenderSurface` 在主线程的 `snapshot` 里用 `renderer.takeFrame()` 取渲染线程导出的最新帧建 `GdkTexture`；渲染初始化在渲染线程完成后才创建 core surface。帧优先以 DMABUF 导出，导入失败时调 `reportPresentationHealth(.unhealthy)`，渲染器改发 CPU 内存帧。终端 surface 不用 `GtkGLArea`（只有 inspector 的 `class/imgui_widget.zig` 在用）。
- **GObject 生命周期**：使用模板的类在 `dispose` 里先 `gtk.Widget.disposeTemplate` 再链式调父类；属性访问器持有的私有字符串、boxed、对象在 `finalize` 释放（访问器只在 set 时替换旧值）；`WeakRef` 在宿主 `dispose` 中 `deinit`，`WeakRef.get` 返回的强引用用完要 `unref`；模板回调返回 `c_int` 而不是 Zig `bool`（`bindTemplateCallback` 编译期拒绝 `bool`）。
- **Blueprint 登记**：每个 `.blp` 都登记在 `gresource.blueprints`，未登记的既不进 gresource 也不被 xgettext 扫描。构建要求 libadwaita 头文件不低于登记表最高版本，新增更高版本目录会抬高整个 GTK 构建的下限；多版本变体（如 `clipboard-confirmation-dialog`、`debug-warning`）在 `Class.init` 用 comptime 版本门挑选。
- **可翻译字符串**：Zig 里立即翻译用 `i18n._("…")`，先存 msgid、展示时再翻译用 `i18n.N_("…")`；带上下文的 `C_("ctx", "…")` 只能写在 `.blp`（`src/os/i18n.zig` 没有 `C_`）。只有 `createUpdateStep` 列出的输入会被抽取，在其外新增可翻译字面量时必须把文件加进该步骤。命令面板条目在 `src/input/command.zig` 用 `i18n.N_` 标记，由 `src/config/Config.zig::RepeatableCommand.init` 只在 `app_runtime == .gtk` 时翻译。
- **pot 与 po**：pot 只由 `update-translations` 生成，必须与源码同步；`.po` 归译者，update 只做 `msgmerge`。新增 locale 要同时提交 `po/<locale>.po` 与 `locales` 条目（构建按列表逐项读取 `.po`）；上游流程还要改 `CODEOWNERS`，fork 不编辑它（`ci-release.md`），新语种宜回馈上游。
- **环境变量**：`class/application.zig::setGtkEnv` 必须在 GTK 初始化前调用（有断言），改完调 `global.syncEnviron()`。`class/surface.zig::Surface.defaultTermioEnv` 从子进程环境剔除 `GDK_DEBUG`、`GDK_DISABLE`、`GSK_RENDERER` 与 desktop/D-Bus/systemd 启动器注入的变量，并把 `LANG` 恢复为启动时的值；新增 GUI 侧环境改动要同步这张清理表。
- **对外接口**：app id `com.mitchellh.ghostty` 同时用于 `build_config.bundle_id`、`build/info.zig`、gettext domain、`dist/linux` 安装文件名、D-Bus 名与 systemd `BusName`。app action 名被 desktop entry 的 `[Desktop Action new-window]` 与 `ipc/*.zig` 共同依赖。systemd 单元必须叫 `app-<appid>.service`，否则 XDG portal 认不出 app id；单元声明 `Type=notify-reload` 与 `ReloadSignal=SIGUSR2`，所以 `Application.startupSignals` 必须先于任何 systemd 通知注册 SIGUSR2。Nautilus 扩展安装名必须是 `ghostty.py`。
- **CSS 层次**：libadwaita 主题与 `css/style.css`（`APPLICATION`）< GX 样式（`src/apprt/gtk/gx/style.zig`，`APPLICATION + 2`）< 运行时 CSS（`APPLICATION + 3`）< `gtk-custom-css`（`USER`）。GX 样式与 herdr 应用模式（`src/apprt/gtk/gx/app_mode.zig`）经 fork 补丁 GX-0016 接入 `class/application.zig`、`class/window.zig`；新增 provider 按此排位，GX 逻辑放在 `src/apprt/gtk/gx/`，上游类里只留 begin/end 钩子。
- **门控与链接**：Flatpak 专用路径同时受编译期 `build_config.flatpak` 与运行期 `isFlatpak()` 门控。`preExec` 跑在 fork 后、exec 前的子进程里，只读 `/proc` 并有限等待，不碰 GTK/GLib 对象。gtk4-layer-shell 只能动态链接，且先于 `wayland-client` 链接（它 shim 了 libwayland）。

## 禁止项

- 不手改 `po/com.mitchellh.ghostty.pot`；无充分理由不改写他人已有的 `.po` 译文（`po/README_TRANSLATORS.md`）。
- 不提交 `src/apprt/gtk/ghostty_resources.{c,h}`、编译出的 `.ui` 与 `.mo`。
- 不在非主线程调 GTK/GLib UI API；不把终端渲染改回 `GtkGLArea`；不用 `gio.Application.run` 替换自定义主循环，不绕过 `core_app.tick`。
- 不在 embedded apprt（libghostty）路径调 `i18n.initGlobalDomain`。
- 不加未登记的 `.blp`，不用硬编码字符串引用 UI 资源绕过 `gresource.blueprint`。
- fork 不改 app id、D-Bus action 名、systemd 单元命名与 gtk4-layer-shell 的链接方式。确需改上游 GTK 源码时按补丁流程：加 `fork(gx): GX-NNNN` 标记并登记 `docs/FORK_PATCHES.md`。

## 上游指令

本域路径下没有嵌套 `AGENTS.md`。上游 i18n 说明以原文为准、此处不复制：贡献者看 `po/README_CONTRIBUTORS.md`，译者看 `po/README_TRANSLATORS.md`；从 Git 检出构建的额外依赖（`blueprint-compiler` 版本）看 `HACKING.md`。

## 验证

- **本机 Windows**：缺 GTK4、libadwaita、blueprint-compiler 与 gettext，且 Windows 默认 `-Di18n=false`（`update-translations` 直接报错）。GTK 的构建、单测、翻译与 Blueprint 检查一律记 **PENDING**，不记 N/A。本机只跑 `just rules <改动路径>` 与 `just fmt-check`（覆盖 GTK 的 Zig 源码）。
- **Linux 机器**（GTK4、libadwaita 头文件不低于登记表最高版本、blueprint-compiler ≥ 0.16、gettext、pkg-config）：
  - 构建 `just build -Dapp-runtime=gtk`，需要时加 `-Dgtk-x11=`、`-Dgtk-wayland=`；单测 `just test -Dapp-runtime=gtk --filter <name>`。
  - 翻译：`just zig build update-translations` 后审 `po/` diff，再跑 `.github/scripts/check-translations.sh`（脚本直接用 PATH 上的 `zig`，须为钉版 0.16.0）。
  - Blueprint：`nix/build-support/check-blueprints.sh` 后 `git diff --exit-code`（沿用上游 CI）。
  - 看译文：`zig-out/bin/ghostty --language=<locale>`。
- **CI**：gx-ci 的 push/PR 路径只跑 `-Dapp-runtime=none`，不编译 GTK。GTK 改动须手动触发 gx-ci 并打开 `gtk_smoke` 输入，由 `gtk-smoke` job 构建并截图；读过截图前 GUI 可见变更保持 PENDING。job 定义以 `.github/workflows/gx-ci.yml` 为准，各层证明范围见 `docs/TESTING.md`。
- **发版**：`gx-release` 的 `linux-gtk` job 从 `zig build dist` 源码包构建 GTK tarball（实验性），源码包自带 `ghostty_resources.{c,h}`，不需要 blueprint-compiler；见 `docs/RELEASE.md`。
