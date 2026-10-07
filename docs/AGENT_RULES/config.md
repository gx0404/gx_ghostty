# config：配置系统、重载语义与配置文档生成

## 范围

- 门面 `src/config.zig`（re-export 字段类型、`ConditionalState`、`FileFormatter`、`CApi`）与 `src/config/**`：`Config.zig` 承载全部配置键，其余模块负责键枚举、条件、主题、路径、命令、格式化，另有首启模板 `config-template` 与主题测试夹具 `testdata/`；`ErrorList.zig` 当前无人引用。
- C 与 wasm 读取面 `CApi.zig`、`c_get.zig`、`Wasm.zig`；把 doc comment 变成 `help_strings` 模块的 `src/helpgen.zig`。
- 并集分工：`CApi.zig`、`c_get.zig` 的 ABI 规则见 `libghostty-embedding.md`；参数语法实现 `src/cli/args.zig` 与 `+show-config`、`+validate-config`、`+explain-config` 见 `cli-inspector.md`；`help_strings` 的构建接线（`src/build/` 下的 `HelpStrings.zig`、`GhosttyDocs.zig`、`GhosttyWebdata.zig`、`mdgen/`、`webgen/`）归 `build-system.md`，这里只写它们对 doc comment 的要求；各 `DerivedConfig` 的消费端见 `app-core.md`、`renderer.md`、`font.md`、`termio-pty-os.md`。

## 符号真源

### 键与字段类型

- `src/config/Config.zig::Config`：每个非 `_` 字段就是一个配置键，同时是 CLI 旗标 `--<key>=<value>`，键名为 kebab-case（如 `@"font-size"`）。`_arena`、`_diagnostics`、`_replay_steps` 等 `_` 开头的字段是内部状态，`Key`、helpgen、格式化、补全与文档生成都跳过它们。
- `src/config/key.zig::Key` 由字段在编译期生成，`Value(key)` 给出字段类型；`Config.changed`、`Config.changeIterator`、`c_get.get` 都按它索引。
- `Config.compatibility`：旧键名到 `CompatibilityHandler` 的映射（`cli.compatibilityRenamed` 或文件内的 `compat*` 函数），只在该键正常解析失败后才调用。
- 字段类型可实现的协议（缺省时各有退路）：`parseCLI`（1、2、3 参三种形态；没有时按类型通用解析）；`formatEntry`（非 packed 的 struct 与 union 必须提供，否则 `src/config/formatter.zig::formatEntry` 编译报错）；`clone`（持有分配的类型必须提供：`Config.cloneValue` 遇到没有 `clone` 的 union 只做浅复制，遇到非 packed 的 struct 只有运行时断言，编译期都不会报错）；`equal`（缺省按字段递归，见 `src/datastruct/comparison.zig::deepEqual`）；`init`（空值复位时调用，如 `Keybinds`）；`cval`（供 C 读取）。

### 加载链

- `Config.load` = `default` → `loadDefaultFiles` → `loadCliArgs` → `loadRecursiveFiles` → `finalize`。
- `loadDefaultFiles`：XDG 下先读旧名 `ghostty/config`，再读 `ghostty/config.ghostty`，两者都在就都加载；macOS 另读 Application Support（路径函数在 `src/config/file_load.zig`）。一个也没有时按 `config-template` 写出模板。
- `loadCliArgs`：Linux/FreeBSD 识别以 `xdg-terminal-exec` 身份启动；CLI 上的 `font-family*` 覆盖而非追加；`--config-default-files=false` 时借 replay 丢掉默认文件的内容。`Path`/`RepeatablePath` 的相对路径，来自 CLI 时按当前目录展开，来自文件时按该文件所在目录展开。
- `loadRecursiveFiles`：按出现顺序加载 `config-file`，`?` 前缀表示可选，同一路径再次出现记 cycle 诊断；`-e` 及其后的参数始终留在 replay 末尾。
- `finalize`：先处理 `theme`（`loadTheme` 会整体替换 Config），再补 `font-family-*`、`term`、`command`、`working-directory` 的默认值并夹取数值范围；幂等，但多次调用浪费内存。
- `Config.parseManuallyHook`：`-e` 吞掉其后全部参数作为 `initial-command`，并隐含设置 `gtk-single-instance`、`quit-after-last-window-closed` 等；其余参数原样记入 replay。
- replay：`Config._replay_steps` 记录全部输入（`Replay.Step` 的 `arg`、`expand`、`conditional_arg`、`diagnostic`、`-e`）。`loadTheme` 读完主题文件后重放用户输入；`changeConditionalState` 只重放、不重读配置文件（随后的 `finalize` 仍会重新打开主题文件），所以配置文件中途被删也能切换明暗。
- 条件配置：`src/config/conditional.zig::State`（目前只有 `theme` 明暗与 `os`）。`loadTheme` 把主题文件的每个参数改写成以 `theme == <当前明暗>` 为条件的 `conditional_arg`，再重放用户输入，所以用户设置总是覆盖主题；明暗主题不同时把 `.theme` 记入 `_conditional_set`，并把 `window-theme = auto` 改为 `system`。
- 主题查找：`src/config/theme.zig::open` 按 `LocationIterator` 先找 `$XDG_CONFIG_HOME/ghostty/themes`，再找资源目录下的 `themes`（由构建依赖 `iterm2_themes` 安装，受 `-Demit-themes` 控制）；非绝对路径的主题名不得含路径分隔符。
- 诊断：`Config._diagnostics` 的类型是 `src/cli/diagnostics.zig::DiagnosticList`。

### 运行时重载

- apprt 收到 `reload_config`（`src/apprt/action.zig::ReloadConfig`；`soft` 表示不重读磁盘，只把完整配置再下发一次）后调用 `src/App.zig::App.updateConfig`：逐个 surface 发 `change_config`，再按 App 自己的条件状态向 apprt 发 `config_change`。系统明暗变化经 `App.colorSchemeEvent` 与 `src/Surface.zig::Surface.colorSchemeCallback` 触发软重载。
- `Surface.updateConfig`：先 `changeConditionalState`，再重建 `src/Surface.zig::DerivedConfig` 与字体网格（手动调过的字号保留），然后向渲染线程发 `src/renderer/message.zig::Message.initChangeConfig`（内含 `src/renderer/Thread.zig::DerivedConfig` 与 `src/renderer/generic.zig::DerivedConfig`），向 termio 发 `change_config`（`src/termio/Termio.zig::DerivedConfig`），最后发 `config_change` 动作；Surface 侧的其余步骤见 `app-core.md`。
- termio 不重启子进程：`command`、`working-directory` 这类键只影响之后新建的 surface（见 `Termio.changeConfig` 的注释）。

### C 与 wasm 读取面

- `src/config/CApi.zig` 导出 `ghostty_config_*`。`ghostty_config_get` 用 `Key` 把字符串键映射到 `src/config/c_get.zig::get`（逐类型的写入规则见 `libghostty-embedding.md`）；要点是枚举以 tag 名的 C 字符串返回，`?[:0]const u8` 为 null 时返回 true 并写入 null，其余可选值为 null 时返回 false。macOS 的 `macos/Sources/Ghostty/Ghostty.Config.swift` 就按字符串键逐个读取。
- `src/config/Wasm.zig` 只被 `src/main_wasm.zig` 引用，而全仓没有构建脚本引用 `src/main_wasm.zig`；它调用的 `cli.args.lineIterator` 已不存在（`src/cli/args.zig` 现为 `LineIterator` 结构体）。这段代码不受任何构建覆盖，不能当作 wasm 配置可用的证据。

### 配置即文档

- `Config.zig` 顶部注释规定：字段 doc comment 按 Pandoc 风格的 Markdown 书写。
- `src/helpgen.zig::genConfig` 在 `Config.zig` 的 token 流里寻找「紧跟 `///` 的同名标识符」，取第一处匹配，产出 `help_strings.Config.<key>`；同一程序还产出 `help_strings.Action`（各动作 `run` 的注释，见 `cli-inspector.md`）与 `help_strings.KeybindAction`（`src/input/Binding.zig::Action` 成员的注释）。
- 消费方：`+explain-config`；`+show-config --docs`（`src/config/formatter_file.zig::FileFormatter`，每行前加 `# `）；`Keybinds.formatEntryDocs`；`src/build/mdgen/mdgen.zig`（`ghostty(1)`、`ghostty(5)` 的 Markdown，`-Demit-docs` 时再经 pandoc 转成 man 与 html）；`src/build/webgen/main_config.zig`（`share/ghostty/webdata/config.mdx`，`-Demit-webdata`）；`src/extra/fish.zig`（补全描述）。

## 不变量

- doc comment 就是用户文档，写法要同时照顾全部消费方：
  - 示例用 4 空格缩进块（webgen 把它转成代码围栏）；以 `Note:`、`Warning:` 开头的段落在网站上渲染为提示框。
  - 首句独立成义：fish 补全截取到第一个句号为止作为描述。
  - 写清默认值语义、平台限制（文件里有 `GTK only.`、`Only implemented on macOS.` 等写法）、能否在运行时生效（文件里常见 `will only affect new terminals`、`requires a full restart` 一类说法）；新键沿用文件里的 `Available since …` 行。
  - 不写注释的字段在网站上并入前一个有注释字段的标题，只用于紧邻的同组变体（如 `font-family-bold` 跟随 `font-family`）。
- helpgen 取第一处匹配：配置字段区必须留在 `Config.zig` 顶部，字段之前不得出现带 `///` 且与某个键同名的声明。
- `help_strings` 是 helpgen 的输出，而 helpgen 自身要编译 `Config.zig`：只能在 helpgen 不会分析的代码里引用 `help_strings`（现状只有 `Keybinds.formatEntryDocs`），不得出现在字段类型、默认值或顶层 comptime 里。`src/build/SharedDeps.zig::add` 给 exe、lib 与 `ghostty-test` 都挂上 `help_strings`，helpgen 一失败这些构建全部失败；`just test-vt` 不经过 helpgen，不能代证。
- 依赖面保持轻量：`Config.zig` 只引入 terminal 的一个子集（见文件内 `terminal` 结构体的注释），因为 `ghostty-build-data` 与 helpgen 要在构建宿主上编译它；`formatter.zig`、`url.zig` 被 `src/input/Binding.zig`、`src/terminal/StringMap.zig` 等直接引用，不得反向引入 `Config.zig`（`FileFormatter` 因此单独放在 `formatter_file.zig`）。
- 用户输入错误不中止加载：目标类型有 `_diagnostics` 时，`cli.args.parse` 把未知键、缺值、非法值都记成诊断后继续，只有 OOM 向上返回。新增诊断只经 `DiagnosticList.append` 或 `Config.addDiagnosticFmt`：libghostty 构建要同步维护预计算的消息，`ghostty_config_get_diagnostic` 靠它无分配地返回。
- 往返：`formatEntry` 的输出必须能被同类型的 `parseCLI` 读回为等价值，这是 `+show-config` 对用户的承诺。`Config.clone` 必须连同 `_replay_steps`、`_conditional_set` 与条件状态一起复制，否则之后的明暗切换会丢配置。
- 线程边界：`App.updateConfig` 收到的 `*const Config` 只在调用期间有效，`config_change` 动作里的指针同样不能保存；渲染线程与 termio 线程只接收堆上的 `DerivedConfig` 副本，从不读取 `Config` 本体。要让新键在运行时生效，必须把它加进相应的 `DerivedConfig`（Surface、渲染线程、渲染器、`src/font/SharedGridSet.zig::DerivedConfig`、Termio），或由 apprt 在 `config_change` 中自行复制；做不到就在 doc comment 里写明只对新 surface 生效。
- `changeConditionalState` 在本配置用到的条件键都没变时返回 null；调用方继续使用原配置，这不是错误。
- 键的兼容性：改名或删除键时在 `Config.compatibility` 登记处理函数，并补 `compatibility:` 前缀的测试，旧配置不得因此报 unknown field。C 侧以字符串键与枚举 tag 名为契约：改键名、改 tag 名、改带 `cval` 的类型，或改注释要求同步 `ghostty.h` 的 `enum(c_int)`，都要同步 `include/ghostty.h` 与 Swift 读取点。
- 配置文件语法由 `src/cli/args.zig::LineIterator` 定义：每行 `key = value`，两端成对的双引号会被去掉；去掉缩进后以 `#` 开头的行才是注释；容忍 CRLF（UTF-8 BOM 由 `Config.loadReader` 跳过）；值为空表示复位为默认值（或调用 `init`）。
- `config-template` 会作为格式串交给 `writer.print`，唯一的占位符是 `{[path]s}`；正文出现字面 `{`、`}` 时必须写成 `{{`、`}}`。

## 禁止项

- 不用 `//` 普通注释代替字段的 `///`；不在 doc comment 里写未经核实的平台、版本或默认值承诺。
- 不直接删除或改名配置键；不在没有兼容处理的情况下改变已有键的取值语义。
- 不在 `Config.zig` 引入 `terminal/main.zig`、渲染器、apprt 这类重依赖；不在 `formatter.zig`、`url.zig` 里引入 `Config.zig`。
- 不在渲染线程或 termio 线程读取 `Config`；不为了让某个键可重载而跨线程缓存 `*const Config`。
- 不绕过 `DiagnosticList.append` 直接改 `_diagnostics.list`。
- 不手改 helpgen、mdgen、webgen 的产物（它们只存在于 `.zig-cache/` 与安装目录）；文档问题回到 doc comment 修正。
- `src/config/**` 与 `src/helpgen.zig` 是上游源码：fork 内的改动（包括新增配置键）必须带 `fork(gx)` 标记并登记 GX 补丁（流程见 `development.md`），否则不改。

## 验证

- 定向单测（`just test`，Windows 上只是尽力而为；完整的 Linux 覆盖看 `gx-ci` 的 `linux` job）：
  - 解析与兼容：`just test -Dtest-filter=compatibility`、`just test -Dtest-filter=parseCLI`、`just test -Dtest-filter=LineIterator`。
  - 条件、主题与克隆：`just test -Dtest-filter=changeConditionalState`、`just test -Dtest-filter=theme`、`just test -Dtest-filter=clone`。
  - 格式化往返：`just test -Dtest-filter=formatEntry`、`just test -Dtest-filter=formatConfig`。
  - C 读取：`just test -Dtest-filter=ghostty_config_get`、`just test -Dtest-filter=c_get`。
- 改 doc comment 或字段集合：`just build -Demit-webdata` 会运行 helpgen 与 webgen，不需要 pandoc；man 与 html 用上游 CI 同款的 `just build -Dapp-runtime=gtk -Demit-docs -Demit-webdata`，只能在装有 pandoc 与 GTK 依赖的 Linux 上运行，本机记 PENDING。
- 行为冒烟需要可运行的 `ghostty`：Linux 的 GTK 构建产出 `zig-out/bin/ghostty`；macOS 用 app 包里的可执行文件（`macos/Sources/App/main.swift` 经 `ghostty_cli_try_action` 执行动作）；Windows 只产出库，本机记 PENDING。检查 `ghostty +validate-config --config-file=<临时文件>` 在有诊断时退出 1，`ghostty +show-config --default --docs` 列出全部键及其文档。
- 改 C 读取面：再跑 `libghostty-embedding.md` 的验证；macOS 侧的构建按 `macos/AGENTS.md`。
- 收尾：`just fmt-check`；改了 `pub` 签名或文档后跑 `just kb`。
