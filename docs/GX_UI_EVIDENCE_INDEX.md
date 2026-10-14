# GX UI 后续实施证据索引

核对日期：2026-10-14（R6 文档收口）。整体状态：**not_complete**。本文件是实施中的独立证据导航，不修改原验收范围，不代替任务账本，也不重开原 37 份源码审计。

## 1. 真源与证据边界

- 完成合同：`docs/GX_UI_REMAINING_PLAN.md` 第 6—9 节；进度补充：`docs/GX_UI_HANDOFF_PLAN.md` 第 8 节。本轮用户确定的并行实施、默认恢复关闭、`-e` 独立、Docker 测试机、DComp 默认关闭，以及 2026-10-14 起的本地阶段 commit 授权（仍不 push、不建 PR/Issue/tag/release、不新增下载），优先于旧计划的历史授权措辞；任务组织见 `docs/GX_UI_EXECUTION_PLAN.md`。
- 本轮执行账本：`.local/evidence/R5/execution-20261013/tasks.json`。核对时所有必需任务仍为 PENDING；其中的批次 PASS 只证明明确选中的范围。
- 原叶需求账本：同目录 `leaf-matrix.json`，共 **21 组、142 叶**，其中 Windows R2 为 117 叶、GTK R3 为 25 叶；`results={}`、`case_to_leaves={}`，最终逐叶状态仍全部 PENDING。该文件保留原候选 `d6f9e1c…` 身份，同时另记本轮基线，不能把两个树当成一个最终树。
- 本轮主仓 HEAD 实查为 `ecdac24009f87a0694bd33fb2bc0ec4f65a546ad`，新增实现仍在工作区。本文引用当前源码入口，不声称该 HEAD 已包含工作区改动。
- 最新有证据的 Windows 候选是 final-r2 的 `candidate-20261014-0250`（见 2.1）；更早的 **windows-app-06**（SHA256 `7557404780b692387db62a3662826a4fd7f9f04b10844f0804831042faffe0f5`）只证明远程单叶迁移与 Palette 回收修复。两者都不覆盖 10:00 之后的源码。
- 当前图谱不含新远程模块；查询已成功，提示技能文本与本地 graphify 包版本不同。这里只用图谱作旧入口导航，新增事实以源码为准；最终冻结仍须重建。

本文用 U 表示纯逻辑或定向测试，N 表示实际原生调用，G 表示真实交互及已读截图，P 表示原性能合同。U/N 不代 G，构建成功不代运行，单个 G 不代 142 叶，运行器退出 0 不代读图。下面各表中的 PENDING 指**完整任务验收**；已有子证据单独注明。

证据目录缩写 `E` 仅指 `.local/evidence/R5/execution-20261013/`，`W` 指 `src/apprt/win32/`，`G` 指 `src/apprt/gtk/gx/`，`K` 指 `src/apprt/gtk/class/`。这些是仓内路径，不是额外真源。

## 2. 本轮已经能证明的范围

### 2.1 最终候选 final-r2（`candidate-20261014-0250`）

`F` 指 `E/final-r2/`。该候选由 2026-10-14 约 02:46 的工作区一次构建（`F/final-build.log`；此前 `F/m1-build.log` 的 ReleaseFast 测试构建 9 处编译错误作为失败原件保留）。此后 root 继续修改 App、Surface、Window、Palette、SearchBar、Remote* 与 runtime helper（`F/app-review/` 留有 10:31 的快照与 diff），新快照 `80fd77531` 在唯一主树构建到 `zig-out-resume`（含 install、test-bin 与 `-Demit-webdata`；不覆盖 02:50 产物，非完整 main）：首编 session 48133（源快照 `F/evidence-resume/source-snapshot-20261014T025803Z-ecdac2400-resume-prebuild.json`）**FAIL**，4 处接线错误由 root 修复；修复编译 session 44734（源快照 `...T030359Z-ecdac2400-resume-repair-prebuild.json`）**尚未编译通过**，同目录另有 `T030732Z` repair2 快照，其构建结果待 root 确认；**新源码未经验证前，下表结论不继承到当前工作区**；`F/windows-fixtures-resume/` 下基于旧 02:50 产物的预演只用于调通夹具；Windows、GTK 完整 main 各已运行一次，按计划不重复，新编译后只重跑受影响的定向测试与场景。

| 证据入口 | 实际结果 | 能证明的范围与限制 |
|---|---|---|
| `F/windows-main-final.json`、`.log` | 完整 Windows main：总 5017，PASS 4942，SKIP 73，FAIL 2；seed `0xdfd10e41`，jobs 3，二进制 `zig-out-final/test/ghostty-test.exe` | 2 个 FAIL 都是 `lib.tinyio` 符号链接用例的 `PermissionDenied`（未开开发者模式），记环境 FAIL，不跳过、不改用例；只绑定该候选源码 |
| `F/gtk-main-final.log` | 完整 GTK main（WSL）：总 4533，PASS 4480，SKIP 53，FAIL 0；seed `0x6bdde806`，jobs 1 | 绑定当时同步到 WSL 克隆的源码与 `F/gtk-build-final.log`；不代硬件、Wayland 或 IME |
| `F/windows-targeted.json`、`.log` | 运行器汇总 226 PASS、0 skip，seed `0xa727726b`，jobs 2；**其中 105 项来自误带的默认旧二进制，属于当前候选的只有 121 项 PASS** | 只能按候选二进制的 121 项理解远程服务、Quick 末标签、protected paste 回执、broker 粘贴确认等所选用例；226 不得合计为最终证据 |
| `F/w0/w0-targeted.json` 与日志 | 历史 W0 定向 161/161 PASS | 只覆盖 W0 当时的源码，独立保留，不与 final-r2 或后续批次合计 |
| `F/remote-normal-window/report.json`、`review.json` | native 7 个检查 PASS，4 张图已读，`PASS_SCOPED`；app SHA256 `536afb0b09a01aef3c6667f18470dba8b5d144e75be36d505926ab44f256347e` | 两个独立宿主的普通窗口迁移、远程输入进原 shell（PID/birth 不变）、远程窗格旁新建本地分屏、目标进程被结束后原 core 恢复且命令只启动一次。3 张图是 PrintWindow，只证可读内容；不证 IME、OLE、MTA UIA、protected paste、拖回、session 重启与源故障 |
| `F/windows-scenarios/SUMMARY.txt` 与各 `notes.txt` | W01—W20：17 个场景步骤通过，W06 SKIPPED（需 `--allow-side-effects`），W07、W14 FAILED | 步骤通过不等于 GUI 通过；本轮有书面逐图结论的只有 W16（见下一行），其余场景的图读完前记 PENDING。W07 旧 expect 仍按模态对话框写，产品早已是非模态 Notice（D12），场景已改写，root 另修了失败终端关闭后清除自己的提示；W14 Nord 预览取色 `#1f1f28`≠`#2e3440`，root 已修预览代码；两者待新编译复验（`F/repro-w07-w14/` 为修前复现） |
| `F/windows-scenarios/W16/review-root.json` | 视觉 **FAIL**：7 张图已读；右侧锚点、快捷键分类与键帽、设置六分区 PASS，键盘打开主菜单时首项「New Tab」没有可见高亮 | expect 要求首项高亮；root 已修键盘入口 Window 为 null 的源码，待本批编译后新验，此前 W16 不计入 GUI 通过 |
| `F/gtk-scenarios/SUMMARY.txt` 与各 `notes.txt` | G01—G16 全部步骤通过 | Xvfb 软件路径、Debug、GTK 4.14.5/libadwaita 1.5；Opus 审阅者已读完 16 组图，限定 PASS（书面记录由证据工位写入 JSON）。不代 G15 的 PID/PTY 恒等、session 重启、管理器 CRUD、硬件、Wayland 或 IME |
| `F/contracts-resume.log` | 框架定向 247 tests，9 skip，OK | 10:01 时的脚本与契约子集；不是 `just framework-check`，其后文档与脚本变化须重跑 |
| `F/source-manifest.{json,md,txt}` | 00:31 的源快照清单（HEAD `ecdac2400…`、143 个身份文件） | 只描述那一刻的工作区，不是 final-r2 构建的源身份 |

### 2.2 历史批次（只证明各自快照）

| 证据入口 | 实际结果 | 能证明的范围与限制 |
|---|---|---|
| `E/windows-22.log` | PASS：569/569，0 skip，seed `0x52553049`，jobs 2 | 本地 Pane、DropBridge/Companion 接线及受影响 Windows 子集；不是完整 main，晚于此批的确认视图寿命修复待另验 |
| `E/bell-native-01/results.json`、两份 native 文本 | 限定 N PASS：5/5，0 skip，seed `0x5255304a`，jobs 1 | batch22 二进制、RTX 5080 真实隐藏 GL/FBO、context 重建及 idle worker 产帧；不是桌面 DWM 边框验收 |
| `E/remote-app06-01/review.json` | 限定 N/G PASS：两进程单叶迁移及断连恢复，3 图已读 | 原 core ID、terminal HWND、cmd PID/birth 与单次启动保持；源普通窗口关闭后后台宿主仍存活。仍为专用远程窗口，非普通窗口 local/remote 混合树 |
| `E/popup-uia-current-user-01/review.json`、`uia-root-app05/report.json` | 限定 N/G PASS：popup 13 图、6 次外部 MTA、5 个 DComp 故障阶段；root 非客户区去重复验通过 | 不代读屏、Notification 事件、Win10、WARP 或性能；保留此前前台激活失败原件 |
| `E/ole-source-window-app05-01/review.json`、`ole-source-window-app05-02/review.json` | 限定 N/G PASS：真实外部 DoDragDrop，8 图已读 | 同权限 text/multiline/files、默认取消保护与路径引用；不代跨权限四方向 |
| `E/gtk-app-08.log`、`gtk-gui-08/review.json` | 构建及 G15/G16 限定 G PASS：4 图已读 | WSL 快照 `0ea5f8303`；既有分屏内容移入新标签、中文 profile manager 可打开；不代迁移 PID/PTY、CRUD 或重启 |
| `E/innosetup-setup.log` | PASS：钉版 7.1.0 便携工具安装与摘要校验 | 仅工具准备；不代安装包编译或 VM 安装/升级/卸载 |
| `E/windows-12.json`、`windows-12.log` | PASS：557/557，0 skip，seed `0x5255303c`，jobs 3 | 当批 `apprt.win32`、引用、IPC、session、全拼、Fluent、编辑模型及 toggle 选中用例；不是完整 main，也不包含后来所有修改 |
| `E/windows-13.json` | PASS：530/530，0 skip，seed `0x5255303e`，jobs 2 | 当批 win32、session、shell startup、argv、remote_view 子集 |
| `E/windows-14.json` | PASS：558，SKIP：5，总选中 563；seed `0x52553041`，jobs 1 | win32、session、Shell、远程模型和 WGL 选中范围；5 个显式启用的 BellBorder GL 用例未运行，不能称“全部 native GL 通过”；该批也不覆盖随后 session OOM 第二阶段修复 |
| `E/windows-app-04.log` | PASS：标准 app 构建 | 绑定上节 app04 哈希；不是安装包、最终全部测试或 GUI 总门 |
| `E/gtk-interfaces-02.log`、`gtk-04.log`、`gtk-05.log` | PASS：81、26、104，各 0 skip | 分别绑定快照 `479c38195`、`f9a526817`、`207362f94` 的选中范围；不累加成最终完整 suite |
| `E/gtk-06.log`、`gtk-07.log` | PASS：91/91、16/16，均 0 skip | 分别绑定 `e1c50a811`、`fbde5c1f2`；后一批为 session 等定向验证，不代真实多轮重启 |
| `E/gtk-app-05.log`、`gtk-app-06.log` | PASS：GTK app 构建记录 | 保留各自 WSL build receipt/快照；不能用当前 Windows 工作区替代其构建身份 |
| `E/windows-gui-02/W01/run.json` 与该目录 3 张图 | 限定 G PASS：标题覆盖、OSC 标题后保持、清空后跟随 | app 第 1 批的标题场景；不证明 DComp、UIA、session 或其余 W01—W20 |
| `E/gtk-gui-05/review.json` | 限定 G PASS：G05/G08 共 4 图 | `207362f94`，Debug Xvfb 软件路径；标签/分屏及启动菜单条目，不证明 Wayland、真实迁移身份、manager CRUD |
| `E/gtk-gui-new-01/review.json` | G15 限定 PASS；G16 FAIL | G15 仅看到既有输出进入第二个 tab，PID/PTY 未证明；G16 原按键没有打开管理器，不能被 runner exit 0 覆盖 |
| `E/gtk-gui-manager-02/G16/` 与对应 `.log` | 运行器 exit 0；独立视觉结论 PENDING | 该目录有新原生运行/图像证据；本索引未据此自行签署读图或完整 CRUD 通过 |
| `E/windows-session-fixture-02/report.json` | 限定 N PASS：普通 launcher 复用、`-e` 独立、默认 off 保留文件；custom FAIL | app02；PrintWindow 图仍 PENDING，不代 GL/DWM 上屏 |
| `E/windows-session-fixture-04/report.json` | 限定 N/G PASS：两次 custom 恢复每次确认、Quit 保留、关闭写空；4 图已读 | app04，同私有状态更新 PID/birth；不覆盖嵌套树、所有来源、CLI、写失败与双 writer 全矩阵 |
| `.local/evidence/R5/uia-readonly-root-app04/` | 限定 N PASS：外部、无 HWND 的 MTA 查询 | 共 18 节点，其中 11 个 `gx-` 自定义节点，包含 Window/Tabs/terminal pane；未 activate、未发键鼠、无截图。实际发现重复非客户区标题栏，后续修复尚待新 app 复验 |
| `.local/evidence/R5/popup-uia-dcomp-app04/report.json` | FAIL：前台 HWND=0、激活失败 | 未发输入、未查询 popup、无截图；自有实例正常关闭。此次失败不意味着桌面永久不可用，也不能绕过守门重试成绿 |
| `.local/evidence/UI-implementation-20261013/ole-text-first/report.json` | FAIL：受控 OLE text 首次场景在激活守门停止 | app04 与外部 source 各有哈希；无截图、未读剪贴板、未注入 Enter、自有 app 正常关闭。不能据 source 程序存在称真实 Drop 已通过 |
| `.local/evidence/R5/DComp/native-contract.json`、`.local/dcomp-native/source-sha.json` | 限定 N PASS：7 个测试条目 | 包含实际隐藏 layered HWND 的 hardware D3D/D2D/DComp、借用 context、EndDraw/Commit、阶段失败与帧代次合同；不是实际 popup 上屏、WARP、Win10 或性能证明 |
| `.local/uia-native/source-sha.json`、同目录 harness | 限定 N/U：该次执行 50/50 | 包括 owned snapshot、队列、OLE medium/撤销生命周期；不覆盖其后非客户区 flags 修复，不代真实 OLE 拖动或 UIA 通知接收 |
| `E/contracts-07.log`、`roots-patches-07.log`、`package-07.log` | 定向框架/闭集/打包测试记录 | 139、85、48 项；打包记录另有 6 skip。后续源码/文档变化须重新核真源；不代完整 framework/ci |

必须保留的失败原件还包括 `windows-06` 旧全拼断言、`windows-11` SRW 编译失败、`windows-app-03` 缺 RDW 常量、相对隔离目录的 `windows-gui-01`、session fixture01—03 及 GUI/WSL runner 原失败。修复后的有限子集只关闭对应原因，不删除原证据。

## 3. R5 源码入口与剩余硬门

| 合同 | 当前可核源码入口 | 本轮证据与完整状态 | 仍需实现或补验 |
|---|---|---|---|
| R5-00 | `src/gx/ui_ref.zig`、`gui_settings.zig::Overlay.getAll`；W `ComApartment.zig`、`App.zig`、`Surface.zig`；K 生命周期钩子与 G `launch.zig` | 基础 U/N、标准 app 子集已有；完整 PENDING | init/OOM、hide/reopen、modal/COM 返回重查、shutdown、同 private state 多次启动及队列满等必须最终批次绑定；一条通路不代全部 owner |
| R5-01 | W `TabTransfer.zig::run`、`tab_transfer.zig::gesture/reparent`、`Window.zig::moveTabToNewWindow/moveTabToWindow`、`Surface.zig::onReparented` | 源码及定向子集；真实完整迁移 PENDING | 15 DIP 严格边界、横向 10 DIP、混合 DPI、完整树/zoom/override/活动 pane、满 tab、SetParent 重入/回滚；迁移后关源窗，核 PID/birth/PTY/Surface/scrollback 不变 |
| R5-01X | `src/gx/remote_view.zig`、`remote_protocol.zig`、`remote_binding.zig`；W `Leaf.zig`、`Pane.zig`、`RemotePane.zig`、`RemotePaneUi.zig`、`RemoteSource.zig`、`RemoteCoordinator.zig`、`RemoteInput.zig`、`RemoteHost.zig`、`ipc/remote_frame.zig`、`RemoteChannel.zig`、`RemoteService.zig`、`ui/uia_remote.zig`；`wgl.zig::Context.present` GX-0043；`src/Surface.zig` GX-0044 | final-r2 两进程普通窗口迁移、远程输入、混合分屏、目标崩溃恢复 native 7 项与 4 图 `PASS_SCOPED`；完整 PENDING | 普通窗口的 Leaf 混合树、目标交互与源端绑定续延已接线，`RemoteInput` 转发物理键、文本、IME、鼠标与 protected paste 分块；10:00 后的 runtime helper 修改未编译。仍缺：拖回原进程、混合标签拒绝跨进程、IME/OLE/MTA UIA/protected paste/搜索/确认在远程窗格上的真实场景，链式绑定 once/performable/断连取消，输入 ACK 丢失后查询，源进程故障显示与会话剪枝，DWM 上屏（非 PrintWindow）与输入到显示延迟 |
| R5-02 | `src/gx/session.zig`、`session_cwd.zig`；W `Session.zig::tryRestore/onQuit/onWindowClose`；G `session.zig::activate/quit/closing` | app04 两次 custom 恢复限定 PASS；GTK U 与接线；完整 PENDING | 两端多窗嵌套非 0.5 树、zoom/字号/手动标题/合法 cwd、失效 profile、CLI/initial-command、取消关闭、写失败、双 writer、Quick 排除及文件隐私。GTK 真 resize→close→restart 尚需独立场景 |
| R5-03 | W `ui/uia.zig::Publisher`、`uia_bridge.zig`、Popup/Palette/Menu/Settings/Dialogs/Toast 接线；`scripts/gx_win_uia.py` | root 外部 MTA 有限 PASS；popup 前台失败；完整 PENDING | 新非客户区去重修复的外部 MTA 复验；真实 popup Invoke/Selection/Value/Toggle/Expand、旧 provider inert、焦点/IME/modal 压力、Notification 真接收、读屏、Win10 缺 API。不能以 Show/notify HRESULT 代事件 |
| R5-04 | W `ole_drop.zig`、`drop_data.zig`、`ui/DropFeedback.zig`、Surface protected paste 与 App owned queue/延后撤销 | medium/注册/撤销原生合同；完整 PENDING | 外部受控 DoDragDrop 与 Explorer 真源、Unicode/文件/URI/多行保护、不自动 Enter、reparent/销毁。跨完整性 broker 已有生产实现：`src/gx/ipc/drop_broker.zig` 合同、W `ipc/DropBroker.zig` 专用管道、`DropBridge.zig`（高端预览确认后经 protected paste 回执）与 `DropCompanion.zig`（显式启动的 medium 接收窗口，核验目标 PID/birth 与映像）；普通 IPC 的 `policy.authenticate` 仍拒绝不同 elevation。尚无任何 broker 运行证据：VM 专用 `test/windows/gx_drop_broker_fixture.py` 的四权限方向矩阵、高端显式预览/取消/拒绝/过期/目标关闭回执均 PENDING；接收窗口目前只能由内部启动参数打开 |
| R5-05 | W `ShellIntegration.zig::initialize/notify/drain`、`shell/Identity.zig`、`WinRTToast.zig`、`ToastActivation.zig`；安装器/包装接线 | native/编码与 app02+构建子集；完整 PENDING | VM 实际安装/升级/卸载、冷/暖激活、多目标 token、DND/禁用、关闭/Quick、多目录 identity；应用内 `ui/Toast.zig` 不代系统通知 |
| R5-06 | W `ipc/Instance.zig::elect`、Client/Server/Security；`src/gx/ipc/`、App 路由、toggle CLI | 普通 launcher/-e 有限 PASS；完整 PENDING | 多 launcher 竞争、ready 前崩溃、退出、冒名 endpoint、不同 root/build/class/install/elevation、重复 toggle、GUI 失败不得 success ACK；GTK D-Bus 真 quick 行为仍独立验 |
| R5-07 | `src/gx/fuzzy.zig`、`pinyin.zig`、`pinyin/inputs/0.15.0/`；`scripts/gx_pinyin.py` | 钉版输入与离线生成、定向算法子集；完整 PENDING | fresh checkout 离线全量再生成/许可随包，三 API 同路径、polyphone/ü-v/高亮边界，Windows 动态 tab/字体与 GTK GX 筛选实际读图；P4 不放宽 |
| R5-08 | W `shell/JumpList.zig`、`ShellIntegration.zig`；`src/gx/windows_argv.zig` 与 startup/profile 路由 | 实现与 native/编码子集；完整 PENDING | 真系统 JumpList 写入/点击、冷启动、removed profile、语言、路径引用、两目录不串台、Abort 保旧、portable 不自动注册；测试环境变量不能隔离系统列表 |
| R5-09 | `src/gx/fluent/{inputs,model.zig,paths.zig}`；`scripts/gx_fluent_icons.py`；W `ui/fluent_icons.zig`、D2D 与 Settings selected 图标 | 六个 MIT 官方输入、离线生成/几何子集；完整 PENDING | Windows/Linux 字节再生、许可包、真实多 DPI/暗亮/高对比/禁用/选择图、device/factory 资源域；系统 glyph 默认保留 |
| R5-10 | W `ui/dcomp.zig::Device/Backend`、`d2d.zig::Canvas.beginBorrowed/finishBorrowed`、`Popup.zig::paintComposition` | 隐藏 HWND native 合同 PASS；生产 GUI PENDING | `GHOSTTY_GX_POPUP_DCOMP=1` 明确 opt-in，默认 off；真 popup 的 reset/target/surface/begin/end/commit、先 legacy 补画、size/DPI/generation 首帧、IME/modal/销毁、Win10/WARP/NVIDIA/Mesa 区分、Fluent 共域及 P4 十对 |
| R5-11a | `src/gx/keybind_edit.zig::enumerate/parseValues/apply`；G `shortcut_editor.zig::present`、`app.zig` | GTK 模型与真实 UI 入口已存在；完整 PENDING | 真实录制及执行结果、table/chain/flags、prefix 冲突、下层 unbind、CLI readonly、失败草稿、外部编辑、取消/恢复，中英文暗亮截图 |
| R5-11b | `src/gx/launch_profile_edit.zig::apply/commit`；G `launch_profiles_dialog.zig::present`、`app.zig` | GTK 管理器实现；G16 原失败及修后 runner 原件均保留；完整 PENDING | CRUD/default/rename 引用影响、只读来源、删覆盖后下层重现、跨窗/重开同步、旧 shell 不重启、保存失败和外部编辑；打开窗口本身不代这些动作 |
| R5-11c | G `window_state.zig::install/restore/closing/quit`、session 生命周期、`window.zig::popupNewTabMenu` | 定向 U/接线；完整 PENDING | 真实 resize→close→restart、各轴 CLI、max/tiled/fullscreen 不污染、never/Quick/取消关闭；Wayland 不承诺 XY，需真 WM 环境 |
| R5-11d | G `split_transfer.zig::perform`，K window/split_tree 的空树收养与 listeners | G15 输出保留有限 PASS；完整 PENDING | PID/birth、Surface/PTY/scrollback 恒等，嵌套/zoom/连续移窗、旧窗关闭后 split/title/search 可用、OOM/回滚与迟到 focus |

**Windows 11a/11b 范围说明。** 原合同 R5-11 标题和四子任务明确为 GTK。当前 W `ui/Keybinds.zig` 是速查/查询录制并执行已有动作，未消费 `keybind_edit`；W `ui/Menu.zig::showProfileMenu` 提供启动、分屏和默认 shell 设置，未接 `launch_profile_edit` 管理 UI。因此不能声称 Windows 已有完整快捷键编辑器/profile CRUD；也不能把本次核查自行扩张为原合同没有的 Windows 新必过项。共享编辑模型测试不证明任一平台完整 UI。

## 4. 142 叶分组导航

以下覆盖原账本全部叶 ID 区间，不重新解释或删减叶内并列条件。每行的测试/场景只是导航，最终证据仍须回填原叶 `source/tree`、构建 receipt、命令退出码、raw 与已读图；整组 PASS 不得替代逐叶签收。

| 叶组与数量 | 当前源码导航 | 本轮可证范围 | 未关闭门 |
|---|---|---|---|
| R2-接口 .01—.06（6） | W Surface/Window/App/Popup；WGL；`src/gx/settings_map.zig` | Windows 定向 U/N；无完整跨模块最终 G | V3/V6、P4/P7 |
| R2-App .01—.11（11） | W `App.zig::performAction/ringBell`、shortcut_conflicts；GX profiles/url_policy | 单实例与 session fixture 仅所列路径；Shell 系统场景未验 | V1/V2/V6、P1/P2/P4 |
| R2-Window .01—.13（13） | W Window/split_layout/caption_layout；GX window_state | 标题/session 有限场景，不代真实移窗/多屏 | V6、P2/P3/P7 |
| R2-Surface .01—.09（9） | W `Surface.zig::readClipboard/confirmClipboard/onReparented/awaitResizeFrames` | OLE/UIA 生命周期 N 子集；真 IME/PTY/clip 链未签收 | V1/V3/V5/V6、P7 |
| R2-Render .01—.05（5） | WGL present/Device，OpenGL/Target，W App | app04 实际启动 GL；不是 alpha/reset/资源数证据 | V3/V6、P1/P7/P8 |
| R2-Tabs .01—.10（10） | W chrome/TabBar、tab_layout、Backdrop、Window | W01 只证标题覆盖子行为 | V3/V6、P2/P3/P4 |
| R2-Caption .01—.07（7） | W TitleBar/Backdrop/caption_layout/alpha/D2D | 自绘 UIA root 子证据，不代 DWM 像素/动画 | V3/V6、P4 |
| R2-Palette .01—.08（8） | W Palette/trigger；GX fuzzy/palette_history | 全拼 U；本轮 popup GUI 被前台 guard 阻断 | V6、P4/P6 |
| R2-Settings .01—.11（11） | W Settings/settings；GX settings_map/config_layers | 源码/模型与 Fluent 接线；本轮自绘设置图 PENDING | V6、P4/P6 |
| R2-Menu .01—.06（6） | W Menu/MenuPopup/Popup | UIA/DComp 基础不代实际菜单；W16 原 expect 仍需对齐真实右侧锚点 | V6、P4 |
| R2-Dialogs .01—.04（4） | W Dialogs/Surface；GX confirm | app04 原生 custom 恢复确认有限 G；不代其他确认流 | V1/V6 |
| R2-Keybinds .01—.06（6） | W Keybinds/shortcut_conflicts；GX shortcuts | 现为速查表；未签收 hover 时间/布局计数 | V6、P5 |
| R2-Find .01—.05（5） | W SearchBar/LinkPreview/ResizeOverlay/Surface/Window | 当前批次 U 仅实现子集；无本轮全搜索 GUI 证据 | V5/V6、P7 |
| R2-Scrollbar .01—.04（4） | W Scrollbar/Surface | 隐藏/reparent 基础接线；无拖窗零重画实测 | V5/V6、P3 |
| R2-Quick .01—.08（8） | W QuickTerminal/Window/Surface/Popup | IPC/toggle 基础不代动画/焦点/最后 tab | V6、P1/P7 |
| R2-Font .01—.04（4） | DirectWrite discovery/warmup；`src/App.zig::create` | 原已合源码保留，不重新审实现 | C6/V6，96 DPI 真图与独立十对 |
| R3-Style .01—.06（6） | G style/style.css/window；GX gtk_css | G05/G08 软件 Xvfb 的有限图 | V7：modern/Wayland/材质/真实 DPI |
| R3-Settings .01—.06（6） | G settings_dialog；GTK 1.5 Blueprint；GX settings_map | GTK 定向 U；不代全部保存/语言/fontdialog | V7、P4/P6 |
| R3-Window .01—.06（6） | G window/menus/shortcuts/launch/language/app/about | G08 菜单条目及 G15 输出有限图；G16 管理动作待验 | V7、R5-11 |
| R3-AppMode .01—.04（4） | G app_mode/progress；GX unread/leader | 源码已有；本轮无完整 idle/进度计数 | V7/P2；原 Dock 进度延期语义保留 |
| R3-Upstream .01—.03（3） | K close_confirmation_dialog/application；G confirm；OpenGL GX27—29 | GTK 构建/U 不代 hardware DMABUF/真实确认 | V7/P9 |

## 5. C、V、P 原硬门保留

### 条件决策 C1—C8

| 项目 | 源码/研究入口 | 本轮证据状态与补验要求 |
|---|---|---|
| C1 | 原计划三冻结 GTK measurement 树、`scripts/gx_perf.py` | PENDING。账本没有本轮完整 40 loads；保留既有 quiet BLOCKED、0/40、DATA_VALID=false。两批各十对完整交替，quiet 不满足就结束本次尝试，不能借本轮 Debug GTK 图或构建改判收益 |
| C2、C2-G | GX defaults、WGL present、shell integration | PENDING。96 DPI 的 padding/cursor/alpha/freetype/CJK 实屏比较及 GTK prompt 光标来源尚未形成逐项采纳/拒绝；不预改默认，不由 C1 cairo 推导 |
| C3 | `src/os/mouse.zig`、`src/Surface.zig` 配置消费 | PENDING。系统双击值与空 config、显式 350 ms 覆盖的真实点击合同；不更改用户系统设置 |
| C4 | Exec/renderer Thread 的 spawn | PENDING。quiet 下 1/11 终端真实 commit 增量与栈压力；WorkingSet/reserve 不代提交量，不无证压 stack |
| C5 | K `application.zig::setGtkEnv` | PENDING。Ubuntu 4.14 与现代 GTK 下实际软件设备、GSK 默认/cairo/ngl 对照及用户环境优先 |
| C6 | DirectWrite `discovery.zig::warmup` | PENDING。同 current 代码仅切 warmup 的公平十对、冷/热字体及首帧；旧 A/C 结果不代最终判断 |
| C7 | GX cursor_blink、renderer Thread/cursor | PENDING。1/11 终端、可见/失焦/最小化、blink 两相位、IME/输出再唤醒及独立动画；不能由单测推 CPU 收益 |
| C8 | GX environment、GTK environment、Config vsync doc | 源码已实现，最终合同 PENDING。用户值追加去重、GTK<4.16、WGL vsync、MDX/CLI 全文尾项 |

条件项可以有据“拒绝优化”，但只关闭对应决策；证据不足继续 PENDING，不删除实验成果。

### 关键验证 V1—V7

| 项目 | 当前入口 | 未被本轮子证据满足的硬门 |
|---|---|---|
| V1 | Exec→ConPTY→parser/core→W Surface clipboard/确认→PTY | 已知安全测试剪贴板下真实 BEL/ST 回复、allow/deny/cancel、empty read/write、split remember、Quick/reparent/关闭竞态；不读或备份未知剪贴板，不用私有消息或 codec 代完整链 |
| V2 | W App bell 路由、BellAudio | 实际 BEL/command_finished 配置、gain 0/.5/1 与听觉、永久驱动不返回的资源收尾；不调系统音量 |
| V3 | W alpha/Backdrop/TitleBar/TabBar/D2D、WGL→DWM | NVIDIA/Mesa 可见 default framebuffer/Swap/DWM、低 alpha、亮暗/高对比、混合 DPI、recreate/failure 补画；DIB/隐藏 HWND 不代证 |
| V4 | GX bell_border、W Surface、WGL | 两后端可见四角 192 DPI/跨屏、repeat/clear/hidden/reparent/idle；Windows-14 的 5 skip 不能算通过 |
| V5 | core search/terminal search、W Surface/Scrollbar | F3/ShiftF3/Enter 实际 viewport 变化、满 scrollback 裁剪和持续输出不误揭条、右缘仍可唤出 |
| V6 | W App/Window/Surface/QuickTerminal/Popup | 长 IME/候选定位、Win10、真实混合 DPI、native退路、Quick 还焦/末 tab、首帧/共享16 ms deadline、真实 TDR 与迁移后继续交互；标题或 session 单场景不代全链 |
| V7 | G style/settings/window/app_mode/launch 与 K hooks | Ubuntu4.14/Adw1.5 和 modern≥4.16、Wayland/WM、原生 pinch/IME/全屏/字体/语言/来源、xdg handler；硬件 DMABUF export→GDK import 单独验，Xvfb 不代证 |

### 性能 P1—P9

所有项目均缺本轮完整最终比较。P4 的历史 FAIL 必须保留；本轮功能测试、截图或单次启动时间不折算为有效十对。

| 项目 | 原门与源码入口 | 必须补交的数据 |
|---|---|---|
| P1 | 启动显示比基线改善 **>100 ms**；App/WGL/首帧 | 公平旧新完整交替十对，实际进程起点和 visible，median/p90 |
| P2 | 进程快照每 2 s 至多 1 次，最小化 0；GX proc 与共享 AppMode | 1/11/多标签、全应用总计数，非单局部日志 |
| P3 | 三窗口各 15 tab 拖窗，scrollbar 重画 0 | 真拖动、活动/后台标签计数与 screen |
| P4 | Palette/Menu/Settings 热路径 ≤1 帧且无 PATH 扫描 | 保留原 160 Hz=6.25 ms 门；完整十对。DComp 实验和 Fluent 组合另列成本，不能改成 60 Hz 门 |
| P5 | Keybinds hover 每帧 CreateTextLayout≤10、绘制<2 ms | 真实 hover、布局计数和 ReleaseFast 时间 |
| P6 | 连续↓浏览主题 2 s，reload 恰一次 | 两端实际按键过程及 reload 计数，非计时器单测 |
| P7 | resize 等帧 timeout 下降，无黑边/拉伸 | 同窗口/网格的旧新真实 resize 帧，保留全窗16 ms deadline |
| P8 | Windows 每 terminal 实际渲染目标 6→2 | 实际资源/显存计数，非配置常量；GTK 仍保留3帧 |
| P9 | GTK DMABUF warn一次、renderer CPU下降 | 标准十对及真 export/import 计数；缺扩展不是 hardware success |

跨 host 另记 BGRA 传输成本与输入到显示延迟，不能用源单进程渲染时间代替。性能窗口前必须停所有 owned 重型构建、测试、安装和 VM；不控制未知进程。

## 6. 补验入口与最终集中门

以下是**待执行入口**，本文没有运行。先核当时 source/build receipt、实际测试名、资源槽及权限条件，稳定批次合并 filter；不能把这些命令机械地全部重复跑一遍。

- 模块定向：`just test --filter apprt.win32 --filter gx.session`，或实际受影响的新模块过滤器；GTK 用 `just wsl test --gtk --filter <实际名称>`。完整运行期筛选和 seed 以相应批次 JSON 的 `build/filters/reproduce` 为准；零命中不计通过，`--no-build` 需身份一致。
- 原场景：Windows `just win-gui run --out <新的绝对隔离目录> W01 ... W20`；GTK `just wsl scenario --out <目录> G01 ... G16`，另保留外部 BellBorder 与所有 R5 场景。不要为了填 142 行机械创建 142 个场景。
- final-r2 之后的最小 GUI 补验（新编译后、身份一致时）：W07 按改写后的非模态 Notice 场景重跑并读 `notice`、`split-with-notice`、`after-close` 三张图；W14 复验预览修复；W16 复验首项高亮并逐图签收（三项源码 root 已修，待本批编译）；BellBorder 与粘贴守门的修复按影响面补外部 BellBorder 与 W08；W06 需 `--allow-side-effects`，会打开默认浏览器访问 `http://127.0.0.1:9/`，未获许可时保持 SKIPPED；其余 W 场景读图前记 PENDING。G01—G16 的旧图已限定 PASS，新 GTK 快照只按影响面重跑。
- 远程窗格：`test/windows/gx_remote_fixture.py`（需显式开启远程测试钩子的冻结 exe）已覆盖两进程迁移、输入、混合分屏与目标进程丢失；拖回、混合标签拒绝、源进程故障与远程窗格上的 IME/UIA/OLE/protected paste 尚无夹具步骤，补齐前不签 R5-01X。
- 跨权限拖放：`test/windows/gx_drop_broker_fixture.py` 只在 VM 中按模块文档的 setup/target/drop 顺序、从同一用户同一会话预开的 medium/high 控制台运行；它不提权、不用 Explorer、不改 UIPI、不读剪贴板、不发 Enter。
- Session/IPC：`test/windows/gx_session_ipc_fixture.py --help` 后选择真实新证据批次；同私有 state 多轮恢复仍须每轮核 PID/birth/exe。已有 custom 子场景与其他 session 门分别签收。
- UIA/DComp：`test/windows/gx_popup_uia_fixture.py --exe <标准exe> --sha256 <构建后实际哈希> --out <新绝对目录> --build <批次>`；`--readonly-root` 只签 root/window/pane MTA 层；`--capture print` 只能诊断，不签 GL/DComp 上屏。脚本内部统一 heavy→desktop；前台/点位失败停止并保留 FAIL，逐张读 `visual-review.md` 指向的图。
- 系统功能：`scripts/gx_windows_vm.py` 管理的 Win11 VM 已实际 KVM 启动、官方 ISO 验证并到登录界面；证据在 `.local/evidence/R5/VM/`。普通/管理员身份及策略、Win10、安装/升级/卸载、通知/JumpList、OLE 四权限方向仍 PENDING。完整 VM 启动不证明其 GL 能力，先核实际 app 后端。
- OLE 专用入口：`test/windows/gx_ole_fixture.py` 与其受控外部 source；以当时 `--help`、已冻结 app/source 哈希和自有窗口守门执行。首个 text 失败在上表，后续正常权限真实成功也不能替代跨权限 broker 与四方向验收。
- 最终冻结只集中一轮：Windows main `just test`；Windows VT/framework/fmt 由一次 `just ci-check` 提供，避免另重复同样完整套件；独立 POSIX main、GTK main 各一次。单独标准 app build、`generated-check`、webdata 全文尾项与真实 CLI/help/error；VT/C ABI/wasm 按真实影响补充。
- R6 文档收口（2026-10-14）：本索引、执行计划、交接计划、`GX_FEATURES.md`、`TESTING.md`、CHANGELOG `0.0.3(TBD)`、`FORK_PATCHES.md`（38 个 ID，GX-0044 形状锁 `Gx0044ShapeTests`）与 apprt-win32/gx-core/app-core 规则已按源码更新；三个 Windows 过渡 shim 已删除。源码和文档冻结后由 owner 统一生成 i18n/pinyin/Fluent/KB/graph 并审 diff；这些文档改动会让 KB 过期，不能沿用此前 freshness。文档任务只跑了 `test_fork_patches`、`version.py --check` 与 resolver `--check`，未生成、未跑 Zig 测试或构建。
- 最终逐叶需要完整身份、命令退出码、raw 单位/n、读图判定与缺证原因。本地阶段 commit 已获授权（精确暂存、不 push）；commit 只保存可审的工作，不代表任何门通过。全部必需功能和门满足前，`tasks.json` 与最终交付继续 **not_complete**。
