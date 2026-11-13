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
| `hosts/autoupgrade.nix` | nightly update from the `prod` branch, Cachix cache, Discord notifications |
| `hosts/soloist.nix` | Soloist service and its daily updater |
| `hosts/soloist.env.example` | template copied to the SD card |

## Settings (build time)

Defaults are in `hosts/settings.nix`; each device overrides what differs in
`hosts/devices/<name>.nix` (add a device: new file, then its name in `soloistDevices`
in `flake.nix` and in the `image` matrix and the host lists of `ci`). Settings:

- `deviceName`: name shown in the Spotify device picker.
- `audioOutput`: `"jack"` or `"hifiberry-amp2"`.
  - `jack`: onboard audio on (`dtparam=audio=on`).
  - `hifiberry-amp2`: onboard audio off, `dtoverlay=hifiberry-dacplus-std`
    (the overlay HiFiBerry documents for the Amp2 on kernels >= 6.1.77) and
    `force_eeprom_read=0` so the HAT EEPROM does not load another overlay.
  - HDMI audio is always off (`vc4-kms-v3d,noaudio`), so the chosen output is
    the only one and PipeWire uses it by default.
- `autoUpgradeReboot`: `false` (default) or `true`, see "Automatic updates".
- `crossCompileKernel`: the Raspberry Pi kernel (from nixos-hardware) is in no
  binary cache official: the `ci` workflow builds it and pushes it to the Cachix cache. `true` cross-compiles it from x86_64-linux (fast); `false`
  builds it natively on aarch64. Everything else comes from cache.nixos.org.
  The kernel is built with `autoModules = false` (`bcm2711_defconfig` plus the
  NixOS options, not every driver of the tree as a module), which cuts its
  build time several times. Jack, HiFiBerry, Wi-Fi and Ethernet drivers are in
  the defconfig.

## Sources and speaker power

Three sources play through the same output, all named after the device
(`deviceName`): Spotify (Soloist), AirPlay 2 (shairport-sync built with
AirPlay 2, clock from `nqptp`) and a Bluetooth A2DP receiver named "<device name> BT" (open pairing,
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

On GitHub, see "Branches, cache and workflows" below: images are only built on
demand (workflow `image`), and the kernel comes from the Cachix cache.

## Branches, cache and workflows

- `main`: development branch. Renovate and the weekly `kernel` workflow push
  flake updates to it.
- `prod`: what the Pis run. Only the `ci` workflow moves it, by fast-forward
  (never forced), once the commit of `main` has passed every check. If the CI
  fails, `prod` does not move and the Pis stay on the previous version.
- Cachix cache `kernelb00t` (public, <https://kernelb00t.cachix.org>, key
  `kernelb00t.cachix.org-1:8IJNajMb8SDKZVtPIfDZrbm8XPAEmOmZANZ8E+Ps6V0=`): holds
  the Raspberry Pi kernel (in no official cache) and the other paths that
  cache.nixos.org lacks. The Pis and the `image` workflow read it; only the
  `ci` workflow writes to it. The free plan is 5 GB: watch its size on
  cachix.org, and delete old paths if needed.
- **Secret to create**: `CACHIX_AUTH_TOKEN`, repository secret (Settings >
  Secrets and variables > Actions), a write token of the cache `kernelb00t`
  (cachix.org > cache > Settings > Auth tokens). Without it, `ci` fails at once
  with a message saying so.

Workflows:

- `ci` (push to `main`, or by hand): evaluates both hosts; compares the kernel
  derivation with the one of `prod` and, if it differs (or is not in the cache),
  builds it and pushes it to Cachix, otherwise skips that step; builds both
  systems (`toplevel`, aarch64 under QEMU, nearly everything is downloaded) and
  pushes them to the cache; runs `nix flake check`; then fast-forwards `prod`
  (`promote` job, the only one with write access to the repository). Started by
  hand from another branch, it builds and checks but never touches `prod`.
- `kernel` (Sunday 03:00 UTC, or by hand): bumps the `nixpkgs-kernel` and
  `nixos-hardware-kernel` pins and commits `flake.lock` to `main`, then starts
  `ci`. It compiles nothing. A kernel compilation (about 1 h 30) therefore
  happens in `ci`, once per kernel bump.
- `image` (by hand, or on a `v*` tag): builds one SD image per device and
  publishes it as an artifact kept 7 days. It fails at once if the kernel is
  not in the cache (run `ci` first). By hand it can use the native arm64 runner
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
   DISCORD_WEBHOOK=...        # optional, see "Automatic updates"
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

### Automatic updates (NixOS)

Each Pi runs `system.autoUpgrade` (`hosts/autoupgrade.nix`) every night at 04:30
(random delay up to 20 minutes): `nixos-rebuild switch` on
`github:kernelb00t/nix-pi-audio/prod#<hostName>`, with the Cachix cache as a
substituter (kernel and the rest are downloaded, nothing is compiled on the Pi).
The new generation is active at once, except for the kernel and firmware, which
need a reboot.

- `autoUpgradeReboot` (`hosts/settings.nix`, per device in `hosts/devices/`):
  `false` by default, no reboot. `true`: the Pi reboots by itself, only between
  04:00 and 05:30, and only if the kernel, initrd or firmware changed.
- Discord notifications, optional: put `DISCORD_WEBHOOK=https://discord.com/api/webhooks/<id>/<token>`
  in `soloist.env` (read at boot, so reboot or `sudo systemctl restart soloist-config`).
  The Pi then posts a message when an update fails, and, with
  `autoUpgradeReboot = false`, once per generation when a reboot is needed.
  The webhook is a secret: it is validated, stored under `/run/soloist-secrets`
  (root only) and never written to the logs. Without it, nothing is sent.
- Follow it: `systemctl list-timers nixos-upgrade`, `journalctl -u nixos-upgrade`.
  Force one now: `sudo systemctl start nixos-upgrade`.

Existing Pis must be switched once by hand (below) to get this module; they
follow `prod` from then on.

### Rollback

- A bad update is on the Pi: `sudo nixos-rebuild switch --rollback` (previous
  generation; 5 are kept), or choose the generation in the U-Boot menu at boot.
  The next nightly update will upgrade again if `prod` has not changed: stop it
  first (`sudo systemctl stop nixos-upgrade.timer`, until reboot) or fix `prod`.
- A bad update is on `prod`: `git revert <commit>` on `prod`, push (the Pis pick
  it up that night, or start `nixos-upgrade` by hand), then merge `prod` into
  `main` (`git checkout main && git merge origin/prod && git push`) so that
  `prod` stays an ancestor of `main` and the CI can still fast-forward it. The
  `ci` workflow refuses any push that is not a fast-forward. Cleaner when there
  is time: revert on `main` and let the CI promote it.

### Manual

**NixOS**, from the admin machine (first switch, or to bypass `prod`):

```bash
nixos-rebuild switch --flake github:kernelb00t/nix-pi-audio#chambre-de-leo --target-host admin@chambre-de-leo --sudo
```

The kernel comes from the Cachix cache (or is cross-compiled locally if absent), the closure is copied over
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
