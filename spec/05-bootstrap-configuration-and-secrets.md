# Specification 05: Bootstrap, Configuration & Secrets Management

## 1. SD Card Storage Architecture

The target SD image (`sdImage`) formats the card into two partitions:

1. **FAT32 Firmware Partition (`/boot/firmware`):**
   - Size: **64 MB** (compact footprint).
   - Read/write compatible out-of-the-box on macOS, Windows, and Linux PCs.
   - Houses Broadcom boot firmware, kernel binary, `config.txt`, and user configuration `soloist.env`.
2. **Ext4 System Partition (`/`):**
   - Uses the remaining SD storage for the immutable Nix store (`/nix/store`) and NixOS root files.

---

## 2. Configuration Contract: `soloist.env`

The `/boot/firmware/soloist.env` file enables zero-touch setup without requiring serial consoles, displays, or keyboards.

### 2.1 Secure Parsing (`soloist-config.service`)
`soloist.env` is **never sourced** by a shell to eliminate arbitrary code execution risks:
- Parsed line-by-line via a strict bash script running under `LC_ALL=C`.
- Format: `KEY=value` (whitespace trimmed, quotes optional but preserve internal spaces).
- Comment lines (`#`) and empty lines are discarded.

### 2.2 In-Memory Secrets (`/run/soloist-secrets`)
During boot, `soloist-config.service` populates a RAM-backed `tmpfs` directory:
- Permissions: `0700` owned by `root:root`.
- Generated secret and configuration files:
  - `soloist-api-key`: Spotify Soloist client key.
  - `tailscale-authkey`: Auth key for initial headless Tailscale node registration.
  - `shelly-host`: IP or hostname of the speaker power switch.
  - `discord-webhook`: Webhook URL for update failure/reboot alerts.
  - `onkyo-host`: IP address, host name, or `"false"`.
  - `onkyo-disabled`: Marker file created if `ONKYO_HOST=false` to inhibit `onkyo-bridge.service`.

---

## 3. Wi-Fi Configuration Generation

`soloist-config.service` dynamically renders `/etc/wpa_supplicant/imperative.conf`:
- **SSID Safety:** The network name (SSID) is converted to hexadecimal (`od -An -v -tx1`) to eliminate escaping issues with special characters, spaces, or emojis.
- **Protocol Transition:** Configures transition mode supporting both WPA2-PSK and WPA3-SAE (`ieee80211w=1`).
- **Ethernet Fallback:** If `WIFI_SSID` is empty, no Wi-Fi network is written and the system communicates solely via `eth0`.
- **Permissions:** File mode is locked to `0600` under user `wpa_supplicant`.

---

## 4. SD Card Flash Wear Prevention

Random small writes degrade micro-SD cards rapidly. NixOS is hardened against flash wear:

1. **Volatile In-Memory Logs:**
   ```nix
   services.journald.settings.Journal = {
     Storage = "volatile";
     RuntimeMaxUse = "50M";
   };
   ```
   System logs reside strictly in RAM and are never persisted to flash.
2. **RAM-Backed Temp Directories:**
   `boot.tmp.useTmpfs = true;` places `/tmp` in tmpfs.
3. **Filesystem Mount Options:**
   - `noatime`: Disables access timestamp writes when files are read.
   - `commit=60`: Batches metadata and data commits to the SD card once every 60 seconds.
   - Kernel sysctl: `vm.dirty_writeback_centisecs = 6000`, `vm.dirty_expire_centisecs = 6000`.
4. **No Automated Garbage Collection Rewrite Cycles:**
   Automatic store optimization and daily garbage collection are disabled to prevent bulk block rewriting on the card.
