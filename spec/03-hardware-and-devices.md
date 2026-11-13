# Specification 03: Hardware, Sound Cards & Device Profiles

## 1. Target Hardware Platform

- **Single-Board Computer:** Raspberry Pi 4 Model B (Broadcom BCM2711, quad-core Cortex-A72 @ 1.5 GHz, 2 GB to 8 GB LPDDR4 RAM).
- **Architecture:** `aarch64-linux`.
- **Boot Flow:** Broadcom firmware -> U-Boot -> Extlinux (`extlinux.conf`).
- **Boot Timeout:** `boot.loader.timeout = 0;` (bypasses the default 5-second syslinux boot menu delay for instant startup).

---

## 2. Audio Hardware & Device Tree Overlays

The `audioOutput` setting in an individual device profile selects and configures the physical audio interface:

| `audioOutput` Value | Physical Interface | `config.txt` Directives | Blacklisted Kernel Modules |
|:---|:---|:---|:---|
| `"jack"` | Onboard 3.5 mm analog jack | None (default BCM2835 PWM audio) | None |
| `"hifiberry-amp2"` | HiFiBerry Amp2 HAT (integrated amplifier) | `dtoverlay=hifiberry-dacplus-std`<br>`dtparam=audio=off`<br>`force_eeprom_read=0` | `snd_bcm2835` |
| `"hifiberry-digi"` | HiFiBerry Digi HAT (optical/coaxial S/PDIF) | `dtoverlay=hifiberry-digi`<br>`dtparam=audio=off`<br>`force_eeprom_read=0` | `snd_bcm2835` |

### 2.1 Hardware Configuration Rules (`config.txt`)
When using any HiFiBerry HAT (`amp2` or `digi`):
1. `dtparam = [ "audio=off" ]`: Disables the Raspberry Pi SoC onboard analog audio DAC.
2. `force_eeprom_read = 0`: Prevents the firmware from probing HAT onboard EEPROMs that can trigger device tree overlay conflicts on modern 6.x kernels.
3. `vc4-kms-v3d.noaudio = true`: Disables HDMI audio endpoints, ensuring a single clean ALSA sink exists on the system.
4. `snd_bcm2835` module is blacklisted in kernel parameters so ghost headphone devices do not disrupt PipeWire sink prioritization.

### 2.2 Unused Kernel Module Blacklist
To minimize boot time, conserve memory, and eliminate unnecessary interrupts, unneeded multimedia modules are blacklisted:
```text
bcm2835_v4l2, bcm2835_codec, bcm2835_isp, rpi_hevc_dec
```

---

## 3. Visual Health Indicator Protocol (`disable-leds.service`)

The onboard Raspberry Pi 4 LEDs (Red PWR LED and Green ACT LED) serve as a **hardware status indicator**:

1. **Booting Phase:**  
   Both LEDs remain solidly illuminated throughout boot to indicate power and system loading.
2. **Health Verification Phase:**  
   `disable-leds.service` runs after `multi-user.target`. It probes the systemd state of all critical audio daemons:
   - `pipewire.service`
   - `wireplumber.service`
   - `audio-arbiter.service`
   - `shairport-sync.service`
   - `bluetooth.service`
   - `soloist.service` (if an API key is present)
3. **State Transition:**  
   - Once all essential services are confirmed `active (running)`, the service removes kernel LED triggers and writes `0` to `/sys/class/leds/*/brightness`. Both LEDs turn completely off.
   - If any daemon fails to reach a healthy state within 60 seconds, the service fails and **LEDs remain lit**, providing immediate physical troubleshooting feedback without requiring SSH access.

---

## 4. Current Device Profiles

Device profiles reside in `hosts/devices/<name>.nix`:

### 4.1 Chambre de Léo — [`hosts/devices/chambre-de-leo.nix`](../hosts/devices/chambre-de-leo.nix)
- **Hostname:** `chambre-de-leo`
- **Display Name:** `Chambre de Léo`
- **Audio Output:** `hifiberry-amp2`
- **DSP Equalizer:** Active (Moode Audio *Lo Boost* curve: 31 Hz +12.24 dB, 63 Hz +4.32 dB, preamp -4.80 dB).

### 4.2 Chambre de Sarah — [`hosts/devices/chambre-de-sarah.nix`](../hosts/devices/chambre-de-sarah.nix)
- **Hostname:** `chambre-de-sarah`
- **Display Name:** `Chambre de Sarah`
- **Audio Output:** `jack`
- **DSP Equalizer:** Disabled (flat output).

### 4.3 Télévision — [`hosts/devices/television.nix`](../hosts/devices/television.nix)
- **Hostname:** `television`
- **Display Name:** `Télévision`
- **Audio Output:** `hifiberry-digi` (S/PDIF optical/coaxial to Onkyo AV receiver).
- **Receiver Integration:** Onkyo eISCP bridge enabled (`onkyo.enable = true`).
