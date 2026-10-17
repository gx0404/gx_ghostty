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
| MIG-01 | remote `--only drag-threshold` | 基础竖向探针；第二轮 controller 同时检查横向 drag-active。144 DPI 下 15 DIP=22.5 px，22/23 px 不冒称恰 15 DIP |
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
```

| case | 实际 controller |
|---|---|
| MIG-01 | 按原生已绘制 tabRect 实际拖动，10 DIP 横向两侧读 drag.active；15 DIP 纵向两侧观测新窗口 |
| MIG-02 / MIG-02b / MIG-03 | 多进程完整嵌套树、0.3125/0.6875、zoom、手动标题、活动 core；每叶先输出 200 行，再核原源进程隐藏宿主的 HWND/PTY PID+birth/history；拖回与实际 shell marker |
| MIG-02-local | 同进程跨窗合并与再拖出完整树，核每个真实子 HWND 的父子关系和原 PTY |
| MIG-04 | Session 真正恢复 64 个目标 tab；鼠标实际拖单 tab 源窗口到满目标，目标仍 64，源树/core/PTY 保持 |
| MIG-05 | 每个叶位置的真实 SetParent 失败（已移动的 HWND 回滚）；WH_CALLWNDPROC 在实际 SetParent 内同步尝试嵌套迁移，检查事务拒绝而非停止 shell |
| MIG-07 | `--remote-controls <root给的JSON>` 丢一个真实 ACK，等待 query 计数增加；原 cmd 的 `set /p` 收到一个 x，验证没有重复输入 |
| MIG-08 | 迁移后关闭原普通源窗口，继续远程 split、search 与 wheel；原 PTY history/offset 通过源宿主查询 |
| IPC-02h | 6 个 launcher 竞争，1 个 host、5 个 exit0；唯一 Ctrl+Alt+Shift+F24 持久热键的 attempt/success/live 都为1 |
| IPC-03 | 选主后、GUI/PTY/hotkey 前停在有界 native seam；只终止本夹具自启 host，secondary 必须非成功退出 |
| IPC-04b | 从自己启动的真实 host 取得 hello，关闭 host 后 FIRST_PIPE_INSTANCE 占同名管道；只改 hello 的 PID/birth 为实际 Python impostor，其他合法字段原样；要求 DifferentImage 拒绝、无 GUI/PTY |
| IPC-06 | 已就绪 host 一次 GUI 创建故障；真实 secondary 请求收到非成功退出，host 无新窗口/PTY |
| IPC-07 | CLI 通过真实认证管道重复发送同一 request key，host GUI toggle 与 execute 计数只增1，Quick 仍可见 |
| UIA-02 | 外部 MTA 保留 provider，分别 hide/reopen、换子菜单、销毁窗口；旧对象实际调用必须 0x80040201，不能操作替补对象 |
| UIA-03 | MTA 连续查询同时切兄弟 pane 焦点、真实中文 IME 组字、关 tab、开 menu、模态确认；无安装 IME 才属于环境 PENDING |
| UIA-04 | 注册外部 Notification handler 完成握手后，GUI native publisher 发固定测试通知；必须实际收到正文，query/register/remove 同线程 |
| OLE-07 | 用 `/n,/separate` 打开自建目录，Shell 确认是新增 HWND 且精确目录，UIA 找唯一自建文件后真实 Explorer drag；原生 Drop/queued 计数各增1；只关自己打开的窗口，不终止 Explorer 进程 |
| OLE-08 / OLE-09 | `--ole-source <exe>`：真实 DoDragDrop 已进入循环/目标 hover 时 reparent 或销毁目标；取消后 effect NONE、没有落到替补 pane，资源 release 配对 |

### 测试消息与诊断登记表（仅 GhosttyWindow）

`GHOSTTY_GX_REMOTE_TEST=1` 才响应；关闭时所有控制/查询返回0，故障与计数不改变。
所有句柄参数只在当前 App 的 live window/attachment 中解析，不接受外部裸指针。

| 消息 | wParam | lParam / 返回值 |
|---|---|---|
| `WM_USER+0x51` = `0x451` CONTROL | 0 | 清该窗口的迁移测试状态 |
| 同上 | 1 / 2 | 1-based SetParent 失败叶位置 / 同步重入叶位置；0 关闭 |
| 同上 | 3 / 4 | 当前 tab 合入本 App 的目标 HWND / 拖到真实空新窗，4 返回新 HWND |
| 同上 | 5 / 6 / 7 | 选择 tab / zoom node（-1取消）/ 活动 leaf node |
| 同上 | 8 | 删除当前活动叶；保留其他叶/窗，供真实 OLE 销毁用例 |
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
| 同上 | 200 / 201 | 真实 OLE Drop 回调数 / owned payload 成功排入数 |

QUERY 的树索引使用 `lParam = tab | (node << 16)`，最多64 tab / 511 node；tabRect 只用
tab。无效索引返回-1，远程 leaf 不由 A3拥有的元数据返回-2，不把它解释为0。Snapshot
中的终端页计数持 `renderer_state` demand lock 读取，日志不持该锁。

IPC 的附加 env 开关也必须同时启用主测试门：`GHOSTTY_GX_REMOTE_TEST_HOLD_READY=1`
在选主后最多等待30s；`GHOSTTY_GX_REMOTE_TEST_REPLAY=1` 让 CLI 的同一个 Attempt 再发
一次同 key 请求。日志 `fixture_hello <328hex>` 只有本机测试身份/隔离哈希，无终端文本。
broker 回执为 `fixture_receipt pid=N request=N outcome=<enum> birth=<FILETIME>`；只认
与当前 companion PID/birth 相符的记录。

UIA test-only 日志 `fixture_uia` 给 snapshot/HWND/node/kind/reason/pending，queue日志
在释放锁之后输出；`fixture_uia_dispatch` 给实际是否撤销 snapshot。无 Value 正文。
Python FAIL JSON 保留 `stage/node_id/pattern_id/call/hresult/action_results`，不重试。

### A2r 远程控制接口依赖

A3 不修改 Remote*.zig，也不猜 selector。MIG-07 的 JSON 必须由 root 从 A2r 接口生成：
`version=1`、`query_message`、`capability={selector,value}`、
`ack_drop={message,wparam,lparam}`（单次丢弃真实输入 ACK、返回1）、整数 selector
`scrollback_total/scrollback_viewport/scrollback_offset/input_applied/input_query_count/ack_dropped`。
作用 HWND 是现有 `GhosttyRemotePane`，PID/birth/exe 与既有 QUERY source core id 先核。
未提供接口报 `WAITING_INTERFACE`，与环境 PENDING 区分。其他迁移 case 已直接查询源
进程隐藏宿主的真实 terminal 页状态，不用缺失的远程字段填0。

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
