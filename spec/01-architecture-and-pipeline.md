# Specification 01: Audio Pipeline & DSP Architecture

## 1. Pipeline Overview

All audio sources (Spotify Soloist, AirPlay 2 via Shairport-Sync, and Bluetooth via BlueZ) stream stereo PCM audio (44.1 kHz / 48 kHz, 16/24-bit) into a **system-wide PipeWire daemon** (`services.pipewire.systemWide = true`).

```mermaid
flowchart TD
    subgraph Clients["Audio Sources"]
        S["Spotify Soloist"]
        A["Shairport-Sync (AirPlay 2)"]
        B["BlueZ (Bluetooth A2DP)"]
    end

    subgraph PipeWire["PipeWire Server (System-Wide)"]
        P_ALSA["PipeWire ALSA Module (/run/pipewire)"]
        
        subgraph DSP["DSP Filter-Chain (Optional)"]
            EQ_IN["effect_input.eq (Default Virtual Sink)"]
            BQ1["Biquad Filter 1 (bq_peaking)"]
            BQ2["Biquad Filter 2 (bq_highshelf)"]
            EQ_OUT["effect_output.eq"]
            EQ_IN --> BQ1 --> BQ2 --> EQ_OUT
        end

        PW_SINK["ALSA Physical Output Node (WirePlumber Route: 100%)"]
    end

    subgraph Hardware["Audio Hardware"]
        SINK_JACK["Onboard Jack (bcm2835)"]
        SINK_AMP2["HiFiBerry Amp2 (I2S DAC)"]
        SINK_DIGI["HiFiBerry Digi (S/PDIF Optical/Coax)"]
    end

    Clients --> P_ALSA
    P_ALSA -->|"If EQ is enabled"| EQ_IN
    P_ALSA -->|"If EQ is disabled"| PW_SINK
    EQ_OUT --> PW_SINK

    PW_SINK --> SINK_JACK
    PW_SINK --> SINK_AMP2
    PW_SINK --> SINK_DIGI
```

---

## 2. PipeWire & WirePlumber Configuration

### 2.1 System-Wide Mode (`systemWide = true`)
- PipeWire runs under the `pipewire` system user with no desktop login session.
- Runtime directory is `/run/pipewire`.
- Client access is granted through the `pipewire` system group and unix domain sockets.
- Audio clients (Soloist, Shairport-Sync, BlueZ) feed audio via `libasound_module_pcm_pipewire.so`.

### 2.2 WirePlumber Routing & 100% Default Volume
- **Hardware Sink Volume at 100%:**  
  By default, WirePlumber initializes physical ALSA sinks at 40% volume (-24 dB). To preserve dynamic range and let application clients (or the Onkyo receiver) control listening volume, WirePlumber is explicitly configured with:
  ```nix
  wireplumber.extraConfig."50-default-volume"."wireplumber.settings" = {
    "device.routes.default-sink-volume" = 1.0;
  };
  ```
- **Embedded Optimization (Camera Probing Disabled):**  
  WirePlumber by default probes V4L2 and `libcamera` devices, producing `DmaBufAllocator` errors and delaying startup on headless audio boards. Camera capture is disabled:
  ```nix
  wireplumber.extraConfig."10-disable-camera"."wireplumber.profiles" = {
    main = { "hardware.video-capture" = "disabled"; };
  };
  ```

---

## 3. Parametric DSP Equalizer (`hosts/equalizer.nix`)

### 3.1 Filter-Chain Architecture
The equalizer is implemented using PipeWire's built-in `libpipewire-module-filter-chain`.
- **Input Node Name:** `effect_input.eq` (registered as an audio sink for incoming streams).
- **Output Node Name:** `effect_output.eq` (connected to the physical ALSA playback sink).
- **Stereo Processing & Port Names:**  
  PipeWire biquad filter nodes (`bq_peaking`, `bq_highshelf`, `bq_lowshelf`) are mono primitives with a single input port `In` and a single output port `Out`.  
  To process stereo signals without channel imbalances or `unknown output port` errors, the filter chain specifies:
  ```text
  audio.channels = 2
  audio.position = [ "FL" "FR" ]
  ```
  PipeWire automatically clones the mono filter graph across both left and right audio channels.

### 3.2 Routing Priority
To ensure incoming audio automatically routes through the equalizer rather than bypassing directly to the raw ALSA sink, the priority of `effect_input.eq` is raised:
```text
priority.driver = 2000
priority.session = 2000
```

### 3.3 Gain Structure & Headroom (Preamp)
Applying positive gain (boost) requires a negative global preamplification gain (**Preamp**) to prevent digital clipping (exceeding 0 dBFS).  
For example, in `hosts/devices/chambre-de-leo.nix` (Moode Audio *Lo Boost* migration):
- `preamp` = -4.80 dB
- Band 1: 31 Hz, Q = 1.41, Gain = +12.24 dB (relative to flat reference)
- Band 2: 63 Hz, Q = 1.41, Gain = +4.32 dB
