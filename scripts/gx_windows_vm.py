"""Prepare and drive isolated, digest-pinned Windows validation VMs (no implicit download).

Every command acts only on the owned containers gx-ghostty-win11 / gx-ghostty-win10 (label gx.owner
and the pinned image are checked first). Nothing pulls an image, removes a container volume or the VM
disk, or uses the host desktop: screenshots come from QEMU's screendump and input goes through the
QEMU human monitor inside the container.

  prepare            write compose, OEM bootstrap and local credentials (never printed); each VM gets
                     a persistent nonzero SMBIOS UUID (machine.json) so the guest guard can bind it
  verify             check the pinned installation media
  status             read-only state of the owned containers (no environment values)
  up                 start one VM attached and hold a heavy gx_slots slot for its whole runtime;
                     refuses while another owned VM runs; never pulls (--pull never)
  stop               ACPI shutdown through docker compose stop; storage and disk are kept
  identity           live SMBIOS UUID (HMP info uuid) compared with machine.json
  screenshot         HMP screendump of the VM screen to a new PNG
  keys / type        HMP sendkey with QEMU qcodes, or US-keyboard ASCII text (--channel vnc
                     sends keysyms through the container's QEMU VNC server instead)
  type-secret        type a credentials.json field; the value never reaches argv or output
  click              absolute pointer click through the container's QEMU VNC server
  stage-validation   stage the guest fixture after checking the live VM identity
  rehearsal-layout   ghostty.exe plus pinned ConPTY/Mesa from the offline package cache, marked
                     REHEARSAL_NOT_FINAL, for GL rehearsal before the frozen installer exists
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import struct
import subprocess
import sys
import time
import uuid
import zlib

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = Path(__file__).resolve().parent
IMAGE = "dockurr/windows@sha256:59f8bed19cfd49cf1701debe34f9df6311e61a4e2ae68aa9f41206e2184e31cc"
OWNER = "gx-ghostty-ui-validation"
VALIDATION_SCRIPT = ROOT / "test" / "windows" / "gx_vm_validation.ps1"
GUEST_RUNNER = "gx-run.cmd"
MONITOR = "/run/shm/monitor.sock"
SLOTS = ROOT / ".local" / "kernel-slots"
PORTS = {"win11": (18006, 13389), "win10": (18007, 13390)}
CREDENTIAL_FIELDS = ("admin_password", "user_password")
QCODE = re.compile(r"^[a-z0-9_]+(-[a-z0-9_]+)*$")
UUID_TEXT = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
REHEARSAL_PAYLOAD = ("conpty.dll", "OpenConsole.exe", "mesa/opengl32.dll", "mesa/libgallium_wgl.dll", "mesa/dxil.dll")
MEDIA = {
    "win11": {
        "file": "win11-25h2-en-us.iso",
        "url": "https://software-static.download.prss.microsoft.com/dbazure/888969d5-f34g-4e03-ac9d-1f9786c66749/26200.6584.250915-1905.25h2_ge_release_svc_refresh_CLIENT_CONSUMER_x64FRE_en-us.iso",
        "sha256": "d141f6030fed50f75e2b03e1eb2e53646c4b21e5386047cb860af5223f102a32",
        "size": 7736125440,
    },
    "win10": {
        "file": "win10-22h2-enterprise-eval-en-us.iso",
        "url": "https://software-static.download.prss.microsoft.com/dbazure/988969d5-f34g-4e03-ac9d-1f9786c66750/19045.2006.220908-0225.22h2_release_svc_refresh_CLIENTENTERPRISEEVAL_OEMRET_x64FRE_en-us.iso",
        "sha256": "ef7312733a9f5d7d51cfa04ac497671995674ca5e1058d5164d6028f0938d668",
        "size": 5550497792,
    },
}
# US keyboard: characters that need shift, and unshifted punctuation, as QEMU qcodes.
SHIFTED = {"!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
           "_": "minus", "+": "equal", "{": "bracket_left", "}": "bracket_right", "|": "backslash",
           ":": "semicolon", '"': "apostrophe", "~": "grave_accent", "<": "comma", ">": "dot", "?": "slash"}
PLAIN = {"-": "minus", "=": "equal", "[": "bracket_left", "]": "bracket_right", "\\": "backslash",
         ";": "semicolon", "'": "apostrophe", "`": "grave_accent", ",": "comma", ".": "dot", "/": "slash",
         " ": "spc", "\n": "ret", "\t": "tab"}


class VmError(Exception):
    pass


def write(path: Path, data: str) -> None:
    path.write_text(data, encoding="utf-8", newline="")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def protect_directory(path: Path) -> None:
    """Restrict generated credentials before writing them, including on Windows."""
    if os.name != "nt":
        path.chmod(0o700)
        return
    system = Path(os.environ["SystemRoot"]) / "System32"
    identity = subprocess.check_output([str(system / "whoami.exe")], text=True).strip()
    subprocess.run([str(system / "icacls.exe"), str(path), "/inheritance:r", "/grant:r",
                    identity + ":(OI)(CI)F", "SYSTEM:(OI)(CI)F"],
                   check=True, stdout=subprocess.DEVNULL)


def verify_media(path: Path, spec: dict) -> str:
    if path.stat().st_size != spec["size"]:
        raise ValueError("Installation media size mismatch")
    digest = sha256_file(path)
    if digest != spec["sha256"]:
        raise ValueError("Installation media SHA256 mismatch")
    return digest


def machine_identity(root: Path, version: str) -> dict:
    data = json.loads((root / version / "machine.json").read_text(encoding="utf-8"))
    machine = uuid.UUID(data["uuid"])
    if machine.int == 0 or data.get("host") != f"GX-{version.upper()}":
        raise ValueError("machine.json does not hold a nonzero UUID and the expected guest name")
    return {"uuid": str(machine), "host": data["host"]}


def text_keys(text: str) -> list[str]:
    keys = []
    for char in text:
        if "a" <= char <= "z" or "0" <= char <= "9":
            keys.append(char)
        elif "A" <= char <= "Z":
            keys.append("shift-" + char.lower())
        elif char in PLAIN:
            keys.append(PLAIN[char])
        elif char in SHIFTED:
            keys.append("shift-" + SHIFTED[char])
        else:
            raise VmError(f"cannot type {char!r} on the guest's US keyboard")
    return keys


def parse_ppm(data: bytes) -> tuple[int, int, bytes]:
    if not data.startswith(b"P6"):
        raise VmError("screendump is not a binary PPM")
    fields: list[int] = []
    index = 2
    while len(fields) < 3:
        while index < len(data) and data[index:index + 1].isspace():
            index += 1
        if data[index:index + 1] == b"#":
            while index < len(data) and data[index:index + 1] not in (b"\n", b"\r"):
                index += 1
            continue
        start = index
        while index < len(data) and not data[index:index + 1].isspace():
            index += 1
        if start == index:
            raise VmError("truncated PPM header")
        fields.append(int(data[start:index]))
    width, height, maxval = fields
    if maxval != 255 or width <= 0 or height <= 0:
        raise VmError("unsupported PPM geometry")
    index += 1
    pixels = data[index:index + width * height * 3]
    if len(pixels) != width * height * 3:
        raise VmError("incomplete PPM pixel data")
    return width, height, pixels


def png_bytes(width: int, height: int, rgb: bytes) -> bytes:
    stride = width * 3
    raw = b"".join(b"\x00" + rgb[row * stride:(row + 1) * stride] for row in range(height))

    def chunk(kind: bytes, payload: bytes) -> bytes:
        return (struct.pack(">I", len(payload)) + kind + payload
                + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF))

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b"")


def docker_executable(explicit: str | None = None) -> str:
    candidates = [explicit, os.environ.get("GX_GHOSTTY_DOCKER"), shutil.which("docker")]
    for base, tail in (("LOCALAPPDATA", "Programs/DockerDesktop/resources/bin/docker.exe"),
                       ("ProgramFiles", "Docker/Docker/resources/bin/docker.exe")):
        if os.environ.get(base):
            candidates.append(str(Path(os.environ[base]) / tail))
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return str(candidate)
    raise VmError("docker CLI not found; pass --docker or set GX_GHOSTTY_DOCKER")


class Docker:
    """docker CLI wrapper; error text never includes container environment values."""

    def __init__(self, executable: str, runner=subprocess.run):
        self.executable = executable
        self.runner = runner

    def run(self, *args: str, input: str | bytes | None = None, timeout: float = 120, text: bool = True,
            check: bool = True) -> subprocess.CompletedProcess:
        result = self.runner([self.executable, *args], input=input, capture_output=True, text=text,
                             timeout=timeout)
        if check and result.returncode != 0:
            detail = result.stderr if text else result.stderr.decode("utf-8", "replace")
            raise VmError(f"docker {args[0]} failed ({result.returncode}): {str(detail).strip()[:400]}")
        return result


def container_name(version: str) -> str:
    return f"gx-ghostty-{version}"


def container_state(docker: Docker, version: str) -> dict:
    name = container_name(version)
    result = docker.run("inspect", "--type", "container", name, check=False)
    if result.returncode != 0:
        return {"name": name, "exists": False, "running": False}
    data = json.loads(result.stdout)[0]
    config = data.get("Config") or {}
    labels = config.get("Labels") or {}
    state = data.get("State") or {}
    return {"name": name, "exists": True, "id": data.get("Id", "")[:12],
            "owned": labels.get("gx.owner") == OWNER and config.get("Image") == IMAGE,
            "running": bool(state.get("Running")), "status": state.get("Status"),
            "exit_code": state.get("ExitCode"), "oom_killed": state.get("OOMKilled"),
            "started_at": state.get("StartedAt"), "finished_at": state.get("FinishedAt"),
            "uuid_configured": any(str(item).startswith("UUID=") for item in config.get("Env") or [])}


def require_running(docker: Docker, version: str) -> dict:
    state = container_state(docker, version)
    if not state["exists"] or not state.get("owned"):
        raise VmError(f"{state['name']} is not the owned, digest-pinned validation container")
    if not state["running"]:
        raise VmError(f"{state['name']} is not running")
    return state


def clean_monitor(text: str) -> str:
    return ANSI.sub("", text).replace("\r", "")


def hmp(docker: Docker, version: str, commands: list[str], *, quiet: bool = False) -> str:
    """Run QEMU human-monitor commands on the container's automation socket."""
    require_running(docker, version)
    if any("\n" in command or "\r" in command for command in commands):
        raise VmError("one HMP command per line")
    script = f"nc -q 1 -w 10 -U {MONITOR}" + (" >/dev/null 2>&1" if quiet else "")
    result = docker.run("exec", "-i", container_name(version), "sh", "-c", script,
                        input="".join(command + "\n" for command in commands), timeout=90)
    return "" if quiet else clean_monitor(result.stdout)


def live_uuid(docker: Docker, version: str) -> str:
    found = UUID_TEXT.findall(hmp(docker, version, ["info uuid"]))
    if not found:
        raise VmError("HMP info uuid returned no UUID")
    return str(uuid.UUID(found[-1]))


def send_keys(docker: Docker, version: str, keys: list[str], *, hold_ms: int = 40, gap: float = 0.12) -> int:
    """sendkey one chord at a time; the gap exceeds the hold so modifiers never overlap."""
    for key in keys:
        if not QCODE.fullmatch(key):
            raise VmError("invalid QEMU key name")
    require_running(docker, version)
    script = (f"while IFS= read -r k; do printf 'sendkey %s {int(hold_ms)}\\n' \"$k\"; sleep {gap:.3f}; done"
              f" | nc -q 1 -w 10 -U {MONITOR} >/dev/null 2>&1")
    docker.run("exec", "-i", container_name(version), "sh", "-c", script,
               input="".join(key + "\n" for key in keys), timeout=60 + len(keys))
    return len(keys)


def type_secret(root: Path, version: str, docker: Docker, field: str, enter: bool) -> int:
    if field not in CREDENTIAL_FIELDS:
        raise VmError("unknown credential field")
    account = json.loads((root / version / "credentials.json").read_text(encoding="utf-8"))
    try:
        keys = text_keys(account[field])
    except VmError:
        raise VmError("the stored credential contains a character this channel cannot type") from None
    finally:
        account = None
    # Slower than ordinary text: a dropped key here costs a failed sign-in.
    return send_keys(docker, version, keys + (["ret"] if enter else []), hold_ms=60, gap=0.25) - (1 if enter else 0)


# Runs inside the container (python3 of the pinned image) against QEMU's own VNC
# server; the event list arrives on stdin so typed text never reaches argv.
VNC_CLIENT = r'''
import json, socket, struct, sys, time
events = json.load(sys.stdin)
s = socket.create_connection(("127.0.0.1", 5900), timeout=10)
def recv(n):
    data = b""
    while len(data) < n:
        chunk = s.recv(n - len(data))
        if not chunk:
            raise SystemExit("vnc closed")
        data += chunk
    return data
version = recv(12)
s.sendall(b"RFB 003.008\n")
types = recv(recv(1)[0])
if 1 not in types:
    raise SystemExit("vnc requires authentication")
s.sendall(b"\x01")
if struct.unpack(">I", recv(4))[0] != 0:
    raise SystemExit("vnc security failed")
s.sendall(b"\x01")
width, height = struct.unpack(">HH", recv(4))
recv(16)
recv(struct.unpack(">I", recv(4))[0])
for event in events:
    kind = event[0]
    if kind == "k":
        s.sendall(struct.pack(">BBxxI", 4, event[2], event[1]))
    elif kind == "p":
        s.sendall(struct.pack(">BBHH", 5, event[3], event[1], event[2]))
    else:
        time.sleep(event[1])
s.close()
print(json.dumps({"width": width, "height": height}))
'''
SHIFT_KEYSYM = 0xFFE1
NAMED_KEYSYMS = {"\n": 0xFF0D, "\t": 0xFF09}
US_SHIFTED = set('~!@#$%^&*()_+{}|:"<>?ABCDEFGHIJKLMNOPQRSTUVWXYZ')


def vnc_text_events(text: str, gap: float = 0.08) -> list:
    events: list = []
    for char in text:
        keysym = NAMED_KEYSYMS.get(char, ord(char))
        if char not in NAMED_KEYSYMS and not 0x20 <= keysym <= 0x7E:
            raise VmError("the VNC channel types printable ASCII only")
        shifted = char in US_SHIFTED
        if shifted:
            events.append(["k", SHIFT_KEYSYM, 1])
        events += [["k", keysym, 1], ["s", 0.03], ["k", keysym, 0]]
        if shifted:
            events.append(["k", SHIFT_KEYSYM, 0])
        events.append(["s", gap])
    return events


def vnc_send(docker: Docker, version: str, events: list) -> dict:
    require_running(docker, version)
    result = docker.run("exec", "-i", container_name(version), "python3", "-c", VNC_CLIENT,
                        input=json.dumps(events), timeout=60 + len(events) // 4)
    return json.loads(result.stdout.strip().splitlines()[-1])


def vnc_click(docker: Docker, version: str, x: int, y: int, button: str = "left", count: int = 1) -> dict:
    mask = {"left": 1, "middle": 2, "right": 4}[button]
    events: list = [["p", x, y, 0], ["s", 0.15]]
    for _ in range(count):
        events += [["p", x, y, mask], ["s", 0.08], ["p", x, y, 0], ["s", 0.08]]
    return vnc_send(docker, version, events)


def type_secret_vnc(root: Path, version: str, docker: Docker, field: str, enter: bool) -> int:
    if field not in CREDENTIAL_FIELDS:
        raise VmError("unknown credential field")
    account = json.loads((root / version / "credentials.json").read_text(encoding="utf-8"))
    try:
        value = account[field]
        events = vnc_text_events(value + ("\n" if enter else ""))
        count = len(value)
    except VmError:
        raise VmError("the stored credential contains a character this channel cannot type") from None
    finally:
        account = None
        value = None
    vnc_send(docker, version, events)
    return count


def screenshot(docker: Docker, version: str, destination: Path) -> dict:
    if destination.exists():
        raise VmError("refusing to overwrite an existing screenshot")
    remote = f"/run/shm/gx-screen-{secrets.token_hex(6)}.ppm"
    name = container_name(version)
    data = b""
    try:
        hmp(docker, version, [f"screendump {remote}"], quiet=True)
        for _ in range(50):
            result = docker.run("exec", name, "cat", remote, text=False, check=False)
            if result.returncode == 0:
                try:
                    parse_ppm(result.stdout)
                    data = result.stdout
                    break
                except VmError:
                    pass
            time.sleep(0.2)
    finally:
        docker.run("exec", name, "rm", "-f", remote, check=False)
    if not data:
        raise VmError("screendump produced no complete image")
    width, height, pixels = parse_ppm(data)
    png = png_bytes(width, height, pixels)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.open("xb") as stream:
        stream.write(png)
    return {"file": str(destination), "sha256": hashlib.sha256(png).hexdigest(), "width": width,
            "height": height, "captured_utc": utc_now(), "source": "QEMU HMP screendump (VM screen only)",
            "visual_review": "PENDING"}


def up(root: Path, version: str, docker: Docker, log_path: Path, slot_timeout: float) -> int:
    sys.path.insert(0, str(SCRIPTS))
    import gx_slots

    compose = root / version / "compose.yaml"
    text = compose.read_text(encoding="utf-8")
    machine = machine_identity(root, version)
    if IMAGE not in text or f"UUID: '{machine['uuid']}'" not in text:
        raise VmError("compose.yaml is not the pinned, UUID-bound configuration; run prepare first")
    docker.run("image", "inspect", IMAGE)  # must already be cached; never pulled
    with gx_slots.acquire(SLOTS, "heavy", slot_timeout):
        for other in MEDIA:
            if container_state(docker, other)["running"]:
                raise VmError(f"{container_name(other)} is already running; only one owned VM may run")
        log_path.parent.mkdir(parents=True, exist_ok=True)
        with log_path.open("ab") as stream:
            child = subprocess.Popen(
                [docker.executable, "compose", "-p", container_name(version), "-f", str(compose),
                 "up", "--pull", "never", "--no-build", "--no-color"],
                cwd=compose.parent, stdin=subprocess.DEVNULL, stdout=stream, stderr=subprocess.STDOUT)
            print(json.dumps({"event": "compose-up", "pid": child.pid, "slot": "heavy",
                              "log": str(log_path), "utc": utc_now()}), flush=True)
            while True:
                try:
                    return child.wait()
                except KeyboardInterrupt:
                    # Keep the heavy slot until the VM has actually stopped.
                    continue


def stop(root: Path, version: str, docker: Docker) -> dict:
    state = container_state(docker, version)
    if not state["exists"] or not state.get("owned"):
        raise VmError(f"{state['name']} is not the owned validation container")
    if state["running"]:
        compose = root / version / "compose.yaml"
        docker.run("compose", "-p", container_name(version), "-f", str(compose), "stop", "-t", "180",
                   timeout=300)
    return container_state(docker, version)


def stage_validation(root: Path, version: str, guest_uuid: str, guest_name: str) -> Path:
    """Stage a guest-only fixture; never touch Docker, host accounts or registry."""
    identity = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
    if identity.get("owner") != OWNER or identity.get("image") != IMAGE:
        raise ValueError("VM root does not belong to this pinned validation setup")
    machine_uuid = uuid.UUID(guest_uuid)
    if machine_uuid.int == 0 or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]{0,14}", guest_name):
        raise ValueError("A nonzero QEMU guest UUID and exact guest computer name are required")
    machine = machine_identity(root, version)
    if str(machine_uuid) != machine["uuid"] or guest_name != machine["host"]:
        raise ValueError("Guest UUID/name differ from this VM's persisted machine identity")
    exchange = (root / version / "exchange").resolve(strict=True)
    destination = (exchange / "validation").resolve()
    if not destination.is_relative_to(exchange):
        raise ValueError("Validation destination escapes the owned exchange directory")
    previous = destination / "validation-manifest.json"
    if destination.exists():
        if not previous.is_file():
            raise ValueError("Existing validation directory has no ownership manifest")
        saved = json.loads(previous.read_text(encoding="utf-8"))
        if saved.get("owner") != OWNER or saved.get("guest_uuid") != str(machine_uuid):
            raise ValueError("Existing validation fixture belongs to another owner or VM")
    setup = root / version / "oem" / "setup-guest.ps1"
    script_bytes = VALIDATION_SCRIPT.read_bytes()
    destination.mkdir(parents=True, exist_ok=True)
    (destination / "out").mkdir(exist_ok=True)
    (destination / VALIDATION_SCRIPT.name).write_bytes(script_bytes)
    write(previous, json.dumps({
        "schema": 1, "owner": OWNER, "image": IMAGE, "version": version,
        "guest_uuid": str(machine_uuid), "guest_name": guest_name,
        "fixture_sha256": hashlib.sha256(script_bytes).hexdigest(),
        "setup_sha256": sha256_file(setup),
        "identity_source": "machine.json UUID passed to QEMU -uuid and read back live through HMP info uuid.",
        "limits": "No passwords; no host registry/account writes; runtime guest identity guard is mandatory.",
    }, indent=2) + "\n")
    write(destination / GUEST_RUNNER, (
        "@echo off\r\n"
        "rem Copies the staged fixture into the caller's profile and runs it with a per-process\r\n"
        "rem execution-policy bypass. Results are also exported to the share's out folder.\r\n"
        "setlocal\r\n"
        "set \"GXSRC=%~dp0\"\r\n"
        "set \"GXDST=%LOCALAPPDATA%\\GXVMValidation\\Fixture\"\r\n"
        "if not exist \"%GXDST%\" mkdir \"%GXDST%\" || exit /b 1\r\n"
        "copy /y \"%GXSRC%gx_vm_validation.ps1\" \"%GXDST%\\gx_vm_validation.ps1\" >nul || exit /b 1\r\n"
        "copy /y \"%GXSRC%validation-manifest.json\" \"%GXDST%\\validation-manifest.json\" >nul || exit /b 1\r\n"
        "\"%SystemRoot%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe\" -NoProfile -ExecutionPolicy Bypass"
        " -File \"%GXDST%\\gx_vm_validation.ps1\" -Manifest \"%GXDST%\\validation-manifest.json\""
        " -ExportDir \"%GXSRC%out\" %*\r\n"
        "exit /b %ERRORLEVEL%\r\n"))
    write(destination / "RUN-IN-GUEST.md", """# 仅在身份已核对的 Windows 测试虚拟机内执行

宿主只运行 gx_windows_vm.py：up 持有 heavy 槽启动唯一一台 VM，identity 核对 QEMU UUID，stage-validation 暂存本目录，screenshot 只取 VM 画面，keys/type/type-secret 经容器内 QEMU monitor 输入；宿主不运行下列 PowerShell。fixture 自身再核名字、UUID、QEMU/OVMF 硬件和自身 SHA，不支持跳过守门。

客机默认执行策略是 Restricted，且共享目录属 Internet 区域，一律从 Win+R 用 cmd /c 调用本目录的 gx-run.cmd：它把 fixture 复制到当前用户 LOCALAPPDATA，以单进程 Bypass 运行，并把报告扁平导出到本目录 out\\，文件名前缀为 <RunId>--<用户>--（该共享不能可靠地在客机新建目录下再建子目录）。

~~~text
cmd /c \\\\host.lan\\Data\\validation\\gx-run.cmd -Phase inspect -RunId probe-01
cmd /c \\\\host.lan\\Data\\validation\\gx-run.cmd -Phase tokens -RunId split-01
~~~

dockur 应答文件把 EnableLUA 设为 0，管理员只有未拆分的 high 令牌：先在提升的 gxadmin 控制台运行 enable-uac（恢复 EnableLUA=1、ConsentPromptBehaviorAdmin=5、PromptOnSecureDesktop=1，并记录前后值），在 VM 内重启客机后重新登录。同一用户的 medium/high 拆分令牌：先在普通 Run 对话框（Enter）运行 tokens，再对同一行按 Ctrl+Shift+Enter，经 UAC 同意后以 high 运行一次；第二次自动配对，核同 SID、同会话、Limited/Full 及双向 linked logon。-PeerPid 可附加检查低完整性能否查询高进程令牌。

首次以 gxadmin 登录会经 FirstLogonCommands 执行 C:\\OEM\\install.bat；若 C:\\OEM\\guest-user.json 仍在，在提升的 gxadmin 终端运行 accounts。密码只由 OEM 脚本在客机内读取，不传命令行、不打印。

完整包未就绪时只能预演：rehearsal-layout 组出的 payload 带 REHEARSAL_NOT_FINAL 清单，只能以 gl -AppRoot <payload> -AppSha256 <SHA> -Rehearsal 运行，报告状态固定为 REHEARSAL_NOT_FINAL，不能作为最终证据。

~~~text
cmd /c \\\\host.lan\\Data\\validation\\gx-run.cmd -Phase install -RunId clean -Installer <完整安装包> -InstallerSha256 <SHA>
cmd /c \\\\host.lan\\Data\\validation\\gx-run.cmd -Phase gl -RunId clean -AppSha256 <已装exeSHA> -HoldSeconds 20
cmd /c \\\\host.lan\\Data\\validation\\gx-run.cmd -Phase gl -RunId clean -AppSha256 <已装exeSHA> -SoftwareGL
cmd /c \\\\host.lan\\Data\\validation\\gx-run.cmd -Phase uninstall -RunId clean
~~~

GL 只签真实 native renderer/window 与正常关闭；VM 无 GPU 时随包 Mesa llvmpipe 是真实软件 WGL，不是 API mock。屏幕截图由协调者在 HoldSeconds 窗口内用 screenshot 采集并逐张读图。无 GL 时保留 FAIL/BLOCKED。

旧版升级负例：新 RunId 先 install 真实旧包，再 upgrade 新包；两个冻结 installer SHA 必须不同。随后 seed-foreign-after（All，分别 Value/Subkey/Both），uninstall、check-preserved，再 cleanup-foreign 只清完全匹配本 run 记录的测试组。

安装前冲突：干净用户状态下，分别以 Group=AppPath/Background/Directory/ShellIdentity 新 RunId 执行 seed-foreign-before，再 expect-install-refused（须退出码 7 且日志含对应具体原因），最后 check-preserved、cleanup-foreign。

干净卸载必须同时删除 App Paths、两组右键菜单、AUMID 与 Toast CLSID 键。首次账户检查不证明后续登录/实际权限操作；静态测试不代旧版升级、真实 registry、Toast/JumpList、DND/冷暖激活或 GUI 验收。安装器/卸载器等待有界，超时保留 owned PID 信息，不强杀未知进程。
""")
    return destination


def rehearsal_layout(app: Path, output: Path, share: Path | None, cache: Path | None) -> dict:
    """Old-build GL rehearsal tree: never a substitute for the frozen installer."""
    sys.path.insert(0, str(SCRIPTS))
    import gx_windows_package as package

    items = [item for item in package.PAYLOAD if item.target in REHEARSAL_PAYLOAD]
    if sorted(item.target for item in items) != sorted(REHEARSAL_PAYLOAD):
        raise VmError("the pinned ConPTY/Mesa payload no longer matches the rehearsal list")
    app = app.resolve(strict=True)
    output.mkdir(parents=True, exist_ok=False)
    shutil.copyfile(app, output / "ghostty.exe")
    package.materialize(output, package.cache_dir(cache), payload=items, offline=True)
    if share is not None:
        for path in sorted(share.rglob("*")):
            relative = path.relative_to(share)
            if relative.parts[0] == "pkgconfig" or not path.is_file():
                continue
            target = output / "share" / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, target)
        for relative, data in package.source_themes(ROOT):
            target = output / relative
            if not target.exists():
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
    files = {path.relative_to(output).as_posix(): sha256_file(path)
             for path in sorted(output.rglob("*")) if path.is_file()}
    manifest = {"class": "REHEARSAL_NOT_FINAL", "created_utc": utc_now(), "app_source": str(app),
                "app_sha256": files["ghostty.exe"], "files": files,
                "limits": "Old application build for VM GL rehearsal only; never final installer evidence."}
    write(output / "payload-manifest.json", json.dumps(manifest, indent=2) + "\n")
    return {"output": str(output), "app_sha256": files["ghostty.exe"], "file_count": len(files)}


def prepare(root: Path) -> None:
    root.mkdir(parents=True, exist_ok=True)
    protect_directory(root)
    (root / "media").mkdir(exist_ok=True)
    write(root / "manifest.json", json.dumps({"owner": OWNER, "image": IMAGE, "media": MEDIA}, indent=2) + "\n")
    for version, (web, rdp) in PORTS.items():
        base = root / version
        for sub in ("storage", "exchange", "oem"):
            (base / sub).mkdir(parents=True, exist_ok=True)
        secret = base / "credentials.json"
        if not secret.exists():
            write(secret, json.dumps({"admin_user": "gxadmin", "admin_password": "Gx9" + secrets.token_hex(16), "user": "gxtest", "user_password": "Gx9" + secrets.token_hex(16)}, indent=2))
        machine_file = base / "machine.json"
        if not machine_file.exists():
            write(machine_file, json.dumps({"uuid": str(uuid.uuid4()), "host": f"GX-{version.upper()}"}, indent=2) + "\n")
        machine = machine_identity(root, version)
        account = json.loads(secret.read_text(encoding="utf-8"))
        write(base / "guest.env", "USERNAME=gxadmin\nPASSWORD=" + account["admin_password"] + "\n")
        write(base / "oem" / "guest-user.json", json.dumps({"username": "gxtest", "password": account["user_password"]}))
        write(base / "oem" / "install.bat", "@echo off\r\npowershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\\OEM\\setup-guest.ps1\r\n")
        write(base / "oem" / "setup-guest.ps1", r'''$ErrorActionPreference = 'Stop'
$account = Get-Content -LiteralPath C:\OEM\guest-user.json -Raw | ConvertFrom-Json
$secure = ConvertTo-SecureString $account.password -AsPlainText -Force
if (-not (Get-LocalUser -Name $account.username -ErrorAction SilentlyContinue)) {
    New-LocalUser -Name $account.username -Password $secure -Description 'GX isolated standard-user tests' | Out-Null
    Add-LocalGroupMember -SID 'S-1-5-32-545' -Member $account.username
    Add-LocalGroupMember -SID 'S-1-5-32-555' -Member $account.username
}
$policy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
New-Item -Path $policy -Force | Out-Null
New-ItemProperty -Path $policy -Name fDisableClip -Value 1 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $policy -Name fDisableCdm -Value 1 -PropertyType DWord -Force | Out-Null
Remove-Item -LiteralPath C:\OEM\guest-user.json
'GX guest setup initialized.' | Set-Content C:\OEM\gx-setup-result.txt
''')
        write(base / "compose.yaml", f'''services:
  windows:
    image: {IMAGE}
    container_name: {container_name(version)}
    labels:
      gx.owner: '{OWNER}'
    env_file: guest.env
    environment:
      VERSION: '{'11' if version == 'win11' else '10e'}'
      CPU_CORES: '4'
      RAM_SIZE: '8G'
      DISK_SIZE: '64G'
      DISK_FMT: 'qcow2'
      ALLOCATE: 'N'
      KVM: 'Y'
      AUTOLOGIN: 'N'
      REMOVE: 'N'
      VERIFY: 'Y'
      LANGUAGE: 'en-US'
      HOST: '{machine['host']}'
      UUID: '{machine['uuid']}'
    devices:
      - /dev/kvm
      - /dev/net/tun
    cap_add:
      - NET_ADMIN
    ports:
      - '127.0.0.1:{web}:8006'
      - '127.0.0.1:{rdp}:3389/tcp'
    volumes:
      - './storage:/storage'
      - './exchange:/shared'
      - './oem:/oem:ro'
      - '../media/{MEDIA[version]['file']}:/custom.iso:ro'
    restart: 'no'
    stop_grace_period: 2m
''')


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=("prepare", "verify", "status", "up", "stop", "identity", "screenshot",
                                            "keys", "type", "type-secret", "click", "stage-validation",
                                            "rehearsal-layout"))
    parser.add_argument("items", nargs="*", help="keys: QEMU qcodes such as meta_l-r or ctrl-alt-delete; type: text")
    parser.add_argument("--root", type=Path, default=ROOT / ".local" / "windows-vm")
    parser.add_argument("--version", choices=tuple(MEDIA), default="win11")
    parser.add_argument("--docker", help="docker CLI (default $GX_GHOSTTY_DOCKER, PATH or Docker Desktop)")
    parser.add_argument("--guest-uuid", help="must equal the live QEMU UUID when given")
    parser.add_argument("--guest-name", help="defaults to machine.json host")
    parser.add_argument("--out", type=Path, help="screenshot PNG, compose log or rehearsal directory")
    parser.add_argument("--field", choices=CREDENTIAL_FIELDS)
    parser.add_argument("--enter", action="store_true", help="press Enter after type-secret or type")
    parser.add_argument("--channel", choices=("hmp", "vnc"), default="hmp",
                        help="type/type-secret input path: QEMU monitor sendkey or QEMU VNC keysyms")
    parser.add_argument("--x", type=int)
    parser.add_argument("--y", type=int)
    parser.add_argument("--button", choices=("left", "middle", "right"), default="left")
    parser.add_argument("--count", type=int, default=1)
    parser.add_argument("--slot-timeout", type=float, default=0)
    parser.add_argument("--app", type=Path, help="rehearsal-layout: old ghostty.exe")
    parser.add_argument("--share", type=Path, help="rehearsal-layout: prefix share/ directory")
    parser.add_argument("--cache-dir", type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    try:
        if args.command == "prepare":
            prepare(root)
            print("Prepared isolated VM configuration; credentials remain local and are not displayed.")
            return 0
        if args.command == "verify":
            spec = MEDIA[args.version]
            path = root / "media" / spec["file"]
            candidate = path if path.exists() else path.with_suffix(path.suffix + ".part")
            digest = verify_media(candidate, spec)
            if candidate != path:
                candidate.rename(path)
            write(path.with_suffix(".receipt.json"), json.dumps({
                "verified_utc": utc_now(), "file": path.name, "sha256": digest, "size": spec["size"],
                "source": spec["url"], "image": IMAGE}, indent=2) + "\n")
            print(f"PASS {args.version}: {digest}")
            return 0
        if args.command == "rehearsal-layout":
            if args.app is None or args.out is None:
                raise VmError("rehearsal-layout requires --app and --out")
            print(json.dumps(rehearsal_layout(args.app, args.out.resolve(), args.share, args.cache_dir), indent=2))
            return 0
        docker = Docker(docker_executable(args.docker))
        if args.command == "status":
            print(json.dumps({version: container_state(docker, version) for version in MEDIA}, indent=2))
        elif args.command == "up":
            if args.out is None:
                raise VmError("up requires --out for the compose log")
            return up(root, args.version, docker, args.out.resolve(), args.slot_timeout)
        elif args.command == "stop":
            print(json.dumps(stop(root, args.version, docker), indent=2))
        elif args.command == "identity":
            machine = machine_identity(root, args.version)
            live = live_uuid(docker, args.version)
            print(json.dumps({"container": container_name(args.version), "live_uuid": live,
                              "machine_uuid": machine["uuid"], "match": live == machine["uuid"],
                              "guest_name": machine["host"]}, indent=2))
            if live != machine["uuid"]:
                return 1
        elif args.command == "screenshot":
            if args.out is None:
                raise VmError("screenshot requires --out")
            print(json.dumps(screenshot(docker, args.version, args.out.resolve()), indent=2))
        elif args.command == "keys":
            print(json.dumps({"sent": send_keys(docker, args.version, args.items)}))
        elif args.command == "type":
            text = " ".join(args.items)
            if args.channel == "vnc":
                vnc_send(docker, args.version, vnc_text_events(text + ("\n" if args.enter else "")))
                print(json.dumps({"sent": len(text) + (1 if args.enter else 0), "channel": "vnc"}))
            else:
                keys = text_keys(text) + (["ret"] if args.enter else [])
                print(json.dumps({"sent": send_keys(docker, args.version, keys), "channel": "hmp"}))
        elif args.command == "type-secret":
            if args.field is None:
                raise VmError("type-secret requires --field")
            typer = type_secret_vnc if args.channel == "vnc" else type_secret
            count = typer(root, args.version, docker, args.field, args.enter)
            print(json.dumps({"typed_characters": count, "enter": args.enter, "channel": args.channel,
                              "value_printed": False}))
        elif args.command == "click":
            if args.x is None or args.y is None or not 1 <= args.count <= 3:
                raise VmError("click requires --x and --y (VM screen pixels) and --count 1-3")
            print(json.dumps({"clicked": [args.x, args.y], "button": args.button, "count": args.count,
                              "screen": vnc_click(docker, args.version, args.x, args.y, args.button, args.count)}))
        else:
            live = live_uuid(docker, args.version)
            if args.guest_uuid and str(uuid.UUID(args.guest_uuid)) != live:
                raise VmError("--guest-uuid differs from the live QEMU UUID")
            name = args.guest_name or machine_identity(root, args.version)["host"]
            destination = stage_validation(root, args.version, live, name)
            print(f"Staged guest-only validation fixture: {destination}")
    except (OSError, ValueError, VmError, subprocess.SubprocessError) as exc:
        parser.exit(1, f"ERROR: {exc}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
