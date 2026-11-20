#!/usr/bin/env python3
"""Debug event log for a Soloist Pi: one JSON line per event on stdout.

stdout goes to the systemd journal, which is volatile (RAM, see default.nix):
nothing is written to the SD card. Read it with `pi-events [minutes]`, which
merges these lines with those of audio-arbiter, shairport-sync, soloist and
bluetooth.

Sources:
  pw       volume / mute / channelVolumes / softVolumes of PipeWire audio nodes
           and of the ALSA device routes (polls `pw-dump`), node added/removed
  bluez    D-Bus property changes of BlueZ (Connected, State, Volume, Status...)
  soloist  every message of the Soloist WebSocket (truncated)

Configuration through environment variables (see eventlog.nix).
"""
import asyncio
import json
import os
import subprocess
import sys
from datetime import datetime

WS_URL = os.environ.get("SOLOIST_WS", "ws://127.0.0.1:8765")
PW_INTERVAL = float(os.environ.get("PW_INTERVAL", "1"))
MAX_LEN = 300

# Props of a PipeWire node or device route worth following.
KEYS = ("volume", "mute", "channelVolumes", "softVolumes", "softMute", "monitorVolumes")


def emit(src, type_, **details):
    line = {"ts": datetime.now().astimezone().isoformat(timespec="milliseconds"), "src": src, "type": type_}
    line.update(details)
    print(json.dumps(line, ensure_ascii=False, default=str), flush=True)


def rnd(v):
    if isinstance(v, float):
        return round(v, 4)
    if isinstance(v, list):
        return [rnd(x) for x in v]
    return v


def pick(props):
    return {k: rnd(props[k]) for k in KEYS if k in props}


def snapshot(dump):
    """pw-dump output (list of objects) -> {key: {"name", "kind", "state"}}."""
    snap = {}
    for o in dump:
        info = o.get("info") or {}
        props = info.get("props") or {}
        params = info.get("params") or {}
        t = o.get("type", "")
        if t.endswith("Interface:Node"):
            cls = props.get("media.class", "")
            if "Audio" not in cls:
                continue
            name = props.get("node.name") or props.get("node.nick") or str(o.get("id"))
            app = props.get("application.name") or props.get("media.name")
            st = {"node.state": info.get("state")}
            plist = params.get("Props") or []
            if plist and isinstance(plist[0], dict):
                st.update(pick(plist[0]))
            snap[f"node:{o['id']}"] = {
                "name": name, "kind": "node", "class": cls, "app": app, "state": st}
        elif t.endswith("Interface:Device"):
            dname = props.get("device.name") or str(o.get("id"))
            for r in params.get("Route") or []:
                if not isinstance(r, dict) or r.get("direction") not in (None, "Output"):
                    continue
                st = pick(r.get("props") or {})
                if st:
                    rn = r.get("name", r.get("index", "?"))
                    snap[f"route:{o['id']}:{rn}"] = {
                        "name": f"{dname}/{rn}", "kind": "route", "state": st}
    return snap


def diff(old, new):
    """Two snapshots -> list of (type, details) events."""
    ev = []
    for k, n in new.items():
        o = old.get(k)
        if o is None:
            d = {"what": n["kind"], "id": k, "name": n["name"], "values": n["state"]}
            for extra in ("class", "app"):
                if n.get(extra):
                    d[extra] = n[extra]
            ev.append(("added", d))
            continue
        ch = {a: [o["state"].get(a), b] for a, b in n["state"].items() if o["state"].get(a) != b}
        for a in o["state"]:
            if a not in n["state"]:
                ch[a] = [o["state"][a], None]
        if ch:
            ev.append(("change", {"what": n["kind"], "id": k, "name": n["name"], "changes": ch}))
    for k, o in old.items():
        if k not in new:
            ev.append(("removed", {"what": o["kind"], "id": k, "name": o["name"]}))
    return ev


async def pw_task():
    env = dict(os.environ, PIPEWIRE_RUNTIME_DIR="/run/pipewire")
    prev = None
    err_logged = False
    while True:
        try:
            p = await asyncio.create_subprocess_exec(
                "pw-dump", env=env, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
            out, err = await asyncio.wait_for(p.communicate(), 10)
            if p.returncode != 0:
                raise RuntimeError(err.decode(errors="replace").strip()[:200] or f"exit {p.returncode}")
            cur = snapshot(json.loads(out))
            if prev is None:
                prev = {}  # first run: every node shows as "added" with its values
            for t, d in diff(prev, cur):
                emit("pw", t, **d)
            prev = cur
            err_logged = False
        except Exception as e:
            if not err_logged:
                emit("pw", "error", error=str(e))
                err_logged = True
        await asyncio.sleep(PW_INTERVAL)


def plain(v):
    """dbus-next Variant (or nested) -> JSON-friendly value."""
    if hasattr(v, "value") and hasattr(v, "signature"):
        return plain(v.value)
    if isinstance(v, dict):
        return {str(k): plain(x) for k, x in v.items()}
    if isinstance(v, (list, tuple)):
        return [plain(x) for x in v]
    return v


async def bluez_task():
    from dbus_next import BusType, Message, MessageType
    from dbus_next.aio import MessageBus
    while True:
        try:
            bus = await MessageBus(bus_type=BusType.SYSTEM).connect()

            def handler(msg):
                if msg.message_type != MessageType.SIGNAL or not (msg.path or "").startswith("/org/bluez"):
                    return
                try:
                    if msg.member == "PropertiesChanged" and msg.interface == "org.freedesktop.DBus.Properties":
                        iface, changed, invalid = msg.body
                        emit("bluez", "properties", path=msg.path, interface=iface,
                             changed=plain(changed), invalidated=list(invalid))
                    elif msg.member in ("InterfacesAdded", "InterfacesRemoved"):
                        emit("bluez", msg.member, path=str(msg.body[0]), detail=plain(msg.body[1]))
                except Exception as e:
                    emit("bluez", "error", error=f"handler: {e}")

            bus.add_message_handler(handler)
            for rule in (
                "type='signal',sender='org.bluez',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged'",
                "type='signal',sender='org.bluez',interface='org.freedesktop.DBus.ObjectManager'",
            ):
                await bus.call(Message(destination="org.freedesktop.DBus", path="/org/freedesktop/DBus",
                                       interface="org.freedesktop.DBus", member="AddMatch",
                                       signature="s", body=[rule]))
            # Current state, once.
            intro = await bus.introspect("org.bluez", "/")
            mgr = bus.get_proxy_object("org.bluez", "/", intro).get_interface("org.freedesktop.DBus.ObjectManager")
            for path, ifaces in (await mgr.call_get_managed_objects()).items():
                for iface in ("org.bluez.Device1", "org.bluez.MediaTransport1", "org.bluez.MediaPlayer1"):
                    if iface in ifaces:
                        emit("bluez", "initial", path=path, interface=iface, props=plain(ifaces[iface]))
            await bus.wait_for_disconnect()
        except Exception as e:
            emit("bluez", "error", error=str(e))
        await asyncio.sleep(5)


async def soloist_task():
    import websockets
    while True:
        try:
            async with websockets.connect(WS_URL) as ws:
                emit("soloist", "connected", url=WS_URL)
                async for raw in ws:
                    if isinstance(raw, bytes):
                        raw = raw.decode(errors="replace")
                    emit("soloist", "message", msg=raw[:MAX_LEN] + ("..." if len(raw) > MAX_LEN else ""))
        except Exception as e:
            emit("soloist", "disconnected", error=str(e))
        await asyncio.sleep(3)


async def main():
    emit("eventlog", "start")
    await asyncio.gather(pw_task(), bluez_task(), soloist_task())


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
