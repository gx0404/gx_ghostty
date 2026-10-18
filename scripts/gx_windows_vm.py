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
                     refuses while another owned VM runs; never pulls (--pull never). compose.yaml
                     must equal the generated file; an existing container must match its owner
                     label, image, compose file, mounts and UUID, else --replace-container <ID>.
                     A replaced container from another compose project (for example one created
                     before machine.json existed) is removed by its exact ID first ("rebind"):
                     compose cannot recreate a fixed container_name it does not own. Its disk is a
                     bind mount under --root and is kept; containers with other mounts are refused.
                     --dry-run prints that plan and changes nothing
  stop               ACPI shutdown through docker compose stop; storage and disk are kept
  identity           live SMBIOS UUID (HMP info uuid) compared with machine.json
  screenshot         HMP screendump of the VM screen to a new PNG
  keys / type        HMP sendkey with QEMU qcodes, or US-keyboard ASCII text (--channel vnc
                     sends keysyms through the container's QEMU VNC server instead)
  type-secret        type a credentials.json field; the value never reaches argv or output
  pointer            read-only HMP info mice: which QEMU mouse receives VNC pointer input now;
                     exits 1 unless it is an absolute device (usb-tablet)
  click              pointer click at VM screen pixels through the container's QEMU VNC server
  drag               press at --x/--y, move in --steps to --to-x/--to-y, dwell --hold-ms, release
                     (VNC pointer; a real OLE drag in the guest, never the host desktop). click and
                     drag first require an absolute current mouse (a relative one turns the
                     coordinates into motion from wherever the guest cursor is), report the mode
                     before and after, and refuse points outside the VNC screen unsent
  queue-args         write one argument line to the staged q/<name>.txt for gx-q.cmd (the guest Run
                     box takes 259 characters); "cmd /c start "" /min cmd /c ...\\gx-q.cmd <name>" runs
                     it minimized without taking the guest foreground
  stage-validation   stage the guest fixture after checking the live VM identity; with --guest-python
                     (the pinned python.org embeddable zip, downloaded explicitly) and --ole-source it
                     also stages the broker Python fixture for the guest's py-fixture phase
  rehearsal-layout   ghostty.exe plus pinned ConPTY/Mesa from the offline package cache, marked
                     REHEARSAL_NOT_FINAL, for GL rehearsal before the frozen installer exists
"""
from __future__ import annotations

import argparse
import ast
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
QUEUE_RUNNER = "gx-q.cmd"
QUEUE_NAME = re.compile(r"[a-z0-9][a-z0-9-]{0,31}")
# gx-q.cmd expands the line once with set /p and again through call: keep cmd metacharacters out.
QUEUE_UNSAFE = re.compile(r"[%!^&|<>\r\n\t]")
MONITOR = "/run/shm/monitor.sock"
PORTS = {"win11": (18006, 13389), "win10": (18007, 13390)}
CREDENTIAL_FIELDS = ("admin_password", "user_password")
QCODE = re.compile(r"^[a-z0-9_]+(-[a-z0-9_]+)*$")
UUID_TEXT = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
REHEARSAL_PAYLOAD = ("conpty.dll", "OpenConsole.exe", "mesa/opengl32.dll", "mesa/libgallium_wgl.dll", "mesa/dxil.dll")
# The guest has no Python; the Python fixtures run on this python.org Windows embeddable package,
# used inside the VM only. Its SHA-256 is the package checksum in the python.org SBOM
# (python-3.12.10-embed-amd64.zip.spdx.json); the release page's MD5 is fe8ef205f2e9c3ba44d0cf9954e1abd3.
# The host downloads it explicitly; stage-validation only checks and copies it.
GUEST_PYTHON = {
    "version": "3.12.10",
    "file": "python-3.12.10-embed-amd64.zip",
    "url": "https://www.python.org/ftp/python/3.12.10/python-3.12.10-embed-amd64.zip",
    "size": 11133606,
    "sha256": "4acbed6dd1c744b0376e3b1cf57ce906f9dc9e95e68824584c8099a63025a3c3",
}
# The broker fixture; stage-validation adds every test/windows or scripts module it imports.
BROKER_ENTRY = "test/windows/gx_drop_broker_fixture.py"
FIXTURE_FOLDERS = ("test/windows", "scripts")
# Path-based reads are invisible to the import AST. Keep them in the same
# source/ref and hash tree as their consumer (source_manifest in newer refs).
FIXTURE_RUNTIME_DEPENDENCIES = {
    "test/windows/gx_fixture_evidence.py": ("scripts/gx_win_uia.py",),
}
OLE_SOURCE_NAME = "gx_ole_source.exe"
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

    def __init__(self, executable: str, runner=None, root: Path | None = None):
        self.executable = executable
        # Resolved per call so a patched subprocess.run is honoured (no import-time capture).
        self.runner = runner
        # When set, every live-container operation also checks the compose/mount binding.
        self.root = root

    def run(self, *args: str, input: str | bytes | None = None, timeout: float = 120, text: bool = True,
            check: bool = True) -> subprocess.CompletedProcess:
        runner = self.runner or subprocess.run
        result = runner([self.executable, *args], input=input, capture_output=True, text=text,
                        timeout=timeout)
        if check and result.returncode != 0:
            detail = result.stderr if text else result.stderr.decode("utf-8", "replace")
            raise VmError(f"docker {args[0]} failed ({result.returncode}): {str(detail).strip()[:400]}")
        return result


def container_name(version: str) -> str:
    return f"gx-ghostty-{version}"


def same_host_path(a: str, b: str | Path) -> bool:
    return os.path.normcase(os.path.normpath(str(a))) == os.path.normcase(os.path.normpath(str(b)))


def expected_binding(root: Path, version: str) -> dict:
    base = Path(root).resolve() / version
    return {"project": container_name(version), "config_file": base / "compose.yaml", "working_dir": base,
            "mounts": {"/storage": base / "storage", "/shared": base / "exchange", "/oem": base / "oem",
                       "/custom.iso": Path(root).resolve() / "media" / MEDIA[version]["file"]},
            "machine": machine_identity(root, version)}


def binding_errors(data: dict, root: Path, version: str) -> list[str]:
    """Why an existing container is not the one the pinned compose under root would run.

    Compares owner label, pinned image, compose project/config file/working directory, every bind
    mount's absolute host path and the SMBIOS UUID/HOST variables. Other environment values
    (credentials) are never read into the result."""
    expected = expected_binding(root, version)
    config = data.get("Config") or {}
    labels = config.get("Labels") or {}
    errors = []
    if labels.get("gx.owner") != OWNER:
        errors.append("owner label differs")
    if config.get("Image") != IMAGE:
        errors.append("image is not the pinned digest")
    if labels.get("com.docker.compose.project") != expected["project"]:
        errors.append("compose project differs")
    if not same_host_path(labels.get("com.docker.compose.project.config_files", ""), expected["config_file"]):
        errors.append("created from another compose file: " + labels.get("com.docker.compose.project.config_files", "<none>"))
    if not same_host_path(labels.get("com.docker.compose.project.working_dir", ""), expected["working_dir"]):
        errors.append("compose working directory differs")
    mounts = {item.get("Destination"): item for item in data.get("Mounts") or []}
    for destination, source in expected["mounts"].items():
        mount = mounts.get(destination)
        if mount is None or mount.get("Type") != "bind" or not same_host_path(mount.get("Source", ""), source):
            errors.append(f"{destination} is not bound to {source}")
    if set(mounts) - set(expected["mounts"]):
        errors.append("unexpected extra mounts")
    env = {}
    for item in config.get("Env") or []:
        name, _, value = str(item).partition("=")
        if name in ("UUID", "HOST"):
            env[name] = value
    if env.get("UUID") != expected["machine"]["uuid"]:
        errors.append("SMBIOS UUID differs from machine.json")
    if env.get("HOST") != expected["machine"]["host"]:
        errors.append("guest HOST differs from machine.json")
    return errors


def disk_facts(root: Path, version: str) -> dict:
    """The VM disk a (re)created container will boot; read-only."""
    disk = Path(root).resolve() / version / "storage" / "data.qcow2"
    if not disk.is_file():
        return {"path": str(disk), "exists": False}
    stat = disk.stat()
    return {"path": str(disk), "exists": True, "size": stat.st_size,
            "modified_utc": datetime.fromtimestamp(stat.st_mtime, timezone.utc).isoformat()}


def plan_up(root: Path, version: str, docker: Docker, replace_container: str | None = None) -> dict:
    """How up would start version without changing anything: reuse, create, replace or rebind.

    replace: the stopped owned container belongs to this compose project, so compose
    --force-recreate replaces it. rebind: it belongs to another project (or none), so compose
    would collide with the fixed container_name; up removes exactly that container first."""
    root = Path(root).resolve()
    plan = {"version": version, "container": container_name(version), "machine": machine_identity(root, version),
            "disk": disk_facts(root, version), "mode": "create", "remove_container": None, "binding_errors": []}
    data = inspect_container(docker, version)
    if data is None:
        return plan
    full_id = data.get("Id", "")
    config = data.get("Config") or {}
    labels = config.get("Labels") or {}
    plan["existing"] = {"id": full_id, "running": bool((data.get("State") or {}).get("Running")),
                        "compose_project": labels.get("com.docker.compose.project")}
    errors = binding_errors(data, root, version)
    if not errors:
        plan["mode"] = "reuse"
        return plan
    plan["binding_errors"] = errors
    owned = labels.get("gx.owner") == OWNER and config.get("Image") == IMAGE
    if (not replace_container or len(replace_container) < 12 or not full_id.startswith(replace_container)
            or not owned or plan["existing"]["running"]):
        raise VmError(f"{container_name(version)} ({full_id[:12]}) does not match this VM root: "
                      + "; ".join(errors) + ". Inspect it; pass --replace-container <its ID> only "
                      "for a stopped owned container that may be replaced (bind-mounted disks are kept).")
    other = sorted({str(item.get("Type")) for item in data.get("Mounts") or [] if item.get("Type") != "bind"})
    if other:
        raise VmError(f"{container_name(version)} has non-bind mounts ({', '.join(other)}); replacing it could "
                      "detach their data, so nothing was changed")
    if labels.get("com.docker.compose.project") == container_name(version):
        plan["mode"] = "replace"
    else:
        plan["mode"] = "rebind"
        plan["remove_container"] = full_id
    return plan


def inspect_container(docker: Docker, version: str) -> dict | None:
    result = docker.run("inspect", "--type", "container", container_name(version), check=False)
    return json.loads(result.stdout)[0] if result.returncode == 0 else None


def container_state(docker: Docker, version: str) -> dict:
    name = container_name(version)
    data = inspect_container(docker, version)
    if data is None:
        return {"name": name, "exists": False, "running": False}
    config = data.get("Config") or {}
    labels = config.get("Labels") or {}
    state = data.get("State") or {}
    result = {"name": name, "exists": True, "id": data.get("Id", "")[:12], "full_id": data.get("Id", ""),
              "owned": labels.get("gx.owner") == OWNER and config.get("Image") == IMAGE,
              "running": bool(state.get("Running")), "status": state.get("Status"),
              "exit_code": state.get("ExitCode"), "oom_killed": state.get("OOMKilled"),
              "started_at": state.get("StartedAt"), "finished_at": state.get("FinishedAt"),
              "uuid_configured": any(str(item).startswith("UUID=") for item in config.get("Env") or [])}
    if docker.root is not None:
        result["binding_errors"] = binding_errors(data, docker.root, version)
    return result


def require_running(docker: Docker, version: str) -> dict:
    state = container_state(docker, version)
    if not state["exists"] or not state.get("owned"):
        raise VmError(f"{state['name']} is not the owned, digest-pinned validation container")
    if state.get("binding_errors"):
        raise VmError(f"{state['name']} is not bound to this VM root: " + "; ".join(state["binding_errors"]))
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
    if event[0] == "p" and not (0 <= event[1] < width and 0 <= event[2] < height):
        raise SystemExit("pointer %d,%d is outside the %dx%d VNC screen; no event was sent"
                         % (event[1], event[2], width, height))
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


VNC_COORD_MAX = 0xFFFF
DRAG_STEPS = (2, 60)
DRAG_HOLD_MS = (0, 5000)
BUTTON_MASKS = {"left": 1, "middle": 2, "right": 4}
# One HMP "info mice" line, e.g. "* Mouse #2: QEMU HID Tablet (absolute)". "*" marks the device that
# receives pointer input: the one QEMU's VNC server asks whether coordinates are absolute.
MOUSE_LINE = re.compile(r"([* ]) Mouse #(\d+): (.*?)( \(absolute\))?$")


def parse_mice(text: str) -> list[dict]:
    mice = []
    for line in clean_monitor(text).splitlines():
        found = MOUSE_LINE.search(line.rstrip())
        if found:
            mice.append({"index": int(found.group(2)), "name": found.group(3),
                         "absolute": found.group(4) is not None, "current": found.group(1) == "*"})
    return mice


def pointer_mode(docker: Docker, version: str) -> dict:
    """Which QEMU mouse receives VNC pointer events right now (read-only HMP info mice).

    QEMU's VNC server passes RFB coordinates on as positions only when this device is absolute; for
    a relative one it sends motion deltas, so a correct packet still lands at the guest cursor.
    Nothing here switches devices."""
    mice = parse_mice(hmp(docker, version, ["info mice"]))
    current = [mouse for mouse in mice if mouse["current"]]
    active = current[0] if len(current) == 1 else None
    return {"absolute": bool(active and active["absolute"]), "current": active, "devices": mice,
            "source": "HMP info mice", "checked_utc": utc_now()}


def require_absolute_pointer(docker: Docker, version: str) -> dict:
    mode = pointer_mode(docker, version)
    if not mode["absolute"]:
        current = mode["current"]
        name = current["name"] if current else ("no single current mouse" if mode["devices"] else "no mouse reported")
        raise VmError(f"VNC pointer input is not absolute (current QEMU mouse: {name}); the coordinates would "
                      "become relative motion from the guest cursor, so nothing was sent. Use keyboard input; "
                      "switching the mouse device needs an authorized VM runtime change.")
    return mode


def vnc_pointer(docker: Docker, version: str, events: list) -> dict:
    """Send pointer events only while the current QEMU mouse is absolute and report the mode before
    and after: a correct RFB packet is not enough when the device that receives it is relative."""
    before = require_absolute_pointer(docker, version)
    screen = vnc_send(docker, version, events)
    after = pointer_mode(docker, version)
    if not after["absolute"]:
        raise VmError("the current QEMU mouse stopped being absolute while the pointer events were sent; "
                      "treat that input as unverified")
    return {"screen": screen, "pointer": {"before": before, "after": after}}


def vnc_click_events(x: int, y: int, button: str = "left", count: int = 1) -> list:
    if button not in BUTTON_MASKS:
        raise VmError("click button must be left, middle or right")
    if not 1 <= count <= 3:
        raise VmError("click --count must be 1-3")
    for value in (x, y):
        if not 0 <= value <= VNC_COORD_MAX:
            raise VmError("click coordinates must be VM screen pixels")
    mask = BUTTON_MASKS[button]
    events: list = [["p", x, y, 0], ["s", 0.15]]
    for _ in range(count):
        events += [["p", x, y, mask], ["s", 0.08], ["p", x, y, 0], ["s", 0.08]]
    return events


def vnc_click(docker: Docker, version: str, x: int, y: int, button: str = "left", count: int = 1) -> dict:
    return vnc_pointer(docker, version, vnc_click_events(x, y, button, count))


def vnc_drag_events(x: int, y: int, to_x: int, to_y: int, button: str = "left", steps: int = 12,
                    hold_ms: int = 300) -> list:
    """Press, move in `steps` interpolated moves with the button held, dwell, release at the target.

    The first move after the press crosses the Windows drag threshold, so the guest's
    DragDetect/DoDragDrop sees a real drag; the dwell lets DragEnter/DragOver settle."""
    if button not in ("left", "middle", "right"):
        raise VmError("drag button must be left, middle or right")
    for value in (x, y, to_x, to_y):
        if not 0 <= value <= VNC_COORD_MAX:
            raise VmError("drag coordinates must be VM screen pixels")
    if (x, y) == (to_x, to_y):
        raise VmError("drag needs distinct start and end points")
    if not DRAG_STEPS[0] <= steps <= DRAG_STEPS[1]:
        raise VmError(f"drag --steps must be {DRAG_STEPS[0]}-{DRAG_STEPS[1]}")
    if not DRAG_HOLD_MS[0] <= hold_ms <= DRAG_HOLD_MS[1]:
        raise VmError(f"drag --hold-ms must be {DRAG_HOLD_MS[0]}-{DRAG_HOLD_MS[1]}")
    mask = {"left": 1, "middle": 2, "right": 4}[button]
    events: list = [["p", x, y, 0], ["s", 0.15], ["p", x, y, mask], ["s", 0.15]]
    for step in range(1, steps + 1):
        px = x + round((to_x - x) * step / steps)
        py = y + round((to_y - y) * step / steps)
        events += [["p", px, py, mask], ["s", 0.04]]
    events += [["s", hold_ms / 1000], ["p", to_x, to_y, 0], ["s", 0.15]]
    return events


def vnc_drag(docker: Docker, version: str, x: int, y: int, to_x: int, to_y: int, button: str = "left",
             steps: int = 12, hold_ms: int = 300) -> dict:
    return vnc_pointer(docker, version, vnc_drag_events(x, y, to_x, to_y, button, steps, hold_ms))


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


def slots_root(gx_slots) -> Path:
    """The kernel-slot root shared by the main checkout and all of its worktrees.

    gx_slots.shared_root resolves it from git's common directory. A checkout-relative
    `.local/kernel-slots` gave each worktree its own locks, so a VM started from a worktree did not
    exclude heavy jobs of the main checkout (or of another worktree)."""
    shared = getattr(gx_slots, "shared_root", None)
    if not callable(shared):
        raise VmError("scripts/gx_slots.py has no shared_root(); merge the shared slot root "
                      "(wip/r6-a2-perf-tools) before starting a VM")
    return Path(shared())


def up(root: Path, version: str, docker: Docker, log_path: Path, slot_timeout: float,
       replace_container: str | None = None, dry_run: bool = False) -> int:
    """Run the VM attached while holding one heavy gx_slots slot.

    The compose file must equal the generated pinned configuration byte for byte. An existing
    container is reused only if its binding matches (no recreation); a mismatched container is
    refused unless its exact ID is passed as replace_container and it is stopped and owned
    (plan_up). dry_run reports the plan without a slot, removal or compose call."""
    sys.path.insert(0, str(SCRIPTS))
    import gx_slots

    root = Path(root).resolve()
    compose = root / version / "compose.yaml"
    machine = machine_identity(root, version)
    if compose.read_text(encoding="utf-8") != compose_text(version, machine):
        raise VmError("compose.yaml is not the generated pinned, UUID-bound configuration; run prepare first")
    if dry_run:
        running = [container_name(other) for other in MEDIA if container_state(docker, other)["running"]]
        plan = plan_up(root, version, docker, replace_container)
        print(json.dumps({"event": "compose-up-plan", "dry_run": True, "running_owned_vms": running, **plan}, indent=2),
              flush=True)
        return 0
    docker.run("image", "inspect", IMAGE)  # must already be cached; never pulled
    with gx_slots.acquire(slots_root(gx_slots), "heavy", slot_timeout):
        for other in MEDIA:
            if container_state(docker, other)["running"]:
                raise VmError(f"{container_name(other)} is already running; only one owned VM may run")
        plan = plan_up(root, version, docker, replace_container)
        mode, record = plan["mode"], None
        if mode in ("replace", "rebind"):
            record = {"replaced_container": plan["existing"]["id"], "binding_errors": plan["binding_errors"],
                      "disk": plan["disk"], "utc": utc_now()}
        if plan["remove_container"]:
            # Exact full ID of the stopped, owned container: no -f, no -v; bind-mounted disks stay.
            docker.run("rm", plan["remove_container"])
            record["removed_before_create"] = True
        extra = {"reuse": ["--no-recreate"], "replace": ["--force-recreate"], "rebind": [], "create": []}[mode]
        log_path.parent.mkdir(parents=True, exist_ok=True)
        with log_path.open("ab") as stream:
            child = subprocess.Popen(
                [docker.executable, "compose", "-p", container_name(version), "-f", str(compose),
                 "up", "--pull", "never", "--no-build", "--no-color", *extra],
                cwd=compose.parent, stdin=subprocess.DEVNULL, stdout=stream, stderr=subprocess.STDOUT)
            print(json.dumps({"event": "compose-up", "mode": mode, "pid": child.pid, "slot": "heavy",
                              "log": str(log_path), "utc": utc_now(), **({"replace": record} if record else {})}),
                  flush=True)
            while True:
                try:
                    return child.wait()
                except KeyboardInterrupt:
                    # Keep the heavy slot until the VM has actually stopped.
                    continue


def stop(root: Path, version: str, docker: Docker) -> dict:
    data = inspect_container(docker, version)
    if data is None:
        raise VmError(f"{container_name(version)} does not exist")
    errors = binding_errors(data, root, version)
    if errors:
        raise VmError(f"{container_name(version)} is not bound to this VM root: " + "; ".join(errors))
    if (data.get("State") or {}).get("Running"):
        compose = Path(root).resolve() / version / "compose.yaml"
        docker.run("compose", "-p", container_name(version), "-f", str(compose), "stop", "-t", "180",
                   timeout=300)
    return container_state(docker, version)


def verify_guest_python(path: Path) -> str:
    if Path(path).stat().st_size != GUEST_PYTHON["size"] or sha256_file(path) != GUEST_PYTHON["sha256"]:
        raise ValueError(f"{path} is not the pinned {GUEST_PYTHON['file']} (size/SHA256 differ)")
    return GUEST_PYTHON["sha256"]


def working_tree_reader(relative: str) -> bytes | None:
    path = ROOT / relative
    return path.read_bytes() if path.is_file() else None


def git_reader(ref: str):
    """Files as committed at ref (such as a fixture branch that is not merged yet); None if absent."""
    found = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "--verify", "--quiet", ref + "^{commit}"],
                           capture_output=True, text=True)
    if found.returncode != 0 or not found.stdout.strip():
        raise ValueError(f"--fixture-ref {ref} is not a commit of this repository")
    commit = found.stdout.strip()

    def read(relative: str) -> bytes | None:
        shown = subprocess.run(["git", "-C", str(ROOT), "show", f"{commit}:{relative}"], capture_output=True)
        return shown.stdout if shown.returncode == 0 else None

    read.commit = commit
    return read


def fixture_closure(read, entry: str = BROKER_ENTRY) -> dict[str, bytes]:
    """Repository imports plus required path-based runtime dependencies, from one reader."""
    files: dict[str, bytes] = {}
    pending = [(entry, True)]
    while pending:
        relative, required = pending.pop()
        if relative in files:
            continue
        data = read(relative)
        if data is None:
            if required:
                raise ValueError(f"{relative} is missing from the fixture source")
            continue
        files[relative] = data
        pending.extend((path, True) for path in FIXTURE_RUNTIME_DEPENDENCIES.get(relative, ()))
        for node in ast.walk(ast.parse(data.decode("utf-8"), relative)):
            if isinstance(node, ast.Import):
                names = [alias.name for alias in node.names]
            elif isinstance(node, ast.ImportFrom) and node.module and node.level == 0:
                names = [node.module]
            else:
                continue
            pending.extend((f"{folder}/{name.split('.')[0]}.py", False)
                           for name in names for folder in FIXTURE_FOLDERS)
    return dict(sorted(files.items()))


def stage_python_fixture(destination: Path, guest_python: Path, ole_source: Path, fixture_ref: str | None = None) -> dict:
    """Copy the pinned embeddable Python, the broker fixture files and the OLE source to py/.

    The fixture files come from the working tree, or as committed at fixture_ref."""
    verify_guest_python(guest_python)
    read = working_tree_reader if fixture_ref is None else git_reader(fixture_ref)
    sources = fixture_closure(read)
    folder = destination / "py"
    folder.mkdir(exist_ok=True)
    shutil.copyfile(guest_python, folder / GUEST_PYTHON["file"])
    verify_guest_python(folder / GUEST_PYTHON["file"])
    files = {}
    for relative, data in sources.items():
        target = folder / Path(relative)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        files[relative] = hashlib.sha256(data).hexdigest()
    ole = Path(ole_source).read_bytes()
    if not ole.startswith(b"MZ"):
        raise ValueError(f"{ole_source} is not a Windows executable")
    (folder / OLE_SOURCE_NAME).write_bytes(ole)
    tree = "\n".join(f"{name}={digest}" for name, digest in sorted(files.items()))
    return {"python": {key: GUEST_PYTHON[key] for key in ("version", "file", "sha256", "url")},
            "files": files, "tree_sha256": hashlib.sha256(tree.encode("utf-8")).hexdigest(),
            "ole_source": {"file": OLE_SOURCE_NAME, "sha256": hashlib.sha256(ole).hexdigest(),
                           "source_name": Path(ole_source).name},
            "source": {"ref": fixture_ref, "commit": getattr(read, "commit", None),
                       "kind": "working tree" if fixture_ref is None else "git"}}


def stage_validation(root: Path, version: str, guest_uuid: str, guest_name: str,
                     guest_python: Path | None = None, ole_source: Path | None = None,
                     fixture_ref: str | None = None) -> Path:
    """Stage a guest-only fixture; never touch Docker, host accounts or registry.

    With guest_python (the pinned embeddable package) and ole_source, the broker fixture is staged
    as well (py/ and the manifest's python_fixture) for the guest's py-fixture phase."""
    if (guest_python is None) != (ole_source is None):
        raise ValueError("--guest-python and --ole-source stage the broker fixture together")
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
    if guest_python is not None:
        verify_guest_python(guest_python)
    script_bytes = VALIDATION_SCRIPT.read_bytes()
    destination.mkdir(parents=True, exist_ok=True)
    (destination / "out").mkdir(exist_ok=True)
    (destination / VALIDATION_SCRIPT.name).write_bytes(script_bytes)
    python_fixture = (stage_python_fixture(destination, guest_python, ole_source, fixture_ref)
                      if guest_python is not None else None)
    write(previous, json.dumps({
        "schema": 1, "owner": OWNER, "image": IMAGE, "version": version,
        "guest_uuid": str(machine_uuid), "guest_name": guest_name,
        "fixture_sha256": hashlib.sha256(script_bytes).hexdigest(),
        "setup_sha256": sha256_file(setup),
        "python_fixture": python_fixture,
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
    (destination / "q").mkdir(exist_ok=True)
    write(destination / QUEUE_RUNNER, (
        "@echo off\r\n"
        "rem Runs gx-run.cmd with the argument line in q\\<name>.txt (gx_windows_vm.py queue-args);\r\n"
        "rem the Run box takes 259 characters. Without taking the current foreground (status steps):\r\n"
        "rem   cmd /c start \"\" /min cmd /c \\\\host.lan\\Data\\validation\\gx-q.cmd <name>\r\n"
        "setlocal\r\n"
        "if \"%~1\"==\"\" exit /b 2\r\n"
        "set \"GXARGS=\"\r\n"
        "set /p GXARGS=<\"%~dp0q\\%~1.txt\"\r\n"
        "if not defined GXARGS exit /b 2\r\n"
        "call \"%~dp0" + GUEST_RUNNER + "\" %GXARGS%\r\n"
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

参数超过 Run 框 259 字符时，宿主用 queue-args --name <名> -- <参数…> 写 q\\<名>.txt，客机运行 cmd /c \\\\host.lan\\Data\\validation\\gx-q.cmd <名>。读状态的步骤（toast-matrix status、jumplist-matrix observe 等）要记录当前前台时，参数加 -DelaySeconds 5，并以 cmd /c start "" /min cmd /c \\\\host.lan\\Data\\validation\\gx-q.cmd <名> 最小化、不激活地启动，前台保持操作者留下的窗口。

Python 夹具（broker）：宿主以 stage-validation --guest-python <钉版 embeddable zip> --ole-source <gx_ole_source.exe> 暂存，py\\ 下是 SHA-256 列在清单 python_fixture 里的解释器包、夹具 .py 与 OLE source。客机里 -Phase py-fixture -PyArgs "<夹具参数>" 逐个复核哈希，在 LOCALAPPDATA 下解压一次解释器并把 ._pth 指向夹具树，以调用者自己的令牌运行（medium 用 Run 框回车，high 用 Ctrl+Shift+Enter；不提权）。-PyArgs 里 {run}、{app}、{app_sha256}、{ole}、{ole_sha256} 展开为本 run 的值；退出码 0/2/其他记 PASS/PENDING/FAIL，夹具本步写出的文件以 py-<相对路径> 导出。

r6 相位 run-config、osc52、toast-matrix、jumplist-matrix、narrator、cross-account、dpi 用 -Action 分步执行（start/status/collect/stop 等，每个相位只接受自己的步骤），记录写在 Runs\\<RunId>\\records，每份报告带 before、after 与 restore。只关闭本夹具启动或明确收编的进程；剪贴板只在 osc52 里由终端内探针写入测试内容；改动的设置（通知、真实配置、讲述人、DPI、JumpList ACL）都先备份再恢复；跨账户密码只经宿主 type-secret 输入。
""")
    return destination


def queue_args(root: Path, version: str, name: str, items: list[str]) -> Path:
    """Write q/<name>.txt: one argument line for the staged gx-q.cmd (quoted like a command line)."""
    if not QUEUE_NAME.fullmatch(name):
        raise ValueError("queue-args --name takes 1-32 lowercase letters, digits and hyphens")
    line = subprocess.list2cmdline(items)
    if not items or len(line) > 1000 or not line.isascii() or QUEUE_UNSAFE.search(line):
        raise ValueError("queue-args takes a non-empty ASCII line of at most 1000 characters without % ! ^ & | < > or control characters")
    exchange = (Path(root) / version / "exchange").resolve(strict=True)
    destination = (exchange / "validation").resolve()
    if not destination.is_relative_to(exchange) or not (destination / "validation-manifest.json").is_file():
        raise ValueError("Run stage-validation first: the staged validation directory has no manifest")
    folder = destination / "q"
    folder.mkdir(exist_ok=True)
    path = folder / f"{name}.txt"
    write(path, line + "\r\n")
    return path


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


def compose_text(version: str, machine: dict) -> str:
    """The only accepted compose.yaml for version; up compares the file to this exactly."""
    web, rdp = PORTS[version]
    return f'''services:
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
'''


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
        write(base / "compose.yaml", compose_text(version, machine))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=("prepare", "verify", "status", "up", "stop", "identity", "screenshot",
                                            "keys", "type", "type-secret", "pointer", "click", "drag", "stage-validation",
                                            "queue-args",
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
    parser.add_argument("--to-x", type=int, help="drag: end point (VM screen pixels)")
    parser.add_argument("--to-y", type=int)
    parser.add_argument("--steps", type=int, default=12, help="drag: interpolated moves while held (2-60)")
    parser.add_argument("--hold-ms", type=int, default=300, help="drag: dwell at the end point before release")
    parser.add_argument("--slot-timeout", type=float, default=0)
    parser.add_argument("--replace-container", help="up: exact ID (12+ hex) of a stopped, owned but mismatched "
                        "container that may be recreated from the pinned compose; disks are bind mounts and kept")
    parser.add_argument("--dry-run", action="store_true", help="up: print the reuse/create/replace/rebind plan only")
    parser.add_argument("--app", type=Path, help="rehearsal-layout: old ghostty.exe")
    parser.add_argument("--share", type=Path, help="rehearsal-layout: prefix share/ directory")
    parser.add_argument("--cache-dir", type=Path)
    parser.add_argument("--guest-python", type=Path, help="stage-validation: the pinned " + GUEST_PYTHON["file"]
                        + " (downloaded explicitly from " + GUEST_PYTHON["url"] + ")")
    parser.add_argument("--ole-source", type=Path, help="stage-validation: gx_ole_source.exe for the broker fixture")
    parser.add_argument("--name", help="queue-args: q/<name>.txt for gx-q.cmd <name>")
    parser.add_argument("--fixture-ref", help="stage-validation: take the broker fixture files as committed at this git ref")
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
        if args.command == "queue-args":
            if args.name is None:
                raise VmError("queue-args requires --name")
            path = queue_args(root, args.version, args.name, args.items)
            print(json.dumps({"queued": str(path), "line": path.read_text(encoding="utf-8").strip()}))
            return 0
        if args.command == "rehearsal-layout":
            if args.app is None or args.out is None:
                raise VmError("rehearsal-layout requires --app and --out")
            print(json.dumps(rehearsal_layout(args.app, args.out.resolve(), args.share, args.cache_dir), indent=2))
            return 0
        docker = Docker(docker_executable(args.docker), root=root)
        if args.command == "status":
            print(json.dumps({version: container_state(docker, version) for version in MEDIA}, indent=2))
        elif args.command == "up":
            if args.dry_run:
                return up(root, args.version, docker, Path(os.devnull), args.slot_timeout, args.replace_container,
                          dry_run=True)
            if args.out is None:
                raise VmError("up requires --out for the compose log")
            return up(root, args.version, docker, args.out.resolve(), args.slot_timeout, args.replace_container)
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
        elif args.command == "pointer":
            mode = pointer_mode(docker, args.version)
            print(json.dumps(mode, indent=2))
            if not mode["absolute"]:
                return 1
        elif args.command == "click":
            if args.x is None or args.y is None or not 1 <= args.count <= 3:
                raise VmError("click requires --x and --y (VM screen pixels) and --count 1-3")
            events = vnc_click_events(args.x, args.y, args.button, args.count)
            print(json.dumps({"clicked": [args.x, args.y], "button": args.button, "count": args.count,
                              **vnc_pointer(docker, args.version, events)}))
        elif args.command == "drag":
            if None in (args.x, args.y, args.to_x, args.to_y):
                raise VmError("drag requires --x --y --to-x --to-y (VM screen pixels)")
            events = vnc_drag_events(args.x, args.y, args.to_x, args.to_y, args.button, args.steps, args.hold_ms)
            print(json.dumps({"dragged": [[args.x, args.y], [args.to_x, args.to_y]], "button": args.button,
                              "steps": args.steps, "hold_ms": args.hold_ms,
                              **vnc_pointer(docker, args.version, events)}))
        else:
            live = live_uuid(docker, args.version)
            if args.guest_uuid and str(uuid.UUID(args.guest_uuid)) != live:
                raise VmError("--guest-uuid differs from the live QEMU UUID")
            name = args.guest_name or machine_identity(root, args.version)["host"]
            destination = stage_validation(root, args.version, live, name, args.guest_python, args.ole_source,
                                           args.fixture_ref)
            print(f"Staged guest-only validation fixture: {destination}")
    except (OSError, ValueError, VmError, subprocess.SubprocessError) as exc:
        parser.exit(1, f"ERROR: {exc}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
