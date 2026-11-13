# `nix-pi-audio` Specifications

> **Core Principle:** This directory constitutes the **Single Source of Truth** for the project. The codebase and NixOS modules are an implementation of these specifications. Any contributor (human or AI agent) must consult and adhere to these specifications before making architectural or functional modifications.

---

## 📑 Specification Index

| Document | Topic | Description |
|:---|:---|:---|
| **01** | [`01-architecture-and-pipeline.md`](01-architecture-and-pipeline.md) | Audio Pipeline | PipeWire system-wide server, WirePlumber routing, DSP parametric equalizer. |
| **02** | [`02-audio-sources-and-arbitration.md`](02-audio-sources-and-arbitration.md) | Sources & Arbitration | Soloist (Spotify), AirPlay 2, Bluetooth, and smart source arbiter (`arbiter.py`). |
| **03** | [`03-hardware-and-devices.md`](03-hardware-and-devices.md) | Hardware & Devices | Raspberry Pi 4 platform, audio HATs (Jack, Amp2, Digi), LED indicators, device profiles. |
| **04** | [`04-onkyo-receiver-bridge.md`](04-onkyo-receiver-bridge.md) | Onkyo Receiver Bridge | eISCP protocol, UDP auto-discovery, power control, subwoofer ramp, volume management. |
| **05** | [`05-bootstrap-configuration-and-secrets.md`](05-bootstrap-configuration-and-secrets.md) | Bootstrap & Secrets | FAT32 `soloist.env`, secrets in RAM, WPA2/WPA3 Wi-Fi, SD card flash protection. |
| **06** | [`06-ci-cd-and-upgrade-lifecycle.md`](06-ci-cd-and-upgrade-lifecycle.md) | CI/CD & Upgrades | Two-tier flake inputs, kernel cross-compilation, Cachix binary cache, nightly auto-upgrade. |

---

## 🎯 Architecture Goals & Philosophy

1. **Zero-Friction Headless Audiophile Experience:**  
   The system runs entirely headless with no display, no local UI, and no custom client app. Users interact exclusively through their native apps: Spotify Connect, iOS/macOS AirPlay 2, or Android/Windows Bluetooth A2DP.

2. **Automatic Conflict Resolution ("Last Playing Source Wins"):**  
   Only one source may output audio at any time. When a user starts playback from a new source, the previous source is cleanly disconnected (not merely paused or muted). This immediately notifies the previous client application and releases the audio pipeline.

3. **Hardware Longevity & Acoustic Safety:**  
   - **SD Card Protection:** No logs or caches are written to flash storage during normal operation (`journald` in RAM tmpfs, `/tmp` in tmpfs, Spotify playback cache in RAM, `noatime`, 60-second batch write commits).
   - **Acoustic Protection (Subwoofer Ramp):** The Onkyo AV receiver bridge enforces a soft logarithmic volume ramp when powering on from standby, protecting active subwoofers from power-on transients.
   - **Hardware Health Visual Indicator:** Onboard ACT and PWR LEDs remain lit throughout boot and extinguish only after all audio services are confirmed healthy.

4. **Zero-Compilation on Edge Devices:**  
   - Raspberry Pis never compile packages locally.
   - The Linux kernel is cross-compiled from x86_64 in CI in under 4 minutes.
   - Updates are continuously cached in Cachix and automatically deployed nightly without interruptions.

---

## 📖 Glossary & Key Terms

- **A2DP:** *Advanced Audio Distribution Profile* (Bluetooth stereo audio streaming).
- **ALSA:** *Advanced Linux Sound Architecture* (Linux kernel sound subsystem).
- **Arbiter:** Background daemon (`audio-arbiter.service`) managing mutual exclusivity among audio inputs.
- **eISCP:** *Ethernet Interactive Serial Control Protocol* (network control protocol used by Onkyo/Pioneer AV receivers on TCP/UDP port 60128).
- **HAT:** *Hardware Attached on Top* (Raspberry Pi expansion board, e.g. HiFiBerry Amp2 or Digi).
- **nqptp:** *Not Quite PTP* (Network Precision Time Protocol clock daemon for AirPlay 2).
- **PEQ:** *Parametric Equalizer* (digital audio filter chain using PipeWire biquad primitives).
- **Soloist:** Official Spotify Connect daemon for embedded Linux.
- **S/PDIF:** *Sony/Philips Digital Interface* (optical/coaxial digital audio output).
