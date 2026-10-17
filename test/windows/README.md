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
| MIG-01 | remote `--only drag-threshold` | 真实竖向阈值两侧、原 PTY/core/HWND；144 DPI 下 15 DIP=22.5 px，22/23 px 不冒称恰 15 DIP；横向 drag-active 仍待原生查询 |
| MIG-02/MIG-02b | remote 默认 transfer/dragback | 现有跨进程迁移/拖回；完整嵌套树与 scrollback 仍单列 |
| MIG-06a/b/d | remote `--only performable --only once --only table` | 实际 shell marker 验证 fallback、once 与持久 table；chain 走默认完整序列 |
| PERF-REMOTE-01 | remote `--only perf-input --perf-count 50 --perf-interval-ms 200` | 两端 `GHOSTTY_GX_PERF=1`，真实逐字符输入、不回车；由 root 的 quiet 批次汇总 `remote.input_to_present`，夹具不判性能门 |
| SES-01 | session `--case roundtrip` | 两窗、每窗两 tab、0.3125/0.6875 嵌套树、后台 zoom/active、字号、中文/emoji override、合法 cwd，两轮新 PID/birth；生产快照逐字段比较 |
| SES-02/03 | session `--case missing_profile --case priority` | 失效 profile、command/-e/initial-command 优先级、恢复不重放 initial-command |
| SES-04/05 | session `--case cancel_close --case write_failure` | 取消保档；只对私有 state 目录设拒写 DACL，先验证真实拒写、最终恢复原 ACL |
| SES-06/07/08 | session `--case dual_writer --case privacy --case quick_excluded` | 双 writer、字段白名单/隐私 marker、Quick 排除 |
| IPC-01/02 | session `--case multi --case race` | 普通 launcher 与 -e；6 个 suspended launcher 同批恢复、一个 host、其余退出码均 0；热键注册次数还需原生计数 |
| IPC-03/04 | session `--case crash_before_ready --case squatter` | ready 前自有 host 退出；同名不响应 endpoint 预占。若暂停时已创建 GUI/PTY，IPC-03 记 PENDING；IPC-04 不代有效伪造 hello 认证 |
| IPC-05 | session `--case roots` | 配置根隔离；build/install/token/session/account 各维度另验 |
| UIA-01/02 | popup `--mode off --actions` | 外部无 HWND MTA 调用 Invoke/SelectionItem/Value/Toggle/Expand；Palette hide/reopen 后保留旧 Value provider 实际调用必须不可用 |
| OLE-01/02/03/04/05/06 | ole `--case unicode/single_file/files/shell_metachar_files/quoted_path/uri/multiline/unterminated/bad_hdrop/bad_uri/text_limit/too_many_files`（每项独立 `--case`） | 真实 DoDragDrop、释放计数、源文件摘要保持；引号路径是明确的恶意合成 HDROP，Windows 不存在引号文件名；COPY 仅准入、粘贴与无 Enter 必须读图 |
| BRK-01/02/03/04 | broker `receipt --expect rejected/expired/target_gone/cancelled` | VM 同用户 medium/high 拆分令牌；必须取得真实完成回执日志。缺 diagnostic 时退出 2/PENDING，不把截图或 OLE COPY 当 ACK |

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
与另一 pane，再验 `target_gone`；杀整个 host 不代认证完成回执。后两项真实触发控制及
生产回执 diagnostic 仍需 root 集成。Explorer 真源、拖放中 reparent/销毁、Notification
真实接收、IME/modal 压力和权限/跨账户矩阵，不能用本表中的有限用例代签。

离线验证：`python -m unittest discover -s test/windows -p 'test_gx_*.py'`，
`python scripts/run_unittests.py test_gx_win_uia test_fork_patches`。
