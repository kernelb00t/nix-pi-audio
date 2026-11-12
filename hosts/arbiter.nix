# Audio arbiter: one source at a time among Spotify (Soloist), AirPlay
# (shairport-sync) and Bluetooth; the last to start wins and the others are
# disconnected. Also switches the speakers' Shelly plug when SHELLY_HOST is set
# in soloist.env. See arbiter.py.
{
  config,
  lib,
  pkgs,
  settings,
  ...
}:
let
  py = pkgs.python3.withPackages (
    ps: with ps; [
      websockets
      dbus-next
    ]
  );
  script = pkgs.writeScript "audio-arbiter" ''
    #!${py}/bin/python3
    ${builtins.readFile ./arbiter.py}
  '';
in
{
  systemd.services.audio-arbiter = {
    description = "Audio source arbiter (Spotify, AirPlay, Bluetooth) and speaker power";
    wantedBy = [ "multi-user.target" ];
    after = [
      "soloist-config.service"
      "soloist.service"
      "shairport-sync.service"
      "bluetooth.service"
      "network-online.target"
    ];
    wants = [ "network-online.target" ];
    environment = {
      SOLOIST_WS = "ws://127.0.0.1:${toString settings.soloistWsPort}";
      STATE_DIR = "/run/audio-arbiter";
      SHELLY_HOST_FILE = "/run/soloist-secrets/shelly-host";
      OFF_DELAY = toString settings.shellyOffDelaySec;
      PYTHONUNBUFFERED = "1";
    };
    path = [ pkgs.systemd ];
    serviceConfig = {
      ExecStart = script;
      Restart = "always";
      RestartSec = 5;
      # Root: it restarts soloist and shairport-sync, and talks to BlueZ.
      # The Soloist WebSocket has no authentication: it only listens on
      # 127.0.0.1.
      RuntimeDirectory = "audio-arbiter";
      RuntimeDirectoryMode = "0775";
      RuntimeDirectoryPreserve = true;
      Group = "audio-arbiter";
      NoNewPrivileges = false;
      ProtectHome = true;
      PrivateTmp = true;
    };
  };

  users.groups.audio-arbiter = { };
  # shairport-sync writes its play state in /run/audio-arbiter (group-writable).
  users.users.${config.services.shairport-sync.user}.extraGroups = [ "audio-arbiter" ];
}
