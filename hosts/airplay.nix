# AirPlay 2 receiver: shairport-sync built with AirPlay 2 and the nqptp clock.
# The device appears under settings.deviceName. It plays through PipeWire
# (system-wide), like Soloist. Play state is reported to the arbiter through a
# file (see arbiter.nix), which also disconnects it by restarting the service.
{
  config,
  lib,
  pkgs,
  settings,
  ...
}:
let
  stateFile = "/run/audio-arbiter/airplay";
  hook = state: pkgs.writeShellScript "airplay-${state}" (
    if state == "start" then "touch ${stateFile}" else "rm -f ${stateFile}"
  );
in
{
  # AirPlay 2 needs a PTP clock: nqptp, on UDP ports 319 and 320.
  systemd.services.nqptp = {
    description = "Network Precision Time Protocol for shairport-sync (AirPlay 2)";
    wantedBy = [ "multi-user.target" ];
    before = [ "shairport-sync.service" ];
    after = [ "network.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.nqptp}/bin/nqptp";
      Restart = "always";
      RestartSec = 5;
      AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
      CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
      DynamicUser = true;
      ProtectSystem = "strict";
      ProtectHome = true;
    };
  };

  # mDNS announcement (AirPlay and Bluetooth names are the Spotify name).
  services.avahi = {
    enable = true;
    settings.publish.disable-user-service-publishing = false;
  };

  services.shairport-sync = {
    enable = true;
    package = pkgs.shairport-sync-airplay2;
    openFirewall = false; # the LAN interfaces are trusted (default.nix)
    settings = {
      general = {
        name = settings.deviceName;
        output_backend = "pipewire";
        # A new AirPlay client takes over: one source at a time.
        allow_session_interruption = "yes";
      };
      sessioncontrol = {
        run_this_before_play_begins = "${hook "start"}";
        run_this_after_play_ends = "${hook "stop"}";
        wait_for_completion = "no";
      };
    };
  };
  systemd.services.shairport-sync = {
    wants = [ "nqptp.service" "avahi-daemon.service" "pipewire.service" ];
    after = [ "nqptp.service" "avahi-daemon.service" "pipewire.service" "wireplumber.service" ];
    environment = {
      PIPEWIRE_RUNTIME_DIR = "/run/pipewire";
      PIPEWIRE_CONFIG_DIR = "${pkgs.pipewire}/share/pipewire";
    };
  };
  users.users.${config.services.shairport-sync.user}.extraGroups = [
    "pipewire"
    "audio"
  ];
}
