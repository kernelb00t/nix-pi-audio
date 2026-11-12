# nix-pi-audio

Raspberry Pi 4 running NixOS as a Spotify Connect speaker, with
[Spotify Soloist](https://developer.spotify.com/documentation/soloist), the
official headless Spotify client.

- One image per device, in `hosts/devices/`: `chambre-de-leo` (HiFiBerry Amp2) and
  `chambre-de-sarah` (3.5 mm jack). Common code, per-device name and audio output.
- Few writes to the SD card: logs, `/tmp` and the Soloist cache live in RAM (see
  "SD card wear").
- Wi-Fi, Soloist API key and Tailscale key: in a `soloist.env` file on the SD
  card, editable from any computer.
- Soloist binary: downloaded and kept up to date by the Pi itself (see below).
- Admin: Tailscale SSH.

## Files

| File | Role |
|---|---|
| `hosts/settings.nix` | defaults shared by every device: cache sizing, kernel build mode |
| `hosts/devices/<name>.nix` | per-device settings: hostname, device name, audio output |
| `hosts/default.nix` | host: boot, `config.txt`, PipeWire, network, Tailscale, users |
| `hosts/sd-config.nix` | reads `soloist.env` at boot (Wi-Fi, secrets) |
| `hosts/soloist.nix` | Soloist service and its daily updater |
| `hosts/soloist.env.example` | template copied to the SD card |

## Settings (build time)

Defaults are in `hosts/settings.nix`; each device overrides what differs in
`hosts/devices/<name>.nix` (add a device: new file, then its name in `soloistDevices`
in `flake.nix` and in the workflow matrix). Settings:

- `deviceName`: name shown in the Spotify device picker.
- `audioOutput`: `"jack"` or `"hifiberry-amp2"`.
  - `jack`: onboard audio on (`dtparam=audio=on`).
  - `hifiberry-amp2`: onboard audio off, `dtoverlay=hifiberry-dacplus-std`
    (the overlay HiFiBerry documents for the Amp2 on kernels >= 6.1.77) and
    `force_eeprom_read=0` so the HAT EEPROM does not load another overlay.
  - HDMI audio is always off (`vc4-kms-v3d,noaudio`), so the chosen output is
    the only one and PipeWire uses it by default.
- `crossCompileKernel`: the Raspberry Pi kernel (from nixos-hardware) is in no
  binary cache. `true` cross-compiles it from x86_64-linux (fast); `false`
  builds it natively on aarch64. Everything else comes from cache.nixos.org.
  The kernel is built with `autoModules = false` (`bcm2711_defconfig` plus the
  NixOS options, not every driver of the tree as a module), which cuts its
  build time several times. Jack, HiFiBerry, Wi-Fi and Ethernet drivers are in
  the defconfig.

## Sources and speaker power

Three sources play through the same output, all named after the device
(`deviceName`): Spotify (Soloist), AirPlay 2 (shairport-sync built with
AirPlay 2, clock from `nqptp`) and a Bluetooth A2DP receiver (open pairing,
paired devices remembered).

Only one source plays at a time. `audio-arbiter` (`hosts/arbiter.py`) watches them
(Soloist WebSocket on 127.0.0.1, shairport-sync session hooks, BlueZ media
transport) and, when one starts, **disconnects** the others so the person sees
it: Soloist and shairport-sync are restarted, the Bluetooth device is
disconnected. The last source to start wins; a source just disconnected cannot
trigger the arbiter again for a few seconds.

If `SHELLY_HOST` is set in `soloist.env`, the arbiter also drives a Shelly
(Gen2 or later, no authentication) plug that powers the speakers, over HTTP
(`Switch.Set`): on when a source plays, off 20 seconds after the last one
stops (`shellyOffDelaySec`). It never touches the plug while idle at boot. 

## SD card wear

- Logs are in RAM only (`Storage=volatile`, 50 MB): they are lost at reboot, so
  read `journalctl` before rebooting when debugging.
- `/tmp` is a tmpfs; the root filesystem is mounted `noatime` and flushes every
  60 s; core dumps are off.
- The Soloist playback cache is a tmpfs on `/var/cache/soloist`, sized from the
  RAM of each Pi: the tmpfs takes `cacheRamPercent` (30 %) of the RAM and Soloist
  is given `cacheFillPercent` (85 %) of it, computed at start (at least 100 MB).
  It is empty after every reboot.
- No automatic Nix garbage collection or store optimisation (both rewrite the
  store). Clean by hand if the card fills up:
  `nix-collect-garbage --delete-older-than 14d`.
- Still written, on purpose: the Soloist session (`/var/lib/soloist`) and the
  Tailscale state (a few KB, rarely), the Soloist binary when a new build is
  published, and `/etc/wpa_supplicant/imperative.conf` at each boot (a few
  hundred bytes).

## Build the image

On x86_64 Linux with Nix, flakes, and aarch64 emulation (binfmt: on Debian,
`qemu-user-binfmt` and `extra-platforms = aarch64-linux` in `nix.conf`):

```bash
nix build .#chambre-de-leo-image      # or .#chambre-de-sarah-image
ls result/sd-image/   # <device>-*.img.zst
```

The first build compiles the kernel; later builds reuse it until the
`nixpkgs-kernel` or `nixos-hardware-kernel` pin of `flake.lock` changes (the
kernel depends on nothing else).

On GitHub, two workflows:

- `kernel` (Sunday 03:00 UTC, or by hand): bumps the two kernel
  pins, compiles the kernel if it changed (about 3 h on the 2-core runners of
  a private repo; free on a public one), publishes it as a release `kernel-<hash>` and commits the new
  `flake.lock`. Keeps the 3 newest kernel releases.
- `image` (every push to these files, or by hand): imports the
  kernel release, builds one image per device and publishes it as an artifact
  kept 7 days. It fails at once, telling you to run the kernel workflow, if the
  kernel release is missing. By hand it can use the native arm64 runner
  (`ubuntu-24.04-arm`).

## Flash and configure

1. Flash: `zstd -dc result/sd-image/*.img.zst | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress`
   (or Raspberry Pi Imager / balenaEtcher with the `.img.zst`).
2. Re-insert the card: the `FIRMWARE` partition (FAT) opens on any computer.
   Copy `hosts/soloist.env.example` to `soloist.env` and fill it in:

   ```bash
   WIFI_SSID=MyNetwork
   WIFI_PASSWORD=my wifi password
   WIFI_COUNTRY=FR
   SOLOIST_API_KEY=...
   TAILSCALE_AUTHKEY=tskey-auth-...
   SHELLY_HOST=192.168.1.50   # optional, see "Sources and speaker power"
   ```

   - Quotes are optional. Empty `WIFI_SSID`: Ethernet only. Empty
     `WIFI_PASSWORD`: open network. WPA2 and WPA3 are accepted (password of 8
     to 63 characters).
   - `SOLOIST_API_KEY`: created at
     <https://developer.spotify.com/dashboard/soloist> with a Premium account.
     Personal, never share it.
   - `TAILSCALE_AUTHKEY`: a key from the Tailscale admin console, pre-approved
     and **tagged** (tagged nodes do not expire; an untagged node expires after
     180 days by default and drops off Tailscale). Only used for the first
     login; it can be removed afterwards.
3. Boot the Pi. On first boot the root partition grows to the whole card, the
   Pi joins Wi-Fi and Tailscale, downloads Soloist (one minute after boot,
   retried every 10 minutes if it fails), then starts it.
4. In the Spotify app, on the same network, pick the device in the device
   picker. The session is stored in `/var/lib/soloist`; no other pairing step.

The file is read at every boot: to change Wi-Fi network or key, edit
`soloist.env` on the card (or `/boot/firmware/soloist.env` on the Pi) and
reboot.

The SD card holds these secrets in clear text: anyone with the card can read
them.

## Tailscale access

Admin is over Tailscale SSH only: your Tailscale policy must allow SSH from the
admin machine to the Pis as user `admin` (passwordless sudo). There is no
OpenSSH and no password. If the Pi drops off Tailscale (logout, expired node),
put a new `TAILSCALE_AUTHKEY` in `soloist.env` on the card and reboot: it logs
in again.

## Updates

**NixOS** (config changes, nixpkgs updates), from the admin machine:

```bash
nixos-rebuild switch --flake github:kernelb00t/nix-pi-audio#chambre-de-leo --target-host admin@chambre-de-leo --sudo
```

The build runs locally (kernel cross-compiled), the closure is copied over
Tailscale. The firmware partition (`config.txt`, overlays, U-Boot) is rewritten
on every switch, so an audio output change applies after a reboot. `soloist.env`
is left alone.

**Soloist** updates itself:

- Spotify publishes the arm64 build at a fixed URL
  (`soloist_release_arm64.tar.gz`, no version, no checksum) and forbids
  redistributing it, so it cannot be a Nix package or sit in a binary cache.
- Each build **expires 90 days after its build date** (exit code 10).
- `soloist-update` runs one minute after boot and every day between 04:00 and
  04:30 (retried up to 6 times, every 10 minutes, on failure): download, compare with the installed binary, check that the
  new one runs (`soloist --version`), replace it atomically in
  `/var/lib/soloist-bin`, restart `soloist`. If anything fails, the current
  binary stays.
- `soloist` restarts on failure, except on exit code 10 (expired build:
  waiting for the next update is the only fix).

An expired build therefore means the update has been failing for weeks: check
`systemctl status soloist-update`.

## Troubleshooting

```bash
systemctl status soloist soloist-update soloist-config wpa_supplicant
journalctl -u soloist -b            # remaining build lifetime is logged at startup
journalctl -u soloist-config -b     # what was read from soloist.env
sudo systemctl start soloist-update # force an update now
wpctl status                        # PipeWire outputs (as root: sudo -u pipewire ...)
```

## Known limits

- Soloist and the updater wait for NTP (no clock on the Pi) for at most
  5 minutes: UDP 123 must be allowed out of the network.
- Not checked yet: whether `soloist --version` refuses an already expired build.

- Not tested on hardware before the first install: check sound on the chosen
  output, and Spotify Connect discovery.
- The Soloist binary is built for Raspberry Pi OS (glibc 2.38+). On NixOS it
  runs through nix-ld; it loads `libpipewire` and `client.conf` from the
  PipeWire package (`PIPEWIRE_CONFIG_DIR`).
- Soloist only takes its API key as a command-line argument, so the key is
  visible in the process list on the Pi.
- The LAN interfaces are trusted by the firewall: Spotify Connect discovery uses
  mDNS and a local HTTP port that Soloist does not document. To tighten once the
  port is known (`ss -tulpn` on the Pi).
