# Onkyo AV receiver bridge: controls power, input and volume of an Onkyo receiver
# connected to the Pi (over eISCP, TCP port 60128 with UDP auto-discovery).
# Enabled when settings.onkyo.enable is true (e.g. for hosts/devices/television.nix).
{
  config,
  lib,
  pkgs,
  settings,
  ...
}:
let
  onkyoSettings = settings.onkyo or { enable = false; };
  script = pkgs.writeScript "onkyo-bridge" ''
    #!${pkgs.python3}/bin/python3
    ${builtins.readFile ./onkyo-bridge.py}
  '';
in
{
  systemd.services.onkyo-bridge = lib.mkIf (onkyoSettings.enable or false) {
    description = "Onkyo AV receiver bridge (eISCP power, input, volume)";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [
      "network-online.target"
      "soloist-config.service"
      "audio-arbiter.service"
      "pipewire.service"
    ];
    # If ONKYO_HOST=false is set in soloist.env, soloist-config creates this marker file
    unitConfig.ConditionPathExists = "!/run/soloist-secrets/onkyo-disabled";
    environment = {
      ONKYO_INPUT = onkyoSettings.input or "03";
      MANAGED_VOLUME = toString (onkyoSettings.managedVolume or 60);
      RESTORE_MAX = toString (onkyoSettings.restoreMax or 40);
      SILENCE_DELAY = toString (onkyoSettings.silenceDelay or 20);
      RAMP_DELAY = toString (onkyoSettings.rampDelay or 3);
      RAMP_FROM = toString (onkyoSettings.rampFrom or 25);
      RAMP_TIME = toString (onkyoSettings.rampTime or 3);
      STATE_DIRECTORY = "/var/lib/onkyo-bridge";
      PYTHONUNBUFFERED = "1";
    };
    path = with pkgs; [
      systemd
      bluez
    ];
    serviceConfig = {
      ExecStart = script;
      Restart = "always";
      RestartSec = 3;
      StateDirectory = "onkyo-bridge";
      NoNewPrivileges = false;
      ProtectHome = true;
      PrivateTmp = true;
    };
  };
}
