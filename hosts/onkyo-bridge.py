#!/usr/bin/env python3
"""onkyo-bridge: use an Onkyo AV receiver as the output of a Soloist audio player.

Controls the receiver over eISCP (TCP port 60128, with UDP port 60128 auto-discovery):
- When audio plays (Spotify, AirPlay, Bluetooth), the receiver is turned on,
  switched to the Pi's input (ONKYO_INPUT, default 03 = AUX) and set to MANAGED_VOLUME (default 60).
  Subwoofers take ~2.5s to start: volume is held at 0, then ramped from RAMP_FROM (25)
  to MANAGED_VOLUME (60) over RAMP_TIME (3s), starting RAMP_DELAY (3s) after power-on.
- While on that input, the bridge owns receiver volume (putting remote/knob drifts back).
- Switching the receiver to another input ends the Pi audio session (disconnects clients)
  and restores the previous volume (capped at RESTORE_MAX, default 40).
- After SILENCE_DELAY (default 20s) of silence, the Pi audio session ends,
  volume is restored and confirmed, then the receiver goes to standby.
- If the receiver is turned off during a session at high volume, it turns it back on,
  lowers the volume to safe levels, confirms, and puts it back to standby.
- Auto-discovery: If ONKYO_HOST is empty or unset, broadcasts UDP discovery packet
  !xECNQSTN to automatically find the receiver IP on the local network.
- Disabled: If ONKYO_HOST is "false" (or "disabled", "off"), exits cleanly.

Zero dependencies outside Python 3 standard library.
"""

import glob
import json
import logging
import os
import select
import socket
import struct
import subprocess
import sys
import time

log = logging.getLogger("onkyo-bridge")


def get_conf(name, default):
    return os.environ.get(name, default)


def read_file_strip(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return ""


# Configuration: environment variable has priority, then secrets file, then default.
ONKYO_HOST = get_conf("ONKYO_HOST", read_file_strip("/run/soloist-secrets/onkyo-host"))
ONKYO_PORT = int(get_conf("ONKYO_PORT", "60128"))
ONKYO_INPUT = get_conf("ONKYO_INPUT", "03").upper()
MANAGED_VOLUME = int(get_conf("MANAGED_VOLUME", "60"))
RESTORE_MAX = int(get_conf("RESTORE_MAX", "40"))
SILENCE_DELAY = float(get_conf("SILENCE_DELAY", "20"))
RAMP_DELAY = float(get_conf("RAMP_DELAY", "3"))
RAMP_FROM = int(get_conf("RAMP_FROM", "25"))
RAMP_TIME = float(get_conf("RAMP_TIME", "3"))
RAMP_INTERVAL = 0.2

STATE_DIR = get_conf("STATE_DIRECTORY", "/var/lib/onkyo-bridge")
STATE_FILE = os.path.join(STATE_DIR, "state.json")

# Delays (seconds)
REPOWER_DELAY = 1.2    # after an unexpected standby, before turning back on
FIX_RETRY = 30         # retry if receiver doesn't turn on
CONFIRM_TIMEOUT = 2    # wait for receiver to confirm command
CONFIRM_TRIES = 3
DRIFT_SETTLE = 0.3     # let remote presses settle
SETTLE_GUARD = 2       # ignore stale volume reports
NO_TAKEOVER = 10       # after manual input change


# --------------------------------------------------------------------------
# Auto-discovery & eISCP Client
# --------------------------------------------------------------------------

def discover_onkyo(timeout=2.5):
    """Broadcast eISCP UDP query !xECNQSTN on port 60128 to find receiver IP."""
    payload = b"!xECNQSTN\r"
    header = b"ISCP" + struct.pack(">IIB3x", 16, len(payload), 1)
    packet = header + payload

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    sock.settimeout(timeout)

    discovered_ip = None
    targets = ["<broadcast>", "255.255.255.255"]
    for target in targets:
        try:
            sock.sendto(packet, (target, 60128))
        except OSError:
            pass

    t_end = time.monotonic() + timeout
    while time.monotonic() < t_end:
        try:
            data, (ip, port) = sock.recvfrom(1024)
            if b"ECN" in data:
                log.info("Discovered Onkyo receiver at %s (%s)", ip, data.rstrip().decode("ascii", "replace"))
                discovered_ip = ip
                break
        except (socket.timeout, BlockingIOError):
            break
        except OSError as e:
            log.debug("UDP discovery recv error: %s", e)
            break

    sock.close()
    return discovered_ip


class Onkyo:
    def __init__(self, host, port):
        self.configured_host = host.strip() if host else ""
        self.host = None
        if self.configured_host and self.configured_host.lower() not in ("auto", ""):
            self.host = self.configured_host
        self.port = port
        self.sock = None
        self.buf = b""
        self.next_attempt = 0.0
        self.backoff = 1.0
        self.down_logged = False

    def connected(self):
        return self.sock is not None

    def connect(self):
        if self.sock or time.monotonic() < self.next_attempt:
            return False

        # If host not fixed, discover it via UDP broadcast
        if not self.host:
            log.debug("Auto-discovering Onkyo receiver...")
            found = discover_onkyo(timeout=2.0)
            if found:
                self.host = found
                self.backoff = 1.0
                self.down_logged = False
            else:
                if not self.down_logged:
                    log.warning("No Onkyo receiver discovered on the network (will retry)")
                    self.down_logged = True
                self.next_attempt = time.monotonic() + self.backoff
                self.backoff = min(self.backoff * 2, 30)
                return False

        try:
            s = socket.create_connection((self.host, self.port), timeout=3)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
            s.setblocking(False)
        except OSError as e:
            if not self.down_logged:
                log.warning("Receiver unreachable at %s:%d (%s)", self.host, self.port, e)
                self.down_logged = True
            # If auto-discovered host is down for too long, reset host to re-discover
            if not self.configured_host and self.backoff >= 16.0:
                log.info("Receiver unreachable at %s, will retry discovery", self.host)
                self.host = None
            self.next_attempt = time.monotonic() + self.backoff
            self.backoff = min(self.backoff * 2, 30)
            return False

        self.sock, self.buf, self.backoff, self.down_logged = s, b"", 1.0, False
        log.info("Connected to Onkyo receiver at %s:%d", self.host, self.port)
        return True

    def close(self):
        if self.sock:
            self.sock.close()
        self.sock = None
        self.next_attempt = time.monotonic() + self.backoff

    def send(self, cmd):
        if not self.sock:
            log.warning("Receiver not connected, command not sent: %s", cmd)
            return False
        data = b"!1" + cmd.encode("ascii") + b"\r"
        pkt = b"ISCP" + struct.pack(">IIB3x", 16, len(data), 1) + data
        try:
            self.sock.sendall(pkt)
            log.debug("-> %s", cmd)
            return True
        except OSError as e:
            log.warning("Send failed (%s)", e)
            self.close()
            return False

    def read(self):
        try:
            chunk = self.sock.recv(4096)
        except BlockingIOError:
            return []
        except OSError as e:
            log.warning("Connection lost (%s)", e)
            self.close()
            return []
        if not chunk:
            log.warning("Connection closed by receiver")
            self.close()
            return []
        self.buf += chunk
        out = []
        while len(self.buf) >= 16:
            if self.buf[:4] != b"ISCP":
                i = self.buf.find(b"ISCP", 1)
                self.buf = self.buf[i:] if i > 0 else b""
                continue
            hsize, dsize = struct.unpack(">II", self.buf[4:12])
            if len(self.buf) < hsize + dsize:
                break
            data = self.buf[hsize:hsize + dsize]
            self.buf = self.buf[hsize + dsize:]
            msg = data.rstrip(b"\x1a\r\n").decode("ascii", "replace")
            if msg.startswith("!1"):
                out.append(msg[2:])
        return out


# --------------------------------------------------------------------------
# Playback detection & session management
# --------------------------------------------------------------------------

def is_audio_playing():
    """Detect if audio is currently playing on the system."""
    # 1. State from audio-arbiter (instant, precise)
    try:
        with open("/run/audio-arbiter/busy") as f:
            if f.read().strip() == "1":
                return True
    except OSError:
        pass

    # 2. ALSA PCM status fallback
    for status_path in glob.glob("/proc/asound/*/pcm*p/sub*/status"):
        try:
            with open(status_path) as f:
                if "RUNNING" in f.read():
                    return True
        except OSError:
            pass
    return False


def end_audio_session():
    """Disconnect active streaming clients on input change or silence timeout."""
    log.info("Ending audio session (disconnecting clients)")
    # Disconnect AirPlay
    try:
        if os.path.exists("/run/audio-arbiter/airplay"):
            os.remove("/run/audio-arbiter/airplay")
    except OSError:
        pass
    subprocess.run(
        ["systemctl", "restart", "shairport-sync.service"],
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        check=False, timeout=10
    )
    # Disconnect Spotify
    subprocess.run(
        ["systemctl", "restart", "soloist.service"],
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        check=False, timeout=10
    )
    # Disconnect Bluetooth
    subprocess.run(
        ["bluetoothctl", "disconnect"],
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        check=False, timeout=5
    )


# --------------------------------------------------------------------------
# State Machine & Bridge Logic
# --------------------------------------------------------------------------

class Bridge:
    IDLE, ENDING, FIXING = "idle", "ending", "fixing"

    def __init__(self, onkyo):
        self.onkyo = onkyo
        self.power = None
        self.input = None
        self.volume = None
        self.managed = False
        self.phase = self.IDLE
        self.step = None
        self.deadline = None
        self.tries = 0
        self.target = None
        self.we_powered = False
        self.playing = is_audio_playing()
        self.want_input = False
        self.power_cmd_at = 0.0
        self.pwr_cmd_at = 0.0
        self.power_on_at = None
        self.silence_deadline = None
        self.drift_deadline = None
        self.settle_until = None
        self.ramp_step = None
        self.ramp_next = 0.0
        self.v_before_pending = False
        self.no_takeover_until = 0.0
        self.last_query = 0.0
        state = self.load()
        self.v_before = state.get("v_before")
        self.was_managed = state.get("managed", False)

    def load(self):
        try:
            with open(STATE_FILE) as f:
                return json.load(f)
        except (OSError, ValueError):
            return {}

    def save(self):
        try:
            os.makedirs(STATE_DIR, exist_ok=True)
            tmp = STATE_FILE + ".tmp"
            with open(tmp, "w") as f:
                json.dump({"v_before": self.v_before, "managed": self.managed}, f)
            os.replace(tmp, STATE_FILE)
        except OSError as e:
            log.warning("Cannot save state: %s", e)

    def restore_volume(self):
        return RESTORE_MAX if self.v_before is None else min(self.v_before, RESTORE_MAX)

    def set_managed(self, value):
        if not value:
            self.ramp_step = None
        if self.managed != value:
            self.managed = value
            self.save()

    def send_managed_volume(self):
        self.onkyo.send("MVL%02X" % MANAGED_VOLUME)
        self.settle_until = time.monotonic() + SETTLE_GUARD

    def enter_managed(self):
        base = self.volume
        self.v_before_pending = base is None
        if base is not None and base < MANAGED_VOLUME:
            self.v_before = base
        self.managed = True
        self.was_managed = False
        self.want_input = False
        self.save()
        log.info("Receiver on input %s: volume %d (restores %d afterwards)",
                 ONKYO_INPUT, MANAGED_VOLUME, self.restore_volume())
        just_on = (self.power_on_at is not None
                   and time.monotonic() - self.power_on_at < RAMP_DELAY + 1)
        if just_on:
            self.start_ramp()
        elif self.volume != MANAGED_VOLUME:
            self.send_managed_volume()
        if not self.playing:
            self.silence_deadline = time.monotonic() + SILENCE_DELAY

    def start_ramp(self):
        """Power-on subwoofer protection: hold volume at 0, then ramp RAMP_FROM..MANAGED_VOLUME."""
        self.onkyo.send("MVL00")
        self.ramp_step = -1
        self.ramp_next = max(self.power_on_at + RAMP_DELAY, time.monotonic() + RAMP_INTERVAL)
        self.settle_until = self.drift_deadline = None

    def tick_ramp(self, now):
        if self.ramp_step is None or now < self.ramp_next:
            return
        steps = max(1, round(RAMP_TIME / RAMP_INTERVAL))
        self.ramp_step += 1
        if self.ramp_step >= steps:
            self.ramp_step = None
            self.send_managed_volume()
            return
        v = RAMP_FROM + (MANAGED_VOLUME - RAMP_FROM) * self.ramp_step / steps
        self.onkyo.send("MVL%02X" % round(v))
        self.ramp_next += RAMP_INTERVAL

    def check_managed(self):
        if (self.phase == self.IDLE and not self.managed and self.power
                and self.input == ONKYO_INPUT):
            self.enter_managed()

    def on_message(self, msg):
        code, arg = msg[:3], msg[3:]
        log.debug("<- %s", msg)
        if code == "PWR" and arg in ("00", "01"):
            self.on_power(arg == "01")
        elif code == "SLI" and arg not in ("N/A", "QSTN"):
            self.on_input(arg)
        elif code == "MVL" and arg not in ("N/A", "QSTN"):
            try:
                self.on_volume(int(arg, 16))
            except ValueError:
                pass

    def on_power(self, on):
        old, self.power = self.power, on
        if on == old:
            return
        if on:
            log.info("Receiver turned ON")
            now = time.monotonic()
            self.power_on_at = (self.pwr_cmd_at if now - self.pwr_cmd_at < 3 else now)
            self.onkyo.send("SLIQSTN")
            self.onkyo.send("MVLQSTN")
            if self.phase == self.FIXING:
                self.fix_powered_on(we_powered=self.step == "wait_on")
                return
            if self.want_input and self.input != ONKYO_INPUT:
                self.onkyo.send("SLI" + ONKYO_INPUT)
            self.check_managed()
            return
        log.info("Receiver in STANDBY")
        if self.phase == self.ENDING and self.step == "wait_standby":
            log.info("Session ended cleanly")
            self.phase, self.step, self.deadline = self.IDLE, None, None
        elif self.phase == self.FIXING and self.step == "wait_standby":
            log.info("Volume fixed, receiver back in standby")
            self.phase, self.step, self.deadline = self.IDLE, None, None
        elif self.managed or self.phase == self.ENDING:
            log.warning("Receiver turned off at volume %s during session", self.volume)
            self.set_managed(False)
            self.start_fix()

    def on_input(self, value):
        old, self.input = self.input, value
        if value == old:
            return
        log.info("Receiver input changed to %s", value)
        if value == ONKYO_INPUT:
            self.want_input = False
            self.check_managed()
        elif self.managed and self.power:
            # Manually switched to another input: restore volume and disconnect session
            log.info("Input changed manually, restoring volume to %d", self.restore_volume())
            self.set_managed(False)
            self.want_input = False
            self.silence_deadline = self.drift_deadline = self.settle_until = None
            self.onkyo.send("MVL%02X" % self.restore_volume())
            if self.playing:
                self.no_takeover_until = time.monotonic() + NO_TAKEOVER
                end_audio_session()
        elif old is None and self.power and self.was_managed:
            log.warning("Input changed while bridge was down, restoring volume to %d", self.restore_volume())
            self.was_managed = False
            self.save()
            self.onkyo.send("MVL%02X" % self.restore_volume())

    def on_volume(self, v):
        self.volume = v
        now = time.monotonic()
        if self.phase in (self.ENDING, self.FIXING):
            if self.step == "wait_volume" and v == self.target:
                if self.phase == self.FIXING and not self.we_powered:
                    log.info("Volume fixed, receiver left on (powered on externally)")
                    self.phase, self.step, self.deadline = self.IDLE, None, None
                    self.check_managed()
                    return
                self.onkyo.send("PWR00")
                self.step, self.tries = "wait_standby", 1
                self.deadline = now + CONFIRM_TIMEOUT * 2
            return
        if self.managed:
            if self.ramp_step is not None:
                return
            if v == MANAGED_VOLUME:
                self.settle_until = self.drift_deadline = None
            elif self.settle_until and now < self.settle_until:
                if self.v_before_pending and v < MANAGED_VOLUME:
                    self.v_before, self.v_before_pending = v, False
                    self.save()
            else:
                self.drift_deadline = now + DRIFT_SETTLE
        elif self.power is False and v >= MANAGED_VOLUME and self.phase == self.IDLE:
            log.warning("Receiver in standby at high volume %d: fixing", v)
            self.start_fix()

    def on_playback(self, playing):
        if playing == self.playing:
            return
        self.playing = playing
        if not playing:
            log.info("Playback stopped")
            if self.managed:
                self.silence_deadline = time.monotonic() + SILENCE_DELAY
            self.want_input = False
            return
        log.info("Playback started")
        self.silence_deadline = None
        if time.monotonic() < self.no_takeover_until:
            log.info("Session recently closed after input change, not taking over")
            return
        if self.phase != self.IDLE:
            log.info("%s interrupted by playback", self.phase)
            self.phase, self.step, self.deadline = self.IDLE, None, None
        if not self.onkyo.connected():
            log.warning("Receiver unreachable, audio plays without receiver control")
            return
        self.want_input = True
        self.power_cmd_at = time.monotonic()
        if not self.power:
            log.info("Turning receiver ON")
            self.onkyo.send("PWR01")
            self.pwr_cmd_at = self.power_cmd_at
        elif self.input != ONKYO_INPUT:
            log.info("Taking over: input %s -> %s", self.input, ONKYO_INPUT)
            self.onkyo.send("SLI" + ONKYO_INPUT)
        elif not self.managed:
            self.check_managed()
        elif self.volume != MANAGED_VOLUME and self.ramp_step is None:
            self.send_managed_volume()

    def start_ending(self):
        self.silence_deadline = None
        self.set_managed(False)
        end_audio_session()
        if not self.power:
            return
        if self.input != ONKYO_INPUT:
            log.info("Silence timeout, but receiver on input %s: leaving alone", self.input)
            return
        log.info("%gs of silence: volume back to %d, then standby",
                 SILENCE_DELAY, self.restore_volume())
        self.phase = self.ENDING
        self.restore_then_standby()

    def restore_then_standby(self):
        self.target = self.restore_volume()
        self.tries = 1
        self.drift_deadline = self.settle_until = None
        if self.volume == self.target:
            self.onkyo.send("PWR00")
            self.step = "wait_standby"
            self.deadline = time.monotonic() + CONFIRM_TIMEOUT * 2
        else:
            self.onkyo.send("MVL%02X" % self.target)
            self.step = "wait_volume"
            self.deadline = time.monotonic() + CONFIRM_TIMEOUT

    def start_fix(self):
        self.phase, self.step, self.tries = self.FIXING, "power_on", 0
        self.deadline = time.monotonic() + REPOWER_DELAY
        self.drift_deadline = self.silence_deadline = self.settle_until = None

    def fix_powered_on(self, we_powered):
        self.we_powered = we_powered
        log.info("Restoring volume %d", self.restore_volume())
        self.restore_then_standby()

    def tick_phase(self, now):
        if self.deadline is None or now < self.deadline:
            return
        if self.phase == self.FIXING and self.step == "power_on":
            if self.power:
                self.fix_powered_on(we_powered=True)
                return
            self.tries += 1
            log.info("Turning receiver back on to lower volume (attempt %d)", self.tries)
            self.onkyo.send("PWR01")
            self.step, self.deadline = "wait_on", now + CONFIRM_TIMEOUT * 2
        elif self.phase == self.FIXING and self.step == "wait_on":
            if self.tries < 2:
                log.warning("Receiver did not turn on, retrying in %ds", FIX_RETRY)
                self.step, self.deadline = "power_on", now + FIX_RETRY
            else:
                log.warning("Receiver did not turn on, waiting until available")
                self.step, self.deadline = "wait_available", None
        elif self.step in ("wait_volume", "wait_standby"):
            if self.tries < CONFIRM_TRIES:
                self.tries += 1
                if self.step == "wait_volume":
                    self.onkyo.send("MVL%02X" % self.target)
                    self.onkyo.send("MVLQSTN")
                else:
                    self.onkyo.send("PWR00")
                self.deadline = now + CONFIRM_TIMEOUT
                return
            log.error("Receiver did not confirm command (%s)", self.step)
            if self.step == "wait_volume":
                log.error("Volume could not be confirmed, leaving receiver on for safety")
            self.phase, self.step, self.deadline = self.IDLE, None, None

    def on_connected(self):
        for q in ("PWRQSTN", "SLIQSTN", "MVLQSTN"):
            self.onkyo.send(q)
        self.last_query = time.monotonic()
        if self.phase == self.FIXING and self.step == "wait_available":
            log.info("Receiver available again, resuming volume fix")
            self.step, self.tries = "power_on", 0
            self.deadline = time.monotonic() + REPOWER_DELAY

    def tick(self):
        now = time.monotonic()
        if not self.onkyo.connected():
            if self.onkyo.connect():
                self.on_connected()
            return
        if now - self.last_query > 60:
            self.onkyo.send("PWRQSTN")
            self.last_query = now
        self.tick_phase(now)
        self.tick_ramp(now)
        if self.want_input and self.playing and now - self.power_cmd_at > 5:
            self.power_cmd_at = now
            if self.power:
                self.onkyo.send("SLI" + ONKYO_INPUT)
            else:
                self.onkyo.send("PWR01")
                self.pwr_cmd_at = now
        if self.silence_deadline and now >= self.silence_deadline and not self.playing:
            self.start_ending()
        if self.settle_until and now >= self.settle_until:
            self.settle_until = None
            if self.managed and self.volume != MANAGED_VOLUME and self.ramp_step is None:
                self.send_managed_volume()
        if self.drift_deadline and now >= self.drift_deadline:
            self.drift_deadline = None
            if self.managed and self.volume is not None and self.volume != MANAGED_VOLUME:
                log.info("Receiver volume drifted to %d: restoring %d", self.volume, MANAGED_VOLUME)
                self.send_managed_volume()


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

def main():
    logging.basicConfig(
        level=get_conf("LOG_LEVEL", "INFO").upper(),
        stream=sys.stdout,
        format="%(levelname)s %(message)s"
    )

    host = ONKYO_HOST.strip()
    if host.lower() in ("false", "off", "no", "disabled", "0"):
        log.info("Onkyo bridge disabled by configuration (ONKYO_HOST=%s)", host)
        sys.exit(0)

    if not host or host.lower() == "auto":
        log.info("Onkyo bridge started in auto-discovery mode (input %s, volume %d, restore %d)",
                 ONKYO_INPUT, MANAGED_VOLUME, RESTORE_MAX)
    else:
        log.info("Onkyo bridge started for host %s (input %s, volume %d, restore %d)",
                 host, ONKYO_INPUT, MANAGED_VOLUME, RESTORE_MAX)

    onkyo = Onkyo(host, ONKYO_PORT)
    bridge = Bridge(onkyo)

    next_poll = 0.0
    while True:
        bridge.tick()
        if onkyo.sock:
            r, _, _ = select.select([onkyo.sock], [], [], 0.1)
            if r:
                for msg in onkyo.read():
                    bridge.on_message(msg)
        else:
            time.sleep(0.1)
        if time.monotonic() >= next_poll:
            next_poll = time.monotonic() + 0.5
            bridge.on_playback(is_audio_playing())


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
