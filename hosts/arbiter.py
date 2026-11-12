#!/usr/bin/env python3
"""Audio source arbiter for a Soloist Pi.

Three sources can play: Spotify (Soloist), AirPlay (shairport-sync) and
Bluetooth (BlueZ A2DP). Only one may play at a time: the last one to start
wins, the others are disconnected (not paused), so the user sees it:
  - Spotify:   restart soloist.service
  - AirPlay:   restart shairport-sync.service
  - Bluetooth: disconnect the device (BlueZ Device1.Disconnect)
Optionally a Shelly plug (speakers power) is switched on when anything plays
and off after OFF_DELAY seconds of silence (direct Shelly Gen2+ HTTP RPC).

Configuration through environment variables (see arbiter.nix).
"""
import asyncio
import json
import os
import subprocess
import sys
import time
import urllib.request

from dbus_next.aio import MessageBus
from dbus_next import BusType
import websockets

WS_URL = os.environ.get("SOLOIST_WS", "ws://127.0.0.1:8765")
STATE_DIR = os.environ.get("STATE_DIR", "/run/audio-arbiter")
SHELLY_HOST_FILE = os.environ.get("SHELLY_HOST_FILE", "")
OFF_DELAY = float(os.environ.get("OFF_DELAY", "20"))
LOCKOUT = float(os.environ.get("LOCKOUT", "8"))

SOURCES = ("spotify", "airplay", "bluetooth")
playing = {s: False for s in SOURCES}
bt_device = None  # object path of the Bluetooth device that is streaming
started_at = {s: 0.0 for s in SOURCES}
lockout_until = {s: 0.0 for s in SOURCES}
last_busy = -1e9  # never busy yet: do not switch the plug at boot
plug_on = None


def log(msg):
    print(msg, flush=True)


def find_status(obj):
    """Find a playback status string in a Soloist event, whatever the nesting."""
    if isinstance(obj, dict):
        v = obj.get("status")
        if isinstance(v, str) and v in ("idle", "playing", "paused", "buffering"):
            return v
        for x in obj.values():
            r = find_status(x)
            if r:
                return r
    elif isinstance(obj, list):
        for x in obj:
            r = find_status(x)
            if r:
                return r
    return None


def set_playing(src, value):
    if playing[src] == value:
        return
    playing[src] = value
    log(f"{src}: {'playing' if value else 'stopped'}")
    if value:
        started_at[src] = time.monotonic()
        if time.monotonic() >= lockout_until[src]:
            asyncio.get_event_loop().create_task(kick_others(src))


async def kick_others(winner):
    for other in SOURCES:
        if other == winner or not playing[other]:
            continue
        log(f"{winner} started: disconnecting {other}")
        lockout_until[other] = time.monotonic() + LOCKOUT
        playing[other] = False
        try:
            if other == "spotify":
                subprocess.run(["systemctl", "restart", "soloist.service"], check=False, timeout=30)
            elif other == "airplay":
                try:
                    os.remove(os.path.join(STATE_DIR, "airplay"))
                except FileNotFoundError:
                    pass
                subprocess.run(["systemctl", "restart", "shairport-sync.service"], check=False, timeout=30)
            elif other == "bluetooth":
                await bt_disconnect()
        except Exception as e:  # never let one failure stop the arbiter
            log(f"disconnect {other} failed: {e}")


async def spotify_task():
    while True:
        try:
            async with websockets.connect(WS_URL) as ws:
                log("connected to the Soloist WebSocket")
                async for raw in ws:
                    try:
                        ev = json.loads(raw)
                    except ValueError:
                        continue
                    if ev.get("type") == "playback_changed":
                        status = find_status(ev)
                        if status:
                            set_playing("spotify", status in ("playing", "buffering"))
        except Exception as e:
            log(f"Soloist WebSocket: {e}")
        set_playing("spotify", False)
        await asyncio.sleep(3)


async def airplay_task():
    path = os.path.join(STATE_DIR, "airplay")
    while True:
        set_playing("airplay", os.path.exists(path))
        await asyncio.sleep(0.5)


bus = None


async def bluez_objects():
    global bus
    if bus is None:
        bus = await MessageBus(bus_type=BusType.SYSTEM).connect()
    intro = await bus.introspect("org.bluez", "/")
    obj = bus.get_proxy_object("org.bluez", "/", intro)
    mgr = obj.get_interface("org.freedesktop.DBus.ObjectManager")
    return await mgr.call_get_managed_objects()


async def bt_disconnect():
    if not bt_device:
        return
    intro = await bus.introspect("org.bluez", bt_device)
    dev = bus.get_proxy_object("org.bluez", bt_device, intro).get_interface("org.bluez.Device1")
    await dev.call_disconnect()


async def bluetooth_task():
    global bt_device
    while True:
        try:
            objs = await bluez_objects()
            active = None
            for path, ifaces in objs.items():
                t = ifaces.get("org.bluez.MediaTransport1")
                if t and t.get("State") and t["State"].value == "active":
                    active = t["Device"].value
            bt_device = active or bt_device
            set_playing("bluetooth", active is not None)
        except Exception as e:
            log(f"BlueZ: {e}")
            set_playing("bluetooth", False)
            await asyncio.sleep(5)
        await asyncio.sleep(1)


def shelly_host():
    try:
        with open(SHELLY_HOST_FILE) as f:
            return f.read().strip()
    except OSError:
        return ""


def shelly(on):
    host = shelly_host()
    url = f"http://{host}/rpc/Switch.Set?id=0&on={'true' if on else 'false'}"
    with urllib.request.urlopen(url, timeout=5) as r:
        r.read()


async def power_task():
    global last_busy, plug_on
    while True:
        if not shelly_host():
            await asyncio.sleep(10)  # no plug configured (SHELLY_HOST in soloist.env)
            continue
        busy = any(playing.values())
        now = time.monotonic()
        if busy:
            last_busy = now
        want = busy or (now - last_busy < OFF_DELAY)
        if plug_on is not want and (want or plug_on is not None):
            try:
                await asyncio.get_event_loop().run_in_executor(None, shelly, want)
                log(f"Shelly plug {'on' if want else 'off'}")
                plug_on = want
            except Exception as e:
                log(f"Shelly plug unreachable ({e}), retrying")
        elif plug_on is None and not want:
            plug_on = False  # first run: do not touch the plug at boot while idle
        await asyncio.sleep(1)


async def main():
    os.makedirs(STATE_DIR, exist_ok=True)
    await asyncio.gather(spotify_task(), airplay_task(), bluetooth_task(), power_task())


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
