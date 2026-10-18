# Windows Tests

Manual test programs for Windows-specific functionality.

## test_dll_init.c

Regression test for the DLL CRT initialization fix. Loads
ghostty-internal.dll at runtime and calls ghostty_info + ghostty_init to
verify the MSVC C runtime is properly initialized.

### Build

First build ghostty-internal.dll, then compile the test:

```
zig build -Dapp-runtime=none -Demit-exe=false
zig cc test_dll_init.c -o test_dll_init.exe -target native-native-msvc
```

### Run

From this directory:

```
copy ..\..\zig-out\lib\ghostty-internal.dll . && test_dll_init.exe
```

Expected output (after the CRT fix):

```
ghostty_info: <version string>
```

The ghostty_info call verifies the DLL loads and the CRT is initialized.
Before the fix, loading the DLL would crash with "access violation writing
0x0000000000000024".

## r6 边界夹具

下面的基础入口保留兼容。第二轮新增的完整 controller、消息表和 VM 触发命令见
「第二轮原生边界控制」；相同 case id 优先采用第二轮入口。

仅在隔离目录、已冻结 exe/hash、`Get-UserIdleSeconds >= 600` 且 root 持有
`Invoke-Desktop` 时运行真实 GUI。所有 Python 夹具支持 `--desktop-held`：该参数只表示
调用者已经持锁，避免在主仓集成后重复获取同一把锁；它不会获取桌面许可。
每次用新的 `--out`。守门失败立即停批，保留原报告。不要对未知剪贴板做备份、覆盖或恢复。

```powershell
. E:/gx_projects/gx_ghostty/.local/tmp/agent-env.ps1
Set-Location E:/gx_projects/gx_ghostty-wt/r6-a3-fixtures
$app = (Resolve-Path zig-out-a3/bin/ghostty.exe).Path
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $app).Hash
$run = "$F3/A3/run-$(Get-Date -Format yyyyMMdd-HHmmss)"
if ((Get-UserIdleSeconds) -lt 600) { throw 'PENDING: 用户空闲不足 600 秒' }
Invoke-Desktop python test/windows/gx_session_ipc_fixture.py --desktop-held --exe $app --sha256 $hash --out "$run/session" --build-label coordinator-frozen --case roundtrip
```

命令中的 build label 不能代替构建 receipt。`gx_fixture_evidence.py` 记录 PID、创建
FILETIME、exe 路径/哈希、HWND、core id 与 PTY 子进程身份；没有原生 scrollback 查询时
明确保留 `scrollback_count=null / PENDING_NATIVE_COUNTER`，不得把它算作恒等证明。
每个 case 的 `reviews/*.json` 绑定截图摘要，默认 `PENDING_REVIEW`；运行器不覆盖人工判读。

| 稳定 case id | 入口/参数 | 边界及限制 |
|---|---|---|
| MIG-01 | remote `--only drag-threshold` | 基础竖向探针；第二轮起 controller 同时检查横向 drag-active。144 DPI 下 15 DIP=22.5 px，22/23 px 不冒称恰 15 DIP |
| MIG-02/MIG-02b | remote 默认 transfer/dragback | 基础单叶探针；完整嵌套树、zoom、override、原 PTY/history 使用第二轮 controller |
| MIG-06a/b/d | remote `--only performable --only once --only table` | 实际 shell marker 验证 fallback、once 与持久 table；chain 走默认完整序列 |
| PERF-REMOTE-01 | remote `--only perf-input --perf-count 50 --perf-interval-ms 200` | 两端 `GHOSTTY_GX_PERF=1`，真实逐字符输入、不回车；由 root 的 quiet 批次汇总 `remote.input_to_present`，夹具不判性能门 |
| SES-01 | session `--case roundtrip` | 两窗、每窗两 tab、0.3125/0.6875 嵌套树、后台 zoom/active、字号、中文/emoji override、合法 cwd，两轮新 PID/birth；生产快照逐字段比较 |
| SES-02/03 | session `--case missing_profile --case priority` | 失效 profile、command/-e/initial-command 优先级、恢复不重放 initial-command |
| SES-04/05 | session `--case cancel_close --case write_failure` | 取消保档；只对私有 state 目录设拒写 DACL，先验证真实拒写、最终恢复原 ACL |
| SES-06/07/08 | session `--case dual_writer --case privacy --case quick_excluded` | 双 writer、字段白名单/隐私 marker、Quick 排除 |
| IPC-01/02 | session `--case multi --case race` | 普通 launcher 与 -e；6 个 suspended launcher 同批恢复、一个 host、其余退出码均 0；IPC-02h 新 controller 检查真实 RegisterHotKey 计数 |
| IPC-03/04 | session `--case crash_before_ready --case squatter` | ready 前自有 host 退出；同名不响应 endpoint 预占。若暂停时已创建 GUI/PTY，IPC-03 记 PENDING；IPC-04 不代有效伪造 hello 认证 |
| IPC-05 | session `--case roots` | 配置根隔离；build/install/token/session/account 各维度另验 |
| UIA-01/02 | popup `--mode off --actions` | 外部无 HWND MTA 调用 Invoke/SelectionItem/Value/Toggle/Expand；Palette hide/reopen 后保留旧 Value provider 实际调用必须不可用 |
| OLE-01/02/03/04/05/06 | ole `--case unicode/single_file/files/shell_metachar_files/quoted_path/uri/multiline/unterminated/bad_hdrop/bad_uri/text_limit/too_many_files`（每项独立 `--case`） | 真实 DoDragDrop、释放计数、源文件摘要保持；引号路径是明确的恶意合成 HDROP，Windows 不存在引号文件名；COPY 仅准入、粘贴与无 Enter 必须读图 |
| BRK-01/02/03/04 | broker `receipt --expect rejected/expired/target_gone/cancelled` | VM 同用户 medium/high 拆分令牌；PID/birth 过滤真实完成回执。第二轮已加入门控 diagnostic；旧 app 缺 diagnostic 不能把截图或 OLE COPY 当 ACK |

remote 参数仍需 `--exe --sha256 --out --build`；popup 同样；ole 需额外
`--source <gx_ole_source.exe> --source-window`。OLE source 的构建命令：

```powershell
Invoke-Heavy python scripts/zigw.py build-exe test/windows/gx_ole_source.zig -target x86_64-windows-gnu -lc -lole32 -luser32 -lkernel32 -lshell32 "-femit-bin=$F3/A3/gx_ole_source.exe"
```

UIA 工具的 `--action-plan <JSON>` 支持精确 `automation_id` 或唯一 `name`，加
`pattern` 和 `operation`；Value 使用 `value`。每个动作必须带 exe SHA-256。
`--ready-file` 在保留 provider/完成通知注册后创建；controller 完成 hide/销毁/换子菜单后
创建 `--continue-file`，`after_signal:true, expect_unavailable:true` 的旧 provider 调用
必须返回 `0x80040201`。`--listen-ms --expect-notification` 必须实际收到事件；查询、注册、
移除线程 ID 记录在 `threads` 中。`--query-interval-ms 20` 在等待时持续查询，不创建窗口。
所有等待受父进程 timeout 限制；超时记 FAIL。

### VM broker 命令与预期

沿用本目录 `gx_drop_broker_fixture.py` 顶部的 setup/target/drop/inspect 流程，所有参数
用绝对路径与实际 hash；由 root 在既有 medium/high 控制台中执行，夹具不提权。

```text
medium: drop --root <private> --direction medium-high --case multiline --name BRK-04
high:   inspect --root <private> --name BRK-04
high:   respond --root <private> --name BRK-04 --popup-hwnd <实际HWND> --decision allow --stage broker-preview --x <已读图按钮X> --y <Y>
high:   inspect --root <private> --name BRK-04
high:   respond --root <private> --name BRK-04 --popup-hwnd <第二层HWND> --decision cancel --stage protected-paste
medium: receipt --root <private> --name BRK-04 --expect cancelled
```

BRK-02 对 text 的第一层预览 `respond --decision allow --delay-ms 31000`，预期 `expired`；
务必在 35 秒传输 deadline 之前完成点击，已超时应保留 unknown/FAIL。BRK-01 的 `rejected`
与用户取消的 `cancelled` 是不同结果，不能相互代证。BRK-03 应关闭所选 pane、保留 host
与另一 pane，再验 `target_gone`；杀整个 host 不代认证完成回执。第二轮的 `boundary`
子命令实现 rejected/target_gone 触发，见下文。权限/跨账户矩阵不能由同权限宿主代签。

离线验证：`python -m unittest discover -s test/windows -p 'test_gx_*.py'`，
`python scripts/run_unittests.py test_gx_win_uia test_fork_patches`。

### 第二轮原生边界控制

```powershell
# 同前文先核 hash、空闲 >=600 并使用新的 out；每次只跑一个 case，失败保留且不自动重试。
Invoke-Desktop python test/windows/gx_boundary_controller.py --desktop-held --exe $app --sha256 $hash --out "$run/MIG-05" --build coordinator-frozen --case MIG-05
Invoke-Desktop python test/windows/gx_boundary_controller.py --desktop-held --exe $app --sha256 $hash --out "$run/MIG-07" --build coordinator-frozen --case MIG-07 --remote-controls "$F3/A2r-fix/remote-controls.json"
```

| case | 实际 controller |
|---|---|
| MIG-01 | 按原生已绘制 tabRect 实际拖动；先在按键抬起时逐像素校准 SendInput 落点，再在同一次按下中跨越边界：阈值内一侧在 `GetCursorPos` 确认落点后等 ≥250 ms、隔 300 ms 读两次（横向 drag.active=0；纵向窗口数不变、无 move loop），越过一侧再等到 drag.active=1 / 新窗口 |
| MIG-02 / MIG-02b / MIG-03 | 多进程完整嵌套树、0.3125/0.6875、zoom、手动标题、活动 core；每叶先输出 200 行，再核原源进程隐藏宿主的 HWND/PTY PID+birth/history；拖回与实际 shell marker |
| MIG-02-local | 同进程跨窗合并与拆出完整树，经 CONTROL 3/4 直接调用产品 `moveTabToWindow` / `detachTabForDrag`（没有鼠标手势；手势见 MIG-04），核每个真实子 HWND 的父子关系和原 PTY |
| MIG-04 | Session 恢复 64 tab 目标与单 tab 源，两窗按主屏工作区并排、纵向居中且整窗可见（顶部附近拖动标题栏会出现 Windows 11 Snap 布局栏，先于目标拥有落点）；真实手势：在源 tab 上按下，纵向越过 15 DIP 触发产品 detach，等到源线程进入原生 SC_MOVE 循环（`GUI_INMOVESIZE`），沿途只经自有窗口移到目标 tab 栏后松开。断言手势前释放点最上层是目标、松开前记录 z 序命中、源窗随指针位移、门控计数 drops/full_refusals/merges 恰为 +1/+1/0 且产品记录 `fixture_transfer_target` 恰为目标窗的 `full`，目标仍 64、源树/core/PTY 保持；同一 controller 再删目标一个 tab 做正对照，同一手势必须 +1/0/+1、产品记录为目标窗 `local`，合入并保持完整树。未开“拖动时显示窗口内容”记环境 PENDING |
| MIG-05 | 每个叶位置的真实 SetParent 失败（已移动的 HWND 回滚）；WH_CALLWNDPROC 在实际 SetParent 内同步尝试嵌套迁移，检查事务拒绝而非停止 shell |
| MIG-07 | `--remote-controls <F3>/A2r-fix/remote-controls.json`：先轮询 capability 等于 magic，再取基线；先测无丢失时单字符的 input_applied 增量作对照，武装一次 ACK 丢弃后输入 x，要求 ack_dropped 恰 +1、input_query_count 增加、input_applied 增量与对照相同；原 cmd 的 `set /p` 输出文件恰为 `x` |
| MIG-08 | 迁移后关闭原普通源窗口（同样要 `--remote-controls`），capability 仍就绪；Ctrl+Shift+F 前切到美式键盘（结束恢复原输入语言），继续远程 split、search 与 wheel；远程 scrollback 三项（实时状态量，不当单调值）在底部满足 offset+viewport=total，wheel 后 offset 变小，并与源进程隐藏宿主本地 PageList 查询一致 |
| MIG-08-local | 同进程 CONTROL 3/4 迁移后关闭原源窗口，在拆出窗口 split、search（同样先切美式键盘并恢复）与 wheel，本地查询 search 计数与 offset 变化 |
| IPC-02h | 6 个 launcher 竞争，1 个 host、5 个 exit0；唯一 Ctrl+Alt+Shift+F24 持久热键的 attempt/success/live 都为1 |
| IPC-03 | 选主后、GUI/PTY/hotkey 前停在有界 native seam；只终止本夹具自启 host，secondary 必须非成功退出 |
| IPC-04b | 从自己启动的真实 host 取得 hello，关闭 host 后 FIRST_PIPE_INSTANCE 占同名管道；只改 hello 的 PID/birth 为实际 Python impostor，其他合法字段原样；要求 DifferentImage 拒绝、无 GUI/PTY |
| IPC-06 | 已就绪 host 一次 GUI 创建故障；真实 secondary 请求收到非成功退出，host 无新窗口/PTY |
| IPC-07 | CLI 通过真实认证管道重复发送同一 request key；先按 launcher PID/birth 断言日志恰有一条 `fixture_ipc_replay ... outcome=completed`（证明确实重发），再要求 host GUI toggle 与 execute 计数只增1，Quick 仍可见 |
| UIA-02 | 外部 MTA 保留 provider，分别 hide/reopen、换子菜单、销毁窗口；旧对象实际调用必须 0x80040201，不能操作替补对象 |
| UIA-03 | MTA 连续查询同时切兄弟 pane 焦点、真实中文 IME 组字、关 tab、开 menu、模态确认；无安装 IME 才属于环境 PENDING。切到已加载的中文布局后等 IME 状态 0.3 s 不变再保存（首读与时间线入报告）；组字只改必需项（开启、OR 上 NATIVE 位），每次写入等状态稳定确认后记入撤销表，finally 按相反顺序逐项撤销并确认，再恢复输入语言（app 已退出时经夹具自有窗口）。精确一致记 `exact`；保存态与结果都是关闭记 `closed-mode-not-comparable`（微软拼音关闭时清零转换模式，原始读数保留）；撤销未确认、开关或输入语言未恢复记 FAIL |
| UIA-04 | 注册外部 Notification handler 完成握手后，GUI native publisher 发固定测试通知；必须实际收到正文，query/register/remove 同线程 |
| OLE-07 | 用 `/n,/separate` 打开自建目录，Shell 确认是新增 HWND 且精确目录，UIA 找唯一自建文件后真实 Explorer drag；原生 Drop/queued 计数各增1；无论成败都在 finally 关掉所有新增且仍显示该私有目录的窗口（未归属成功时再观察 5 s 防迟到窗口），只关这些窗口，不终止 Explorer 进程 |
| OLE-08 / OLE-09 | `--ole-source <exe>`：真实 DoDragDrop 已进入循环/目标 hover 时 reparent 或销毁目标；取消后 effect NONE、没有落到替补 pane，资源 release 配对 |

### 测试消息与诊断登记表

`GHOSTTY_GX_REMOTE_TEST=1` 才响应；关闭时所有控制/查询返回0（DefWindowProcW），故障与计数不改变。
ID 只在同一 HWND 内唯一；新增前先查本表。GhosttyWindow 上 A3 的 CONTROL/QUERY：
所有句柄参数只在当前 App 的 live window/attachment 中解析，不接受外部裸指针。

| 消息 | wParam | lParam / 返回值 |
|---|---|---|
| `WM_USER+0x51` = `0x451` CONTROL | 0 | 清该窗口的迁移测试状态 |
| 同上 | 1 / 2 | 1-based SetParent 失败叶位置 / 同步重入叶位置；0 关闭 |
| 同上 | 3 / 4 | 当前 tab 合入本 App 的目标 HWND / 拖到真实空新窗，4 返回新 HWND |
| 同上 | 5 / 6 / 7 | 选择 tab / zoom node（-1取消）/ 活动 leaf node |
| 同上 | 8 | 经产品 `removeLeaf` 删除当前活动叶：多叶 tab 只删该叶；单叶 tab 删除整个 tab，若这是窗口唯一 tab 则窗口随之关闭（代码不保证保留其他叶/窗；OLE 销毁与 MIG-04 正对照前先确认还有别的 tab） |
| 同上 | 9 / 10 | 当前已发布 Window UIA root 真实 Notification / 生产模态关闭确认（10 用 PostMessage，controller 用 Esc 关闭） |
| 同上 | 20 / 21 / 22 / 23 | 下一次 newWindow 失败次数（<=16）/ 下一次认证 broker GUI admission 拒绝 / 删除 broker 当前绑定的目标叶 / 生产 addTab |
| `WM_USER+0x52` = `0x452` QUERY | 0 / 1 / 2 / 3 / 4 | magic `0x47584133` / drag.active / window id / active tab / tab count |
| 同上 | 5 / 6 / 7 / 8 / 9 | node count / zoom index+1（0无）/ active source core id / tab id / UTF16 手动 tab title Wyhash |
| 同上 | 10 / 11 / 12 / 13 / 14 | node kind（1 leaf、2 split）/ source core id / 子 HWND / parent HWND / local PTY PID |
| 同上 | 15 / 16 / 17 / 18 / 19 | ratio 的 f32 bits / axis（0横、1竖）/ left / right / local leaf 手动 title hash |
| 同上 | 20 / 21 / 22 / 23 / 24 / 25 | local terminal total/viewport/offset / 窗口 DPI / 本地或远程 search UI active / search total（未知-1） |
| 同上 | 30 / 31 / 32 / 33 | 已绘制 tab 的屏幕像素 x/y/width/height |
| 同上 | 40 / 41 | SetParent 内真实同步重入数 / 事务拒绝数 |
| 同上 | 100 / 101 / 102 / 103 / 104 / 105 / 106 | hotkey attempts/successes、GUI toggle、GUI IPC execute、剩余 window failure、当前持久热键数、实际 IME composition 消息数 |
| 同上 | 107 / 108 / 109 | App 级真实标签拖放：原生 move loop 结束后进入目标查找的次数 / 命中活着的满 64 窗口而拒绝的次数 / 本地合入成功次数；每次查找另记日志 `fixture_transfer_target outcome=full\|unavailable\|no_slot\|local\|foreign\|peer\|none hwnd=0x… pid=N class=<ASCII 类名>` |
| 同上 | 200 / 201 | 真实 OLE Drop 回调数 / owned payload 成功排入数 |

同进程其他测试消息（不归 A3，均须同一门）：

| 窗口类 | 消息 | 用途 / 所有者 |
|---|---|---|
| GhosttyWindow | `WM_USER+0x4f` = `0x44f` / `WM_USER+0x50` = `0x450` | `remote_test` 远程迁移 BEGIN（wParam 目标 PID、lParam 目标 birth）/ QUERY（flags）；A2r |
| GhosttyRemotePane | `WM_USER+0x50` = `0x450` | REMOTE_QUERY（0 magic `0x47585231`，1 flags）；A2r `remote_test` |
| GhosttyRemotePane | `WM_USER+0x53` = `0x453` | REMOTE_TEST_QUERY：lParam 必须 0；selector 0 capability（magic `0x47585233`）、1/2/3 scrollback total/viewport/offset、4 input_applied、5 input_query_count、6 ack_dropped；-1 参数非法、-2 未就绪/断连；A2r `RemoteControls.zig` |
| GhosttyRemotePane | `WM_USER+0x54` = `0x454` | REMOTE_TEST_ACK_DROP：wParam 1、lParam magic，返回 1 已武装下一次真实 completed 输入 ACK；重复武装或恢复中 -1，不可用 -2；A2r |

以上 A2r 消息没有新计时器，复用 GhosttyMsg 的 `RM`。

QUERY 的树索引使用 `lParam = tab | (node << 16)`，最多64 tab / 511 node；tabRect 只用
tab。无效索引返回-1，远程 leaf 不由 A3拥有的元数据返回-2，不把它解释为0。Snapshot
中的终端页计数持 `renderer_state` demand lock 读取，日志不持该锁。

IPC 的附加 env 开关也必须同时启用主测试门：`GHOSTTY_GX_REMOTE_TEST_HOLD_READY=1`
在选主后最多等待30s；`GHOSTTY_GX_REMOTE_TEST_REPLAY=1` 让 CLI 的同一个 Attempt 再发
一次同 key 请求，并记 `fixture_ipc_replay pid=N birth=<FILETIME> outcome=<enum>`（发起
launcher 的身份；日志行首的 `[N]` 是线程号，不是 PID）。日志 `fixture_hello <328hex>` 只有本机测试身份/隔离哈希，无终端文本。
broker 回执为 `fixture_receipt pid=N request=N outcome=<enum> birth=<FILETIME>`；只认
与当前 companion PID/birth 相符的记录。

UIA test-only 日志 `fixture_uia` 给 snapshot/HWND/node/kind/reason/pending，queue日志
在释放锁之后输出；`fixture_uia_dispatch ... invalidates=` 只表示桥层是否预撤销 snapshot
（focus 为 false），回调自身改模型/布局时仍会 `Popup.invalidate()`，不能据此推断最终
provider 状态，以随后的 `fixture_uia ... reason=` 为准。无 Value 正文。
Python FAIL JSON 保留 `stage/node_id/pattern_id/call/hresult/action_results`，不重试。

### A2r 远程控制接口（MIG-07 / MIG-08）

A3 不修改 Remote*.zig，也不猜 selector；`--remote-controls` 读 root 提供的
`F3/A2r-fix/remote-controls.json`（A2r b4d9257da）：`version=1`、`query_message=0x453`、
`capability={selector:0,value:0x47585233}`、`ack_drop={message:0x454,wparam:1,lparam:0x47585233}`，
selector `scrollback_total=1`、`scrollback_viewport=2`、`scrollback_offset=3`、
`input_applied=4`、`input_query_count=5`、`ack_dropped=6`。作用 HWND 必须是同 PID 的
`GhosttyRemotePane`（先核类名与 PID），查询 lParam=0。

- `SendMessageTimeoutW` 的结果按有符号 LRESULT 归一；-1（参数非法/重复武装）与
  -2（未就绪/断连）一律报错，不当计数增长。
- 取任何基线前先轮询 capability 直到等于 magic（超时 FAIL）；整个超时内都是 0 说明
  构建缺少该接口或门未开，记 `WAITING_INTERFACE`。
- 只有 input_applied / input_query_count / ack_dropped 单调；scrollback 三项是
  PageList.scrollbar 的实时状态，可随滚动、缩放、截断变小。

两个进程都要 `GHOSTTY_GX_REMOTE_TEST=1`（夹具自动设置），构建需包含 A2r 提交。

### VM rejected / target_gone 触发

```text
high:   target --root <private> --integrity high --tabs 2
high:   boundary --root <private> --name BRK-01 --transition rejected
medium: drop --root <private> --direction medium-high --case text --name BRK-01
medium: receipt --root <private> --name BRK-01 --expect rejected

medium: drop --root <private> --direction medium-high --case text --name BRK-03
high:   boundary --root <private> --name BRK-03 --transition target-gone
medium: receipt --root <private> --name BRK-03 --expect target_gone
```

第二条路径在真实 preview 模态期间删除绑定叶、保留 host 与另一 tab，再取消旧 preview，
由生产 `eligible` 检查返回 `target_gone`。不要杀整个 host，也不要将用户取消改叫 rejected。
`receipt` 与 `boundary --transition target-gone` 的最终证据只写一次：同一 `--name` 重跑时
若 `<case>-native.json`、回执截图、review 或 target-gone 文件已存在即拒绝，换新 `--name`。

### VM broker 运行前提（O10 对接）

BRK-01～04 只在 VM 中同一用户的 medium/high 拆分令牌下运行，宿主只做单测与语法检查。

- 被测 app 必须含 A3 第二轮 `df33ee3fd`：`DropCompanion.zig` 的门控回执
  `fixture_receipt`、`DropBridge.zig` 的拒绝注入、`Window.zig::fixtureMessage` 的
  CONTROL 21/22。root 合入 A3 之前主线没有这三处，O7b 报的“源码里没有
  fixture_receipt”即此原因；用 `wip/r6-a3-fixtures` 或合入后的 gx_ghostty 构建，并用
  `python -c "import sys; print(b'fixture_receipt' in open(sys.argv[1], 'rb').read())" ghostty.exe`
  核对二进制。
- `gx_ole_source.exe` 在宿主按上文 build-exe 命令构建，带 SHA-256 进客机
  （`setup --source ... --source-sha256 ...`）。
- CPython ≥ 3.9 x64（用到 `Path.is_relative_to`；宿主实测 3.14），只用标准库与 ctypes，
  无第三方包；medium 与 high 控制台用同一解释器。
- 按仓库相对布局暂存（脚本以 `parents[2]` 定位仓库根并把 `scripts/` 加入 `sys.path`）：
  `test/windows/` 的 `gx_drop_broker_fixture.py`、`gx_ole_fixture.py`、`gx_fixture_evidence.py`、
  `gx_boundary_controller.py`、`gx_input_language.py`、`gx_session_ipc_fixture.py`，
  `scripts/` 的 `gx_win_gui.py`、`gx_slots.py`（复制全部 `test/windows/gx_*.py` 最省事）。
  现有 `stage-validation` 只暂存 `gx_vm_validation.ps1`，需扩展暂存清单或另行复制。
- 暂存目录须可写：不带 `--desktop-held` 时在 `<仓库根>/.local/kernel-slots` 建槽锁，VM 内
  没有其他工位时可加 `--desktop-held`。`--root` 用 medium 与 high 都可写的本地目录。
- `GHOSTTY_GX_REMOTE_TEST=1` 由夹具给 target 与 companion 设置，控制台无需预设；回执只认
  与当前 companion PID/birth 相符的 `fixture_receipt` 行。每次运行用新的 `--name`。

### 宿主副作用说明

- controller 的 stage 配置把分屏焦点绑定为 Ctrl+Alt+Shift+J/K（不用 Ctrl+Alt+L/H），启动前用与
  产品 `shortcut_conflicts.zig` 相同的 RegisterHotKey/UnregisterHotKey 探测所有要注入的组合键；
  被其他程序注册为全局热键的组合键会被 Windows 投递给那个程序，故探测到即环境 PENDING，
  绝不注入。

- UIA-03 与 MIG-08 / MIG-08-local 会切换自有 GUI 线程的输入语言（默认“所有应用同一
  输入法”时对其他应用可见），结束时恢复；恢复结果写入 report 的 `input_language`，
  失败即 FAIL，需人工恢复。只切到 `GetKeyboardLayoutList` 已列出的布局
  （`gx_input_language.switch_to_us`，与 A2 第 6 轮 `gx_win_gui` 的 layout/ime_off 语义一致），
  宿主绝不加载布局：缺美式布局时 controller 记 `BLOCKED`（`blocked_by=keyboard-layout`）、
  远程夹具抛 Blocked，均以退出码 2 结束，不静默跳过、不在拼音状态下继续输入。
  本树 `scripts/gx_win_gui.py` 尚无 A2 第 6 轮的 `layout`，故夹具自带同语义实现。
  `--allow-load-layouts`（controller 与 `gx_remote_fixture.py`）只在 VM 使用，夹具自己加载的
  布局在恢复原布局后卸载，结果记入 report 的 `input_language`。
- OLE-07 经用户真实 Explorer 打开夹具私有目录，可能在当前用户的 Explorer 中留下文件夹
  视图或最近访问等持久痕迹，宿主上无法避免；需要零痕迹时只在 VM 运行。
