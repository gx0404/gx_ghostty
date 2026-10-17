# GX UI 当前执行计划：单对话原生子智能体、集中验证、R6 收口

本计划依据当前对话 2026-10-14 的授权与 2026-10-17 的模型分工更新，覆盖旧交接文档的任务组织、构建频次和提交授权；功能范围仍是 F1–F10，原完整验收契约（`docs/GX_UI_REMAINING_PLAN.md`）中的门不因本计划而视为通过。原定截止北京时间 2026-10-14 02:48 **已超期**，如实保留，已用时间不清零。当前总状态 **`not_complete`**。

## 授权与组织

- 只派当前会话的原生子智能体，同时活动上限 10 个；不建独立对话或后台 CLI 会话，不恢复已归档的独立对话；当前对话里已完成的原生子智能体按需 followup 复用。子智能体直接指定 `model`、`reasoning_effort` 与 `fork_turns:"none"`，不改客户端配置。
- 模型（2026-10-17 用户更新）：中等及以上复杂度任务默认用 `gpt-6-astra` `xhigh`，包括跨模块接线、系统集成排障、跨进程生命周期、协议与绑定续延；边界明确的简单实现、简单修复、常规夹具和文档用 `claude-opus-5-5` `xhigh`；清单、哈希、映射、证据 JSON 等机械工作用 `deepseek-flash` `max`。按任务实际复杂度分配，不仅按文件类型分配；简单任务出现多模块或系统行为不确定性时转交 Astra。DeepSeek 的 fresh 明文探针已返回 `DEEPSEEK_PLAINTEXT_OK`；探针或创建成功不等于该模型的产出已验收。
- 全机重型任务（构建、完整测试、VM、性能）最多 3 个；同一工作树的构建串行，构建期间冻结相关源码；宿主桌面独占，GUI 与性能不并行。
- Windows 与 GTK 完整 main 各已运行一次（final-r2），不再重复；新编译后只重跑受影响的定向测试与场景。打包不重编，翻译、KB、图谱在源码与文档冻结后各生成一次。
- 用户已授权把全部已有与新增改动做本地阶段 commit，无需逐次确认：精确暂存、提交信息按根 `AGENTS.md`「提交规范」。不 push、不建 PR/Issue/tag/release、不新增下载，不触碰 `GX_API`。
- 主树按文件单写者工作；所有权按文件显式移交；状态经原生消息回传，不共写状态文件。文档、CHANGELOG、补丁登记与证据导航由文档工位独占，证据 JSON 由机械工位维护。

## 当前状态（2026-10-17 核对）

- 已有本地阶段提交：`8a2b4bb59` 保存整体实现，`de3149e1f` 修 GTK 恢复泄漏，`03c8e138f` 隔离 VM 单测并核验容器归属，`c9dd5eb7c` 修 ReleaseFast 远程粘贴事务身份，`ff41652c2` 修远程取消、映射替换和退出清理，`b0de75a1b` 补远程压力与焦点时序夹具，`84671b9b6` 修通知激活器快捷方式 GUID，`f55771d84`、`432f91eb4` 补 VM 关闭结果、拖放源与指针模式，`3aeb28f15` 让拖放接收器以关联令牌启动。HEAD 为 `3aeb28f15`，产品源码无未提交改动，工作区只有文档与生成物；提交不是验收通过。2026-10-17 机械核对（`final-r2/identity-20261017.json`）：`src/**` 1223/1223 与 r4 构建前快照一致，r4 app/setup/zip 与 r3 test-bin 哈希全部匹配，无需重编。
- 当前最终候选为 `zig-out-delivery-r4/bin/ghostty.exe`，SHA256 `eece67e02e54823a8336849359776c86fe1195c1fef4d721c146f40013c37e90`；离线包 setup `de2a810188d84c94dabad61719dea320f0144b9ea36584be11f637264013c9ea`、zip `9d440ea5…fc25f`。r4 相对 r3（`95d7a015…8eba`，合并构建与 50 项定向通过）只把接收器启动令牌权限由 `0x0B` 改为 `0x18B`，r3 的测试、远程与 GUI 证据只覆盖未改动的逻辑，按范围复用，不计为 r4 的新测试结果；令牌权限改动由 VM 四组令牌对照与接收器配对实证覆盖。Toast 诊断 app `435c87aa…236e` 不作最终包，四个诊断源码文件已精确撤回（补丁留存），源码与 r4 清单一致。此前 `cc2edbc9…663f76` 的已验范围独立保留。源身份以构建时 HEAD 加文件摘要为准，不因后来提交而改写 receipt。最新已验 GTK 快照为 `38e3e644f`。
- 完整 main 已各运行一次：Windows 5017 总、4942 PASS、73 SKIP、2 环境 FAIL（符号链接权限）；GTK 4533 总、4480 PASS、53 SKIP。历史 W0 的 161 项和误混旧二进制的 226 项不冒充新证据。
- Windows 后续 103 项受影响测试通过；RemoteInput 的真实源码小入口 Debug/ReleaseFast 各 7/7，真实安全粘贴子集 9 项和 4 图通过。W06/W07/W14/W16 修复批次 19 图已读；本轮 session/IPC 4 组、7 图以及 W20 的 23 步、6 图通过。Popup UIA/DComp 21 项原生检查、13 图已审阅，范围限制见证据索引。
- GTK 生命周期 38/38、20 图通过，两次退出码均为 0；迁移后原 PID/birth/PTY 不变，恢复确认、临时命令跳过及几何恢复均有证据。恢复探针 6/6 与 7/7，受影响 G15/G16 通过。Xvfb 不代 Wayland/IME/硬件验收。
- r3 已复验三个远程修复：取消后输入正常，目标丢失后回收并退出 15/15 为 0，连续 330 次分屏与布局变化未再出现非预期断连。52 张图已读完（含 15 张历史夹具失败图的独立判读），另有 root 和 Opus 抽查；旧失败原件保留。Win11 接收器的 1346 已修复；后续访问拒绝由四组真实令牌权限对照确认只有 `0x18B` 成功。r4 安装版经提权窗口菜单启动接收器，host 10180 与 receiver 8260 双向关联认证 PASS（high/medium 登录会话互为 linked，同 SID、同会话）；这些 PID 是 10-14 的历史记录，不代表今天仍在运行。实际 DoDragDrop 的高端预览、取消/允许回执与不追加回车仍 PENDING。
- VM 曾被未隔离单测误操作，异常关机原件保留；真实磁盘未丢失。单测与容器身份检查已修复。GL 关闭探针已确认窗口和请求正确；历史“正常关闭”漏查退出码，实际含与宿主相同偏移的 `WM_QUIT` 清理崩溃，结论已作废。r3 的三次关闭均退出 0；渲染图本身仍只证明渲染。
- Win11 系统集成：r3 安装 exit 0 后卸载 exit 0，五组注册表键与应用目录均不存在；r4 安装 exit 0 并核对 app 哈希。JumpList 用键盘打开，选择启动配置在同一进程（PID 2912）新开窗口，PASS。系统通知的原生同 AUMID 探针、诊断版与 r3 原版重启对照都显示了横幅；早期三次 OSC 未显示仍记 FAIL，原因不明，不宣称诊断日志修复了它。通知冷热激活与 r4 最终卸载残留 PENDING。
- 2026-10-17 已重新启动 Docker，并复用原 Win11 容器（`a8771d3f…`，此前 exited 255，live UUID 匹配），heavy 由 session 9120 持有，当前由 Astra 负责 GUI 验证；10-14 的客机 PID 一律不视为在运行。
- root 当前 `just framework-check` 936 项、17 skip、exit 0。KB 已重新生成且 fresh，本轮文档修改会让它再次过期，由 root 最终统一生成。

## 功能状态

| 项 | 源码 | 现有证据 | 状态 |
|---|---|---|---|
| F1 混合树与 Session 剪枝 | `Leaf`/`Pane`、Window、TabTransfer、Session | 拖回、再迁移、混合标签拒绝、本地部分恢复及原终端身份已有实证 | PASS_SCOPED：回收后退出 15/15，正式签收 PENDING |
| F2 远程视图与输入 | RemotePane、RemoteInput、key_translate | 原 shell 输入、IME、OLE、安全粘贴、鼠标选择复制通过 | PASS_SCOPED：取消后正常输入，原失败已复验 |
| F3 协议与状态 | remote_protocol、RemoteSource、RemoteCoordinator | 协议与输入队列定向；330 次布局变化无非预期断连 | PASS_SCOPED：原生与全部附加压力图已审阅 |
| F4 绑定续延 | remote_binding、GX-0044、RemoteSource | 链、once、普通 performable 回退及 cancelled 语义有单测和真实回放 | PASS_SCOPED，完整矩阵仍按证据索引 |
| F5 目标交互 | RemotePaneUi、UIA、OLE、菜单、搜索与剪贴板 | 外部 MTA、真实 OLE、弹层及部分确认通过；取消状态已在 r3 复验 | PASS_SCOPED：完整平台矩阵按批准延期 |
| F6 broker 与 shim | DropBroker、DropBridge、DropCompanion | shim 已删除并构建；认证/回执定向通过；r4 安装版接收器启动与双向配对通过 | PENDING：实际 DoDragDrop 的预览、取消/允许回执与不追加回车 |
| F7 GTK 生命周期 | GTK GX 生命周期、迁移、session 与编辑器 | 38 项生命周期、20 图、原 PTY、双退出与重启通过 | PASS_SCOPED；Wayland/IME/硬件保留 PENDING |
| F8 Win11 系统集成 | ShellIntegration、shell、安装器 | 登录、真实 medium/high 配对、Mesa 渲染预演；r3 安装与无残留卸载、r4 安装、JumpList 通过；通知显示对照通过 | PENDING：通知冷热激活、r4 最终卸载残留；早期三次 OSC 未显示保留 FAIL；升级延期 |
| F9 文档与生成物 | R6、GX-0039～0044、671 条翻译、142 叶映射 | 补丁与测试根检查通过；framework-check 936 项（17 skip）exit 0；映射保留正式 PENDING | PENDING：文档冻结后由 root 统一重建 KB/图谱并复查 |
| F10 条件实验与性能 | C1–C8 保持默认；DComp 实验默认关 | 无新样本 | PENDING；P4 保留既有 FAIL 至重测 |

## 接口冻结（仍有效）

- `Window.adoptRemoteTab(at, description, panes)!refs.Reference`：RemotePane 由远程侧创建，Leaf 与树由 Window 创建，仅成功后转移所有权；`leafForPane`、`activeLeaf`、`removeLeaf`、`onLeafStateChanged`、`describeTab`、`performUiAction`；App 提供 `resolveLeaf`、`resolveRemote`、`visiblePanes`。
- `RemoteCoordinator.sendToSource/sendToTarget` 按 source 稳定引用找已认证连接；`RemotePaneUi.handlePacket`、`performBindingAction` 的返回值只表示真实结果。
- 协议 v2：两端共享规范动作文本；请求与结果携带 surface、lease、transaction、config_generation；快照文本有界（60 KiB），不按值扩张队列槽位。源持有终端与绑定状态，目标持有可见 UI。
- 语义：源丢失不重放命令；目标退出归还源；纯远程标签可拖回源，混合标签禁止跨进程迁移；all/global 只作用目标可见窗格；Session 不保存远程叶；Quick Terminal 拒收远程。粘贴单块受协议上限约束、总量不超过 16 MiB，不追加 Enter。模态返回后重查稳定引用。

## 余下批次与补验入口

原定构建/打包次数已因真实系统缺陷超出：r3 合并 app/test-bin，r4 仅 app 热修，以及单独 Toast 日志诊断 app；r3/r4 各打包，诊断 app 不作为最终包，其源码改动已撤回。未追加完整 main。已生成的 KB/图谱在真源再变后需重验新鲜度，按实际影响补生成，不把旧产物冒充最终冻结结果。

1. 剩余 broker 拖放、通知激活等系统集成排障，以及中等或复杂的修复与接线交给 Astra；既有远程修复证据保留，不重做。Opus 承担步骤明确的简单夹具、常规 GUI 回放和文档，DeepSeek 整理证据映射；root 统一测试根、构建和接口裁决。按文件单写者并行，空闲工位复用，不增独立对话。
2. 已完成：r3 合并构建一次 `install test-bin`，受影响并集 50/50（seed `0x52553301`）非零命中，未重跑 main。r4 只改启动令牌权限，不再重编测试；r3 结论不计为 r4 新套件结果。
3. 已完成：r3 复跑受影响远程子集（取消后正常输入、330 次 split/resize、目标丢失回收 15/15 干净退出），52 图已读并以旧失败原件对照；W09/W12 增强后复验通过。
4. 不改变 GTK 生产路径的 Win32 专用修复复用 `38e3e644f` 证据；若共享修改实际影响 GTK，再补对应编译与定向。不得因 commit 或文档变更全量重编。
5. r4 已离线打包（不加 `--build`）并安装；r3 卸载无残留，JumpList 与接收器配对通过。余下 VM 工作交给 Astra：实际 DoDragDrop 的高端预览、取消/允许回执与不追加回车，同用户其余权限方向按批准计划执行；通知冷热激活（只看到横幅不够）；r4 最终卸载与残留核查后停止自有 VM。Win11 卸载属于本次功能门，不延期。早期关闭探针先明确请求是否送达，不能以超时猜产品根因。
6. 文档与真源冻结后用生成器重建 KB/图谱；译文未变不重复生成。集中 `framework-check`、`fmt-check`、`generated-check`、`git diff --check`，聚合门公共子项不重复执行。原 `ci-check` 的 VT、独立 POSIX、Win10/升级、硬件/性能/macOS 与正式 142 叶签收按已批准延期表保留 PENDING；P4 保留既有 FAIL。

每项逐条记 PASS / FAIL / PENDING / BLOCKED / N/A 并附原件；未运行项写补验命令与理由，不写假绿。
