#!/usr/bin/env python3
"""Audio source arbiter for a Soloist Pi.

Sources: Spotify (Soloist), AirPlay (shairport-sync) and every connected
Bluetooth device (BlueZ A2DP; each device is its own source, "bt:<path>").
Only one may play at a time: the last one to start wins, the others are
disconnected (not paused), so the user sees it:
  - Spotify:   restart soloist.service
  - AirPlay:   restart shairport-sync.service
  - Bluetooth: every connected device other than the winner is disconnected,
    playing or not (AVRCP Pause, short wait, then BlueZ Device1.Disconnect)
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
LOCKOUT = float(os.environ.get("LOCKOUT", "15"))
# A source must keep playing this long before it disconnects the others: short
# "playing" blips (track change, a phone that just connected) do not count.
MIN_PLAY = float(os.environ.get("MIN_PLAY", "4"))

# Wait after the AVRCP Pause before disconnecting a Bluetooth device.
BT_PAUSE_WAIT = 0.3

SOURCES = ("spotify", "airplay")
BT_PREFIX = "bt:"
# Bluetooth devices are added as "bt:<object path>" while they are connected.
playing = {s: False for s in SOURCES}
started_at = {s: 0.0 for s in SOURCES}
lockout_until = {}  # kept after a device disconnects: it may reconnect soon
bt_names = {}  # object path -> alias, for the logs
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


def write_busy_state():
    busy = any(playing.values())
    try:
        tmp = os.path.join(STATE_DIR, "busy.tmp")
        target = os.path.join(STATE_DIR, "busy")
        with open(tmp, "w") as f:
            f.write("1\n" if busy else "0\n")
        os.replace(tmp, target)
    except OSError:
        pass


def set_playing(src, value):
    if playing.get(src, False) == value:
        return
    playing[src] = value
    write_busy_state()
    log(f"{src}: {'playing' if value else 'stopped'}")
    if value:
        started_at[src] = time.monotonic()
        if time.monotonic() >= lockout_until.get(src, 0.0):
            asyncio.get_event_loop().create_task(confirm_then_kick(src, started_at[src]))


async def confirm_then_kick(src, t0):
    await asyncio.sleep(MIN_PLAY)
    # Still the same, uninterrupted playback after MIN_PLAY seconds?
    if playing.get(src, False) and started_at.get(src) == t0:
        await kick_others(src)
    else:
        log(f"{src}: playing for less than {MIN_PLAY:g} s, ignored")


def devices_to_disconnect(winner, connected_devices):
    """Bluetooth devices to disconnect when `winner` (a source key) wins.

    Every connected device except the winner, whether it plays or not.
    """
    return [d for d in connected_devices if BT_PREFIX + d != winner]


async def kick_others(winner):
    for other in SOURCES:
        if other == winner or not playing.get(other, False):
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
        except Exception as e:  # never let one failure stop the arbiter
            log(f"disconnect {other} failed: {e}")
    try:
        objs = await bluez_objects()
        victims = devices_to_disconnect(winner, connected_devices(objs))
    except Exception as e:
        log(f"BlueZ: cannot list devices to disconnect: {e}")
        return
    for dev in victims:
        key = BT_PREFIX + dev
        lockout_until[key] = time.monotonic() + LOCKOUT
        playing[key] = False
    await asyncio.gather(*(bt_disconnect(dev, objs) for dev in victims))


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


def connected_devices(objs):
    """Object paths of the connected BlueZ devices (Device1.Connected)."""
    devs = []
    for path, ifaces in objs.items():
        d = ifaces.get("org.bluez.Device1")
        if d and d.get("Connected") and d["Connected"].value:
            devs.append(path)
            alias = d.get("Alias")
            bt_names[path] = alias.value if alias else path
    return devs


async def bt_call(path, iface, method):
    intro = await bus.introspect("org.bluez", path)
    i = bus.get_proxy_object("org.bluez", path, intro).get_interface(iface)
    await asyncio.wait_for(getattr(i, "call_" + method)(), timeout=5)


async def bt_disconnect(dev, objs):
    """Pause the device's AVRCP player if any, wait a bit, then disconnect it."""
    name = bt_names.get(dev, dev)
    players = [
        p for p, ifaces in objs.items()
        if "org.bluez.MediaPlayer1" in ifaces and p.startswith(dev + "/")
    ]
    paused = False
    for p in players:
        try:
            await bt_call(p, "org.bluez.MediaPlayer1", "pause")
            paused = True
        except Exception:
            pass  # not every player supports Pause: ignore
    if paused:
        await asyncio.sleep(BT_PAUSE_WAIT)
    try:
        await bt_call(dev, "org.bluez.Device1", "disconnect")
        log(f"disconnected {name} ({'pause sent' if paused else 'no player'})")
    except Exception as e:  # one device failing must not stop the others
        log(f"disconnect {name} failed: {e}")


async def bluetooth_task():
    while True:
        try:
            objs = await bluez_objects()
            active = set()
            for path, ifaces in objs.items():
                t = ifaces.get("org.bluez.MediaTransport1")
                if t and t.get("State") and t["State"].value == "active":
                    active.add(t["Device"].value)
            connected = connected_devices(objs)
            for dev in connected:
                set_playing(BT_PREFIX + dev, dev in active)
            # Forget the devices that are gone (their lockout is kept).
            for key in [k for k in playing if k.startswith(BT_PREFIX)]:
                if key[len(BT_PREFIX):] not in connected:
                    set_playing(key, False)
                    playing.pop(key, None)
                    started_at.pop(key, None)
        except Exception as e:
            log(f"BlueZ: {e}")
            for key in [k for k in playing if k.startswith(BT_PREFIX)]:
                set_playing(key, False)
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
    write_busy_state()
    await asyncio.gather(spotify_task(), airplay_task(), bluetooth_task(), power_task())


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
