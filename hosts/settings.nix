# Defaults shared by every Soloist Pi. Each device overrides what differs in
# devices/<name>.nix (see README.md). flake.nix merges the two.
{
  # Hostname, also the machine name on Tailscale.
  hostName = "soloist-pi";

  # Name shown in the Spotify device picker (also used for AirPlay and Bluetooth).
  deviceName = "Soloist Pi";

  # Audio output: "jack" (onboard 3.5 mm jack) or "hifiberry-amp2".
  audioOutput = "jack";

  # Soloist playback cache, kept in RAM (tmpfs), so the SD card is not written.
  # The tmpfs takes cacheRamPercent of the RAM of the Pi it runs on; Soloist is
  # given cacheFillPercent of that tmpfs (computed at start, at least 100 MB).
  cacheRamPercent = 30;
  cacheFillPercent = 85;

  # Local port of Soloist's WebSocket API (127.0.0.1 only, no authentication):
  # the arbiter reads the playback state from it.
  soloistWsPort = 8765;

  # Speakers' Shelly plug: its address is SHELLY_HOST in soloist.env (optional).
  # Switched on when a source plays, off after this many seconds of silence.
  shellyOffDelaySec = 20;

  # The Raspberry Pi kernel is not in the NixOS binary cache. true: cross-compile
  # it from x86_64-linux (fast, for any x86_64 Linux builder);
  # false: build it natively on aarch64 (the Pi itself, an aarch64 builder).
  crossCompileKernel = true;
}
