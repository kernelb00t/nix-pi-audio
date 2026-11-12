# Bluetooth audio receiver (A2DP sink) named settings.deviceName + " BT" (the
# suffix keeps it apart from the Spotify Connect device of the same name in the
# Spotify app). Pairing is
# open (nobody around the house); paired devices are remembered, one stays
# connected at a time (the arbiter disconnects the others).
{
  config,
  lib,
  pkgs,
  settings,
  ...
}:
{
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
    settings = {
      General = {
        Name = "${settings.deviceName} BT";
        # Audio / loudspeaker device class.
        Class = "0x240414";
        DiscoverableTimeout = 0;
        PairableTimeout = 0;
        JustWorksRepairing = "always";
      };
      Policy.AutoEnable = true;
    };
  };

  # Accept pairing without a PIN, and trust the device (BlueZ otherwise asks
  # for an agent). Then stay discoverable and pairable.
  systemd.services.bluetooth-agent = {
    description = "Bluetooth pairing agent (no PIN) and discoverable adapter";
    wantedBy = [ "multi-user.target" ];
    after = [ "bluetooth.service" ];
    requires = [ "bluetooth.service" ];
    path = [ pkgs.bluez ];
    serviceConfig = {
      ExecStartPre = "${pkgs.bash}/bin/bash -c 'for i in $(seq 1 20); do bluetoothctl show >/dev/null 2>&1 && exit 0; sleep 1; done; exit 1'";
      ExecStart = "${pkgs.bluez-tools}/bin/bt-agent -c NoInputNoOutput";
      ExecStartPost = "${pkgs.bash}/bin/bash -c 'bluetoothctl system-alias \"${settings.deviceName} BT\"; bluetoothctl pairable on; bluetoothctl discoverable on'";
      Restart = "always";
      RestartSec = 5;
    };
  };

  # Only the A2DP sink profile (no headset/hands-free), through WirePlumber.
  services.pipewire.wireplumber.extraConfig."51-bluez" = {
    "monitor.bluez.properties" = {
      "bluez5.roles" = [ "a2dp_sink" ];
      "bluez5.enable-sbc-xq" = true;
      "bluez5.auto-connect" = [ "a2dp_sink" ];
    };
  };
  # System-wide PipeWire runs as the pipewire user, which must reach BlueZ.
  users.users.pipewire.extraGroups = [ "bluetooth" ];
}
