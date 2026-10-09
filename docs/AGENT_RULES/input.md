# input：键盘与鼠标输入、绑定与终端编码

## 范围

- `src/input.zig` 与 `src/input/**`；`src/surface_mouse.zig`（也属 `app-core`）。
- 五个编码文件 `src/input/key.zig`、`key_encode.zig`、`mouse.zig`、`mouse_encode.zig`、`paste.zig` 同属 `libghostty-vt`：`src/lib_vt.zig::input` 直接导出它们，`src/terminal/c/` 的 `key_event`、`key_encode`、`mouse_event`、`mouse_encode`、`paste`、`types` 包装它们。它们的传递导入 `key_mods.zig`、`config.zig`、`function_keys.zig`、`kitty.zig` 同样随 lib-vt 编译，也登记在 `libghostty-vt` 路由里；闭包里还有 `src/renderer/size.zig`（同样登记，见 `renderer.md`）与 `src/terminal/kitty/key.zig`（归 `terminal-core`）。改上面登记在 `libghostty-vt` 的文件时 resolver 会同时列出 `libghostty-vt.md`，两边规则都要满足；`kitty/key.zig` 只路由到 `terminal-core.md`，它的 lib-vt 约束见该文。
- `src/input/KeymapDarwin.zig` 同属 `macos-app`。
- fork 的两个输入模块（同属 `gx-core`）：`src/gx/action.zig`（`gx:` 绑定动作，补丁 GX-0014）与 `src/gx/win32_input.zig`（win32-input-mode 的 KEY_EVENT_RECORD 编码，补丁 GX-0006，apprt 接入契约写在文件头）。
- 调用方在 `app-core`：`src/Surface.zig` 的 `keyCallback`、`gxWin32KeyCallback`、`mouseButtonCallback`、`cursorPosCallback`、`scrollCallback`、`completeClipboardPaste`，以及 `src/App.zig::keyEvent`。平台事件到 `input.KeyEvent` 的翻译在 `src/apprt/gtk/`（`apprt-gtk`）、`src/apprt/win32/Surface.zig`（`apprt-win32`）与 `src/apprt/embedded.zig` 加 macOS 宿主（`libghostty-embedding`、`macos-app`）。

## 符号真源

- 事件：`src/input/key.zig::KeyEvent`（`action`、物理键 `key`、`mods`、`consumed_mods`、`composing`、`utf8`、`unshifted_codepoint`，方法 `effectiveMods`、`bindingHash`）；`Key` 是按 W3C UI Events `code` 命名、与布局无关的物理键；`Action` 为 release/press/repeat。`src/input/key_mods.zig::Mods` 含左右侧与锁定键，`binding()` 只保留 shift、ctrl、alt、super；`RemapSet` 实现 `key-remap` 配置。
- 键盘编码：`src/input/key_encode.zig::encode(writer, event, Options)`。`Options.kitty_flags` 非零走 Kitty 键盘协议，否则走 legacy：xterm PC 风格功能键表 `src/input/function_keys.zig`、modifyOtherKeys、DECBKM、`alt_esc_prefix`、macOS option-as-alt。`Options.fromTerminal` 从终端模式取值，`macos_option_as_alt` 由调用方另设。
- Kitty 协议：键码表 `src/input/kitty.zig::entries`（移植自 foot）；标志位与 8 层栈在 `src/terminal/kitty/key.zig::Flags`、`FlagStack`（`terminal-core`），由 `CSI > u`、`CSI < u`、`CSI = u` 经 `StreamHandler` 修改。
- 鼠标：`src/input/mouse.zig`（`Button`、`ButtonState`、`Action`、`ScrollMods`、`PressureStage`）；`src/input/mouse_encode.zig::encode(writer, Event, Options)` 支持 x10、utf8、sgr、urxvt、sgr_pixels 格式，`Options.fromTerminal(t, size)` 取模式与尺寸，`last_cell` 用来给 motion 去重。
- 粘贴：`src/input/paste.zig` 的 `encode`、`encodeWriter`、`isSafe`、`isSafeWith`、`Options.fromTerminal`（不安全字节替换为空格，2004 模式加括号帧，否则 `\n` 换成 `\r`）。把「用户粘贴」变成 pty 字节（含 Kitty 5522 粘贴事件）的唯一实现是 `src/terminal/paste.zig::paste`（`terminal-core`）。
- 绑定：`src/input/Binding.zig`。`Parser` 解析 `flags:trigger>trigger=action`（前缀 `all:`、`global:`、`unconsumed:`、`performable:`，以及 `chain=`）；`Trigger.Key` 分 `physical`、`unicode`、`catch_all`；`Action` 是绑定动作 union，配套 `Action.scope`、`Scoped`、`scoped`；`Set` 的值是 `leader`、`leaf`、`leaf_chained`，`reverse` 为菜单快捷键反查表；`Flags` 记录 consumed、all、global、performable。默认键位在 `src/config/Config.zig::Keybinds.init`（`config` 域）。
- 命令面板：`src/input/command.zig::Command`、`defaults`、`actionCommands`。动作文档生成：`src/helpgen.zig` 解析 `Binding.zig` 的 doc comment，`src/input/helpgen_actions.zig` 输出纯文本或 Markdown。
- 其他：`src/input/Link.zig`（基于 oniguruma 的链接匹配）、`src/input/keyboard.zig::Layout`（macOS 布局决定 option-as-alt 默认值）、`src/input/keycodes.zig::entries`（USB 与平台原生键码到 W3C 的映射）、`src/input.zig::Keymap`（macOS 用 `KeymapDarwin`，其余用 `KeymapNoop`）、`src/surface_mouse.zig::keyToMouseShape`。

## 不变量

### 按键处理顺序

- `Surface.keyCallback` 先应用 `key-remap`；`Surface.keyEventIsBinding` 必须做同样的映射，两者的查找逻辑不得分叉。
- 绑定优先：`maybeHandleBinding` 对 press、repeat、release 都执行。进行中的按键序列只查序列集合；否则从内到外查 key table 栈（上限 `max_active_key_tables` 为 8），最后查根集合。被消费的 press 记下 `bindingHash`，对应的 release 不再编码。
- `global:`、`all:` 绑定不能用于序列，执行时走 `App.performAllChainedAction` 且总是消费按键；`performable:` 的动作没执行成功时视同不存在。触发关闭类动作后立即返回 `.closed`，此后不再使用 surface 指针。
- `App.keyEvent` 只查根集合、不支持序列，也不处理 release：global 绑定无论 app 是否聚焦都在这里执行；app 聚焦时，动作全为 app 作用域的绑定也在这里执行；其余返回 false，交给 surface。
- win32-input-mode（DECSET 9001）：`Surface.encodeKey` 先问 `gx_win32_input.surfaceWriteReq`，只有本次事件带着匹配的 Win32 按键记录（由 `gxWin32KeyCallback` 传入）、子进程未退出、9001 已开且没有 kitty 标志时才以记录替换常规编码；只调 `keyCallback` 的 apprt 行为与上游相同。
- 编码：`encodeKeyOpts` 在 `renderer_state.mutex` 内用 `Options.fromTerminal` 取终端状态，macOS 再补 `macos_option_as_alt`；先写入 `termio.Message.WriteReq.Small` 大小的数组，放不下才分配，然后经 `Surface.queueIo` 发出。子进程已退出时，任何产生输出的按键都会关闭 surface。
- 鼠标上报在持锁状态下用 `mouse_encode.Options.fromTerminal` 构造选项，编码结果必须放进 `WriteReq.Small`，溢出时记日志并丢弃。
- 粘贴：`completeClipboardPaste` 在锁内判断安全性。开启 `clipboard-paste-protection` 时，不安全内容返回 `error.UnsafePaste` 交 apprt 确认；括号模式下含 `\x1b[201~` 一律不安全，否则受 `clipboard-paste-bracketed-safe` 控制。

### 绑定语义与新增动作

- `Set.getEvent` 的查找顺序：物理键 → 恰好一个码点的 `utf8` → `unshifted_codepoint` → 带修饰键的 `catch_all` → 不带修饰键的 `catch_all`。trigger 只比较 `Mods.binding()`。
- `Action.scope` 是穷举 switch；app 作用域由 `App.performAction`（参数为 `Scoped(.app)`）处理，surface 作用域由 `Surface.performBindingAction` 处理，两处也都是穷举。
- `Binding.Action` 字段的 `///` 注释就是用户文档：`ghostty +list-actions --docs`、man page（`src/build/mdgen/mdgen.zig`）与网站数据（`src/build/webgen/main_actions.zig`）都由它生成。
- 新增绑定动作的清单：
  1. 在 `Binding.Action` 加字段，写好 doc comment；
  2. 在 `Action.scope` 归类，并在 `App.performAction` 或 `Surface.performBindingAction` 实现；
  3. 在 `src/input/command.zig::actionCommands` 的穷举里决定是否进命令面板，标题与描述用 `i18n.N_` 标记（翻译同步见 `apprt-gtk.md`）；
  4. 需要 GUI 配合时新增 `apprt.Action`，按 `app-core.md` 的步骤同步 `include/ghostty.h`，并在 GTK、win32 与 macOS 三端实现；
  5. 需要默认键位时改 `Keybinds.init`（`config.md`）。
- fork 自有的界面操作不加新的 `Binding.Action` 成员，而是加 `gx:` 子动作（`src/gx/action.zig::Action`），由 apprt 的 `gxAction` 执行，不改 C ABI；GX 默认键位写在 `src/gx/defaults.ghostty`（`gx-core.md`）。

### C 可见类型

- 标注了「Any changes here update include/ghostty.h」的有：`src/input/key.zig` 的 `Action` 与 `Key`（`ghostty_input_key_e`）、`src/input/key_mods.zig::Mods`、`src/input/mouse.zig` 的 `ButtonState` 与 `Button`。`Binding.Flags.cval`、`Binding.Trigger.C` 同样映射到 `ghostty.h`。
- `Key`、`key.Action`、`mouse.Action`、`mouse.Button`、`config.OptionAsAlt` 还登记在 `src/terminal/c/types.zig` 的 ABI 类型清单里，对应 `include/ghostty/vt/key/event.h`、`include/ghostty/vt/key/encoder.h`（`GhosttyOptionAsAlt`）与 `include/ghostty/vt/mouse/event.h`。改枚举值或顺序要两套头文件一起改；lib-vt 头里的枚举保留 `_MAX_VALUE` 哨兵（`libghostty-vt.md`）。
- 每个 `Key` 成员都必须能与 W3C 名称互转（`Key` 内的 `test "w3c"`）；`function_keys` 的每条序列都必须放得进 `termio.Message.WriteReq.Small`（`test "keys"`，lib-vt 构建下跳过）。

### libghostty-vt 边界

- 五个编码文件属于 libghostty-vt 的公开面：`src/lib_vt.zig::input` 的 Zig API、`src/terminal/c/` 的 C API，以及消费它们的示例 `example/c-vt-encode-key`、`example/c-vt-encode-mouse`、`example/c-vt-paste`、`example/wasm-key-encode`。行为或签名变化要让这些接口与 `test-lib-vt` 保持全绿，示例和 `include/ghostty/vt/` 里引用它们的 Doxygen snippet 一并更新。
- `src/lib_vt.zig::input` 的注释写明只能导入目标文件，整个 input 包会带进过多依赖。五个编码文件及其传递闭包不得导入 `src/input.zig`、`Binding.zig`、`Link.zig`（oniguruma）、termio、apprt 或 `global.zig`。
- `key.zig` 顶层的 `@import("dcimgui")` 只是靠 Zig 惰性分析才不影响 lib-vt：lib-vt 模块不提供 `dcimgui`，lib-vt 可达代码不得调用 `Key.imguiKey`。
- 测试若需要 termio 等 app 依赖，照 `function_keys.zig` 的 `test "keys"` 按 `terminal_options.artifact` 在 `.lib` 下跳过。
- 编码器只依赖传入的事件与 `Options`（唯一的副作用是 `mouse_encode` 经 `last_cell` 回写去重状态），输出写进 `std.Io.Writer`；内部不读全局状态、不加锁，终端状态由调用方在锁内转换成 `Options`。

### 平台

- `KeymapDarwin` 与 `KeymapNoop` 必须保持同一接口（`init`、`deinit`、`reload`、`translate`、`State`、`Translation`）。目前只有 `src/apprt/embedded.zig` 在用：`App.keyboardLayout` 调 `sourceId` 推断 option-as-alt 默认值，`ghostty_app_keyboard_changed` 触发 `reload`；`translate` 没有活跃调用方，按键文本由宿主随 `ghostty_surface_key` 传入（该函数注释里的「keymap translation」已过时）。
- `Key.ctrlOrSuper`、`Mods.ctrlOrSuper`、`Mods.translation` 有 Darwin 分支（super 代替 ctrl、option-as-alt）；`keycodes.entries` 只支持 macOS/iOS、Windows、Linux/FreeBSD，其他平台 `@compileError`。

## 禁止项

- 在五个编码文件及其闭包中引入 app 层依赖，或让 lib-vt 可达代码触及 `imguiKey`。
- 改 C 可见枚举的值或顺序，却不同步 `include/ghostty.h`、`include/ghostty/vt/**` 与 `src/terminal/c/types.zig`。
- 在 `Action.scope`、`actionCommands`、`performBindingAction` 等穷举 switch 里加 `else` 来逃避处理新动作。
- 绕过 `Surface.queueIo` 写 pty，或在 `renderer_state.mutex` 外读取终端模式来构造编码选项。
- 跳过 `paste.isSafe` 与粘贴保护配置。

## 验证

- 定向测试：`just test --filter parse:` 与 `just test --filter set:`（Binding）、`just test --filter RemapSet`、`just test --filter legacy:`、`just test --filter kitty:`、`just test --filter ctrlseq`、`just test --filter KittySequence`（key_encode）、`just test --filter shouldReport`（mouse_encode）、`just test --filter keyToMouseShape`；fork 模块 `just test --filter gx.win32_input --filter gx.action`。平台相关的按键路径在 Windows 与 Linux（`just wsl test`）各跑一次。
- 改五个编码文件或其闭包：再跑 `just test-vt --filter RemapSet --filter legacy: --filter kitty: --filter ctrlseq --filter KittySequence --filter shouldReport`（Binding 的 `parse:`、`set:` 与 `keyToMouseShape` 不在 lib-vt 里）、`just build-vt` 与 `just vt-wasm`。
- 改 win32-input-mode 或 win32 的按键翻译：除单测外按 `apprt-win32.md` 启动 app 实测（PSReadLine 的 Shift+Enter、死键与 AltGr、输入法上屏），日志里有终端开始发送记录的说明行。改 C 可见类型：`just test --filter ghostty.h`，以及 `just zig build test-lib-vt-schema`（脚本需要 Python 的 `jsonschema`，并提示在 `nix develop` 中运行；本机缺依赖时记 PENDING，交 `gx-ci` 的 `linux-vt` job）。
- macOS：`key_encode`、`key_mods` 里的 option-as-alt 用例随 lib-vt，可交 `gx-ci` 手动触发的 `macos` job（它只跑 `zig build test-lib-vt`）；`KeymapDarwin` 只在 `ghostty-test` 里，要在 Mac 上跑 `just test`。本机两者都记 PENDING。GTK 下的实际按键体验同样记 PENDING，交 `gtk-smoke`。
- 改 Zig 后跑 `just fmt-check`。

## 上游指令

- `src/terminal/c/AGENTS.md`：编码器的 C API 包装与导出步骤；改编码器公开行为或 C 可见类型时必读。
- `example/AGENTS.md`：编码器示例工程与 Doxygen snippet 的约定；改动波及上述示例时必读。
