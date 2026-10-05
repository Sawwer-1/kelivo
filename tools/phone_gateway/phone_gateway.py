#!/usr/bin/env python3
"""Kelivo phone gateway - drives an Android phone over adb as MCP tools.

Zero phone-package changes: everything rides on adb (USB or TCP). The MCP
server speaks stdio, so Kelivo spawns it directly with:

    command: python  args: ["<path to this file>"]

stdout is reserved for the MCP protocol; all diagnostics go to stderr.

Dangerous tools (phone_shell, phone_install, phone_uninstall, phone_text,
phone_tap, phone_swipe) should be put behind Kelivo's per-tool approval in
the MCP settings - the gateway never enforces its own policy.
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile
from typing import Optional

from mcp.server.fastmcp import FastMCP

mcp = FastMCP(
    "phone-gateway",
    instructions=(
        "Control a connected Android phone over adb: UI automation, shell, "
        "apps, SMS/call-log reads, battery and device info. Prefer "
        "phone_list_devices first; pass the serial when several devices are "
        "attached."
    ),
)

# --------------------------------------------------------------------------
# adb plumbing


def _adb_path() -> str:
    candidates = [
        os.environ.get("ADB_PATH", "").strip(),
        shutil.which("adb"),
        r"D:\dev\platform-tools\adb.exe",
        os.path.join(
            os.environ.get("LOCALAPPDATA", ""), "Android", "Sdk",
            "platform-tools", "adb.exe",
        ),
    ]
    for cand in candidates:
        if cand and os.path.isfile(cand):
            return cand
    return "adb"  # last resort; subprocess will surface the error


def _run(args, device: str = "", timeout: int = 20) -> tuple[int, str]:
    cmd = [_adb_path()]
    if device:
        cmd += ["-s", device]
    cmd += args
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
        )
        out = proc.stdout or ""
        if proc.returncode != 0:
            err = (proc.stderr or "").strip()
            out = f"{out}\n[adb exit {proc.returncode}] {err}".strip()
        return proc.returncode, out.strip()
    except subprocess.TimeoutExpired:
        return 1, "ERROR: adb timed out"
    except FileNotFoundError:
        return 1, "ERROR: adb not found; set ADB_PATH or install platform-tools"


def _device_or_fail(device: str) -> Optional[str]:
    rc, out = _run(["devices"])
    if rc != 0:
        return None
    serials = [
        line.split("\t")[0]
        for line in out.splitlines()[1:]
        if "\tdevice" in line
    ]
    if device:
        return device if device in serials else None
    if len(serials) == 1:
        return serials[0]
    return None  # zero devices, or ambiguity the caller must report


def _pick(device: str = "") -> str:
    serial = _device_or_fail(device)
    if serial:
        return serial
    rc, out = _run(["devices"])
    lines = [ln for ln in out.splitlines()[1:] if ln.strip()]
    if not lines:
        raise ValueError(
            "ERROR: no adb device attached. Connect the phone (USB debugging "
            "on) or use phone_connect for wireless adb."
        )
    if any("unauthorized" in ln for ln in lines):
        raise ValueError(
            "ERROR: device unauthorized - accept the debugging prompt on the "
            "phone."
        )
    raise ValueError(
        "ERROR: multiple devices online, pass an explicit serial. "
        "Online: " + ", ".join(lines)
    )


def _shell(shell_cmd: str, device: str = "", timeout: int = 20) -> str:
    serial = _pick(device)
    rc, out = _run(["shell", shell_cmd], device=serial, timeout=timeout)
    return out


def _content_query(uri: str, projection: str, limit: int, selection: str = "") -> str:
    cmd = f"content query --uri {uri} --projection {projection}"
    if selection:
        cmd += f" --where '{selection}'"
    out = _shell(cmd, timeout=30)
    if out.startswith("ERROR") or "No result found" in out:
        return "No rows." if "No result" in out else out
    rows: list[dict[str, str]] = []
    for line in out.splitlines():
        if not line.startswith("Row:"):
            continue
        row: dict[str, str] = {}
        for pair in re.findall(r"(\w+)=((?:[^=]|=(?!\S))*?)(?:, |\s*$)", line):
            row[pair[0]] = pair[1]
        rows.append(row)
    return json_pretty(rows[:limit])


def json_pretty(obj) -> str:
    import json

    return json.dumps(obj, ensure_ascii=False, indent=2)


# --------------------------------------------------------------------------
# tools


@mcp.tool()
def phone_list_devices() -> str:
    """List adb devices with model, Android version and connection state."""
    rc, out = _run(["devices", "-l"])
    return out if out.strip() else "No devices attached."


@mcp.tool()
def phone_connect(host_port: str) -> str:
    """Connect to a phone over TCP (wireless adb), e.g. 192.168.0.10:5555."""
    rc, out = _run(["connect", host_port], timeout=15)
    return out


@mcp.tool()
def phone_shell(command: str, device: str = "", timeout: int = 30) -> str:
    """Run a raw shell command on the phone. Approval recommended."""
    return _shell(command, device=device, timeout=timeout)


@mcp.tool()
def phone_tap(x: int, y: int, device: str = "") -> str:
    """Tap the screen at pixel coordinates (from phone_dump_ui bounds)."""
    return _shell(f"input tap {int(x)} {int(y)}", device=device)


@mcp.tool()
def phone_swipe(
    x1: int, y1: int, x2: int, y2: int, duration_ms: int = 300, device: str = ""
) -> str:
    """Swipe between two points over duration_ms milliseconds."""
    return _shell(
        f"input swipe {int(x1)} {int(y1)} {int(x2)} {int(y2)} {int(duration_ms)}",
        device=device,
    )


@mcp.tool()
def phone_key_event(key: str, device: str = "") -> str:
    """Press a key by name (BACK, HOME, ENTER, POWER, WAKEUP, VOLUME_UP,
    VOLUME_DOWN, RECENT, DELETE) or raw keyevent number."""
    names = {
        "BACK": 4, "HOME": 3, "ENTER": 66, "DEL": 67, "DELETE": 67,
        "POWER": 26, "WAKEUP": 224, "SLEEP": 223, "VOLUME_UP": 24,
        "VOLUME_DOWN": 25, "RECENT": 187, "TAB": 61, "ESC": 111,
    }
    value = names.get(key.strip().upper(), key.strip())
    return _shell(f"input keyevent {value}", device=device)


@mcp.tool()
def phone_input_text(text: str, device: str = "") -> str:
    """Type ASCII text into the focused field. Spaces become %s; CJK needs
    an IME-based approach (unsupported in this version)."""
    safe = text.replace(" ", "%s")
    safe = re.sub(r'[<>&|;"\'`$*\\(){}[\]!#~^]', "", safe)
    if safe != text.replace(" ", "%s"):
        removed = set(text) - set(safe.replace("%s", " "))
        return (
            f"ERROR: characters {removed!r} are unsafe for `input text`; "
            "edit the text or use an IME."
        )
    return _shell(f"input text '{safe}'", device=device)


@mcp.tool()
def phone_screenshot(device: str = "") -> str:
    """Capture a PNG to a host temp file and return its path. Read the file
    or attach it to the chat to view the screen."""
    serial = _pick(device)
    remote = "/sdcard/kelivo_gateway_screen.png"
    rc, out = _run(["shell", f"screencap -p {remote}"], device=serial)
    if rc != 0:
        return out
    host_dir = os.path.join(tempfile.gettempdir(), "kelivo_phone_gateway")
    os.makedirs(host_dir, exist_ok=True)
    host = os.path.join(host_dir, f"screen_{serial.replace(':', '_')}.png")
    rc, out = _run(["pull", remote, host], device=serial, timeout=60)
    if rc != 0:
        return out
    _run(["shell", f"rm -f {remote}"], device=serial)
    size = os.path.getsize(host)
    return f"Screenshot saved: {host} ({size} bytes)"


@mcp.tool()
def phone_dump_ui(device: str = "") -> str:
    """Dump the window hierarchy XML (uiautomator). Returns the file path and
    the inline XML (truncated); use bounds of nodes as tap/swipe coordinates."""
    serial = _pick(device)
    remote = "/sdcard/kelivo_gateway_window.xml"
    out = _shell(f"uiautomator dump {remote}", device=serial, timeout=30)
    if "dumped" not in out.lower():
        return out
    host_dir = os.path.join(tempfile.gettempdir(), "kelivo_phone_gateway")
    os.makedirs(host_dir, exist_ok=True)
    host = os.path.join(host_dir, f"window_{serial.replace(':', '_')}.xml")
    rc, out = _run(["pull", remote, host], device=serial, timeout=30)
    if rc != 0:
        return out
    _run(["shell", f"rm -f {remote}"], device=serial)
    with open(host, encoding="utf-8", errors="replace") as fh:
        xml = fh.read()
    head = xml if len(xml) <= 20000 else xml[:20000] + "\n<!-- truncated -->"
    return f"UI dump: {host}\n\n{head}"


@mcp.tool()
def phone_read_sms(limit: int = 20, device: str = "") -> str:
    """Read the latest SMS messages (address, date, body)."""
    return _content_query(
        "content://sms",
        "_id,address,date,body",
        max(1, min(int(limit), 100)),
        device=device,
    )


@mcp.tool()
def phone_read_call_log(limit: int = 20, device: str = "") -> str:
    """Read the latest call-log entries (number, type, date, duration)."""
    return _content_query(
        "content://call_log/calls",
        "_id,number,date,duration,type",
        max(1, min(int(limit), 100)),
        device=device,
    )


@mcp.tool()
def phone_list_packages(name_filter: str = "", device: str = "") -> str:
    """List installed packages, optionally filtered by a name substring."""
    out = _shell("pm list packages", device=device, timeout=30)
    if name_filter:
        lines = [
            ln for ln in out.splitlines()
            if name_filter.lower() in ln.lower()
        ]
        return "\n".join(lines) if lines else "No matching packages."
    return out


@mcp.tool()
def phone_install(apk_path: str, device: str = "") -> str:
    """Install an APK that already exists on this computer. Approval strongly
    recommended."""
    serial = _pick(device)
    if not os.path.isfile(apk_path):
        return f"ERROR: APK not found: {apk_path}"
    rc, out = _run(["install", "-r", apk_path], device=serial, timeout=300)
    return out


@mcp.tool()
def phone_uninstall(package: str, device: str = "") -> str:
    """Uninstall an app by package name. Approval strongly recommended."""
    return _shell(f"pm uninstall {package}", device=device, timeout=60)


@mcp.tool()
def phone_battery(device: str = "") -> str:
    """Battery level, state, health and temperature."""
    out = _shell("dumpsys battery", device=device)
    keep = (
        "level", "status", "health", "present", "powered", "temperature",
        "technology", "voltage", "current",
    )
    lines = [
        ln for ln in out.splitlines()
        if any(k in ln.lower() for k in keep)
    ]
    return "\n".join(lines) if lines else out


@mcp.tool()
def phone_device_info(device: str = "") -> str:
    """Model, brand, Android release, SDK and screen resolution."""
    props = {
        "brand": "ro.product.brand",
        "model": "ro.product.model",
        "device": "ro.product.device",
        "release": "ro.build.version.release",
        "sdk": "ro.build.version.sdk",
        "abi": "ro.product.cpu.abi",
    }
    serial = _pick(device)
    lines = [
        f"{name}: {_shell(f'getprop {prop}', device=serial)}"
        for name, prop in props.items()
    ]
    size = _shell("wm size", device=serial)
    density = _shell("wm density", device=serial)
    return "\n".join(lines + [size, density])


def main() -> None:
    # stdin/stdout must stay pristine for the MCP protocol.
    sys.stderr.write("[phone-gateway] starting on stdio; diagnostics here\n")
    mcp.run()


if __name__ == "__main__":
    main()
