# GX UI 当前执行计划：单对话原生子智能体、集中验证、R6 收口

本计划依据当前对话 2026-10-14 的最新授权，覆盖旧交接文档的任务组织、构建频次和提交授权；功能范围仍是 F1–F10，原完整验收契约（`docs/GX_UI_REMAINING_PLAN.md`）中的门不因本计划而视为通过。原定截止北京时间 2026-10-14 02:48 **已超期**，如实保留，已用时间不清零。当前总状态 **`not_complete`**。

## 授权与组织

- 只派当前会话的原生子智能体，同时活动上限 10 个；不建独立对话或后台 CLI 会话，不恢复已归档的独立对话；当前对话里已完成的原生子智能体按需 followup 复用。子智能体直接指定 `model`、`reasoning_effort` 与 `fork_turns:"none"`，不改客户端配置。
- 模型：一般实现、修复、夹具、文档用 `claude-opus-5-5` `xhigh`；罕见的复杂跨进程生命周期、协议与绑定续延用 `gpt-6-astra` `xhigh`；清单、哈希、映射、证据 JSON 等机械工作用 `deepseek-flash` `max`。DeepSeek 的 fresh 明文探针已返回 `DEEPSEEK_PLAINTEXT_OK`；探针或创建成功不等于该模型的产出已验收。
- 全机重型任务（构建、完整测试、VM、性能）最多 3 个；同一工作树的构建串行，构建期间冻结相关源码；宿主桌面独占，GUI 与性能不并行。
- Windows 与 GTK 完整 main 各已运行一次（final-r2），不再重复；新编译后只重跑受影响的定向测试与场景。打包不重编，翻译、KB、图谱在源码与文档冻结后各生成一次。
- 用户已授权把全部已有与新增改动做本地阶段 commit，无需逐次确认：精确暂存、提交信息按根 `AGENTS.md`「提交规范」。不 push、不建 PR/Issue/tag/release、不新增下载，不触碰 `GX_API`。
- 主树按文件单写者工作；所有权按文件显式移交；状态经原生消息回传，不共写状态文件。文档、CHANGELOG、补丁登记与证据导航由文档工位独占，证据 JSON 由机械工位维护。

## 当前状态（2026-10-14 上午）

- HEAD 仍是 `ecdac24009f87a0694bd33fb2bc0ec4f65a546ad`；全部实现在工作区（已暂存与未暂存混合），未提交。
- 历史 W0 定向 161/161 PASS 只覆盖当时源码，独立保留。final-r2 的 Windows 定向汇总 226 PASS 中有 105 项来自误带的默认旧二进制，属于候选的只有 121 项，不得合计为最终证据。
- 最近一次完整候选是 final-r2 的 `candidate-20261014-0250`：Windows 完整 main 5017 总、4942 PASS、73 SKIP、2 FAIL（`lib.tinyio` 符号链接 `PermissionDenied`，环境前置）；GTK 完整 main 4533 总、4480 PASS、53 SKIP；远程普通窗口场景 native 7 项通过、4 张图已读（`PASS_SCOPED`）；W01–W20 有 17 个场景步骤通过，W06 SKIP、W07 与 W14 FAIL，W16 逐图审阅 FAIL（键盘打开主菜单时首项无可见高亮）；G01–G16 步骤全部通过，16 组图已由 Opus 审阅者读完并给出限定 PASS（Xvfb 软件路径）。详表与限制见 [证据索引](GX_UI_EVIDENCE_INDEX.md) 2.1。
- final-r2 之后 root 继续修改 App、Surface、Window、Palette、SearchBar、Remote* 与 runtime helper，并已修：W14 主题预览、W16 键盘打开主菜单时 Window 为 null 的入口（首项高亮）、W07 失败终端关闭后清除自己的提示（场景已改写为非模态 Notice，D12）、BellBorder，以及粘贴的父窗口、once 与扇出忙碌守门。**这些修复都待本批编译，尚未验证，不能把任何功能标为完成。**
- 新快照 `80fd77531` 合并后，Windows 在唯一主树构建到 `--prefix zig-out-resume`（含 install、test-bin 与 `-Demit-webdata`），只做定向与场景，不是完整 main：首编 session 48133（源快照 `final-r2/evidence-resume/source-snapshot-20261014T025803Z-ecdac2400-resume-prebuild.json`）失败于 4 处接线错误，root 已修；修复编译 session 44734（源快照 `…T030359Z-ecdac2400-resume-repair-prebuild.json`）**尚未编译通过**。新产物输出到 `zig-out-resume`，不覆盖仍用于预演的 02:50 产物；预演（如 `final-r2/windows-fixtures-resume/rehearsal-old0250-*`）只用来调通夹具，不作当前证据。
- 场景「步骤通过」只说明脚本与断言通过，不等于 GUI 通过；读图并写出结论后才记 PASS。

## 功能状态

| 项 | 源码 | 现有证据 | 状态 |
|---|---|---|---|
| F1 混合树完整交互与本地 Session 剪枝 | `Leaf`/`Pane`、`Window.adoptRemoteTab`、`TabTransfer`、`Session` 剪枝远程叶 | final-r2 两进程迁移与混合分屏 `PASS_SCOPED`；剪枝单测 | PENDING：拖回、混合标签拒绝、zoom/active/override、迁移后关源窗的完整场景 |
| F2 普通窗口远程视图和完整输入 | `RemotePane`、`RemoteInput`（键、文本、IME、鼠标、粘贴分块）、`key_translate` | 远程输入进原 shell（PID/birth 不变） | PENDING：IME、鼠标报告、粘贴的真实远程场景；DWM 上屏 |
| F3 协议 v2 与源端状态 | `gx/remote_protocol.zig`、`RemoteSource`、`RemoteCoordinator` | 定向单测 | PENDING：最新源码编译与定向复跑 |
| F4 续延与有界输入队列 | `gx/remote_binding.zig`、GX-0044（`src/Surface.zig`）、`RemoteSource` | 定向单测、`Gx0044ShapeTests` | PENDING：真实链式绑定、once、performable 回退与断连取消 |
| F5 目标 UIA/OLE/确认/搜索/剪贴板/菜单 | `RemotePaneUi`、`ui/uia_remote.zig` | 无远程窗格上的 GUI 证据 | PENDING |
| F6 broker 与 shim 收口 | `ipc/DropBroker`、`DropBridge`、`DropCompanion`；三个 Windows shim 已从工作区删除 | broker 粘贴确认定向单测；无运行证据 | PENDING：VM 四权限方向矩阵；shim 删除待新编译 |
| F7 GTK 生命周期 | `gtk/gx/{runtime,origin,tree_lifecycle,session,window_state,split_transfer,shortcut_editor,launch_profiles_dialog}.zig` 与 GX-0039 钩子 | GTK 完整 main 通过；G01–G16 步骤通过且读图限定 PASS | PENDING：新快照编译；G15 的 PID/PTY 恒等、真实 session 重启、管理器 CRUD、硬件与 Wayland |
| F8 Win11 系统集成 | `ShellIntegration`、`shell/*`、安装器注册 | VM 到登录界面 | PENDING：安装/升级/卸载、通知冷暖激活、JumpList、broker 矩阵 |
| F9 文档/译文/补丁/证据 | 本轮 R6 文档已按源码更新；GX-0039～GX-0044 登记 | `test_fork_patches` 80 tests OK | PENDING：i18n/KB/图谱生成、`just framework-check`、`just generated-check` |
| F10 条件实验与性能 | C1–C8 保持默认；DComp 实验默认关 | 无新样本 | PENDING；P4 保留既有 FAIL 至重测 |

## 接口冻结（仍有效）

- `Window.adoptRemoteTab(at, description, panes)!refs.Reference`：RemotePane 由远程侧创建，Leaf 与树由 Window 创建，仅成功后转移所有权；`leafForPane`、`activeLeaf`、`removeLeaf`、`onLeafStateChanged`、`describeTab`、`performUiAction`；App 提供 `resolveLeaf`、`resolveRemote`、`visiblePanes`。
- `RemoteCoordinator.sendToSource/sendToTarget` 按 source 稳定引用找已认证连接；`RemotePaneUi.handlePacket`、`performBindingAction` 的返回值只表示真实结果。
- 协议 v2：两端共享规范动作文本；请求与结果携带 surface、lease、transaction、config_generation；快照文本有界（60 KiB），不按值扩张队列槽位。源持有终端与绑定状态，目标持有可见 UI。
- 语义：源丢失不重放命令；目标退出归还源；纯远程标签可拖回源，混合标签禁止跨进程迁移；all/global 只作用目标可见窗格；Session 不保存远程叶；Quick Terminal 拒收远程。粘贴单块受协议上限约束、总量不超过 16 MiB，不追加 Enter。模态返回后重查稳定引用。

## 补验顺序（新编译后）

1. 冻结相关源码，同树串行构建一次 Windows app 与 test-bin，记录 exe SHA256；GTK 在 WSL 克隆同步后构建一次。
2. 受影响定向：`just test --filter apprt.win32 --filter gx.` 中与改动相关的子串（运行期 filter 必须非零命中），GTK 用 `just wsl test --gtk --filter apprt.gtk.gx`；不重跑完整 main。
3. Windows 场景：`just win-gui run --out <新的绝对目录> W07 W14 W16`，再按 runtime helper 的影响面加选；逐图签收。W06 只在获准打开默认浏览器时加 `--allow-side-effects`。
4. 远程：`test/windows/gx_remote_fixture.py` 用新 exe 重跑，并补拖回、混合标签拒绝与源故障步骤；VM 中跑 `test/windows/gx_drop_broker_fixture.py` 与安装/通知/JumpList。
5. GTK：新快照的 G 场景按影响面重跑并读图；G15 与 session 重启补 PID/PTY 与几何证据。
6. 冻结后：`just i18n`、`just fluent-check`、`just pinyin-check`、`just kb`、`just graph`，再 `just generated-check`、`just framework-check`、`just ci-check` 与 `git diff --check`。

每项逐条记 PASS / FAIL / PENDING / BLOCKED / N/A 并附原件；未运行项写补验命令与理由，不写假绿。
