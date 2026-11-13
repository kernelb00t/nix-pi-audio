# Reads /boot/firmware/soloist.env (FAT partition, editable from any computer)
# at boot and turns it into the Wi-Fi config and secret files under
# /run/soloist-secrets. The file is parsed, never sourced: it may contain any
# character and must not be able to run code.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  envFile = "/boot/firmware/soloist.env";
  secretsDir = "/run/soloist-secrets";
  wifiConf = "/etc/wpa_supplicant/imperative.conf";

  soloistConfig = pkgs.writeShellApplication {
    name = "soloist-config";
    runtimeInputs = with pkgs; [
      coreutils
      gnugrep
    ];
    text = ''
      # Byte-wise checks (wpa_supplicant wants 8 to 63 ASCII bytes).
      export LC_ALL=C
      umask 077
      mkdir -p ${secretsDir}
      chmod 0700 ${secretsDir}
      rm -f ${secretsDir}/*

      declare -A v=()
      if [ -r ${envFile} ]; then
        n=0
        while IFS= read -r line || [ -n "$line" ]; do
          n=$((n + 1))
          line=''${line%$'\r'}
          [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
          if [[ ! "$line" =~ ^[[:space:]]*([A-Z_]+)[[:space:]]*=(.*)$ ]]; then
            echo "soloist.env line $n ignored: not KEY=value" >&2
            continue
          fi
          key=''${BASH_REMATCH[1]}
          val=''${BASH_REMATCH[2]}
          # Trim, then drop one pair of surrounding quotes.
          val=''${val#"''${val%%[![:space:]]*}"}
          val=''${val%"''${val##*[![:space:]]}"}
          if [[ "$val" =~ ^\"(.*)\"$ || "$val" =~ ^\'(.*)\'$ ]]; then
            val=''${BASH_REMATCH[1]}
          fi
          v[$key]=$val
        done < ${envFile}
      else
        echo "${envFile} not found: no Wi-Fi, no Soloist API key, no Tailscale key" >&2
      fi

      # Wi-Fi (wpa_supplicant, imperative config file).
      ssid=''${v[WIFI_SSID]:-}
      pass=''${v[WIFI_PASSWORD]:-}
      country=''${v[WIFI_COUNTRY]:-FR}
      [[ "$country" =~ ^[A-Z]{2}$ ]] || { echo "WIFI_COUNTRY '$country' invalid, using FR" >&2; country=FR; }
      tmp=$(mktemp ${wifiConf}.XXXXXX)
      {
        echo "country=$country"
        if [ -n "$ssid" ]; then
          echo "network={"
          # Hex SSID: no quoting problem whatever the name contains.
          printf '  ssid=%s\n' "$(printf '%s' "$ssid" | od -An -v -tx1 | tr -d ' \n')"
          echo "  scan_ssid=1"
          if [ -z "$pass" ]; then
            echo "  key_mgmt=NONE"
          elif [[ ''${#pass} -ge 8 && ''${#pass} -le 63 && "$pass" =~ ^[[:print:]]+$ ]]; then
            # WPA2 and WPA3 (transition mode).
            echo "  key_mgmt=WPA-PSK WPA-PSK-SHA256 SAE"
            echo "  ieee80211w=1"
            printf '  psk="%s"\n' "$pass"
          else
            echo "WIFI_PASSWORD must be 8 to 63 printable ASCII characters: Wi-Fi not configured" >&2
            echo "  key_mgmt=NONE"
            echo "  disabled=1"
          fi
          echo "}"
        fi
      } > "$tmp"
      chown wpa_supplicant:wpa_supplicant "$tmp"
      mv -f "$tmp" ${wifiConf}
      if [ -n "$ssid" ]; then echo "Wi-Fi network: $ssid"; else echo "No Wi-Fi network configured"; fi

      # Secrets, only written when set (units check that the file is not empty).
      if [ -n "''${v[SOLOIST_API_KEY]:-}" ]; then
        printf '%s' "''${v[SOLOIST_API_KEY]}" > ${secretsDir}/soloist-api-key
      else
        echo "SOLOIST_API_KEY not set: Soloist will not start" >&2
      fi
      if [ -n "''${v[TAILSCALE_AUTHKEY]:-}" ]; then
        printf '%s' "''${v[TAILSCALE_AUTHKEY]}" > ${secretsDir}/tailscale-authkey
      fi
      # Optional: address of the Shelly plug that powers the speakers
      # (read by audio-arbiter). Not a secret, but lives in the same file.
      if [ -n "''${v[SHELLY_HOST]:-}" ]; then
        if [[ "''${v[SHELLY_HOST]}" =~ ^[A-Za-z0-9.-]{1,253}$ ]]; then
          printf '%s' "''${v[SHELLY_HOST]}" > ${secretsDir}/shelly-host
        else
          echo "SHELLY_HOST must be an IP address or host name (letters, digits, . and -): ignored" >&2
        fi
      fi
      # Optional: Discord webhook for the automatic update notifications
      # (autoupgrade.nix). A secret: its value is never printed.
      if [ -n "''${v[DISCORD_WEBHOOK]:-}" ]; then
        if [[ "''${v[DISCORD_WEBHOOK]}" =~ ^https://discord\.com/api/webhooks/[0-9]+/[A-Za-z0-9_-]+$ ]]; then
          printf '%s' "''${v[DISCORD_WEBHOOK]}" > ${secretsDir}/discord-webhook
        else
          echo "DISCORD_WEBHOOK must look like https://discord.com/api/webhooks/<id>/<token>: ignored" >&2
        fi
      fi
      # Optional: Onkyo AV receiver host (onkyo.nix).
      # - "false", "off", "no", "disabled", "0": disables onkyo-bridge
      # - IP address or host: direct connection
      # - empty or unset: auto-discovery
      if [ -n "''${v[ONKYO_HOST]+x}" ]; then
        raw_onkyo="''${v[ONKYO_HOST]}"
        case "$raw_onkyo" in
          false|off|no|disabled|0)
            touch ${secretsDir}/onkyo-disabled
            printf '%s' "false" > ${secretsDir}/onkyo-host
            ;;
          *)
            printf '%s' "$raw_onkyo" > ${secretsDir}/onkyo-host
            ;;
        esac
      fi
    '';
  };
in
{
  # The firmware partition is mounted at boot (the SD image default is noauto),
  # both to read soloist.env and so that nixos-rebuild can update config.txt.
  fileSystems."/boot/firmware".options = lib.mkForce [
    "nofail"
    "fmask=0077"
    "dmask=0077"
  ];

  systemd.services.soloist-config = {
    description = "Read soloist.env from the SD card firmware partition";
    wantedBy = [ "multi-user.target" ];
    before = [
      "wpa_supplicant.service"
      "tailscaled-autoconnect.service"
      "soloist.service"
    ];
    unitConfig.RequiresMountsFor = "/boot/firmware";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = lib.getExe soloistConfig;
    };
  };

  networking.wireless = {
    enable = true;
    # No declarative network: wpa_supplicant uses the imperative file above.
    networks = { };
  };
  systemd.services.wpa_supplicant = {
    wants = [ "soloist-config.service" ];
    after = [ "soloist-config.service" ];
    # The module makes the imperative file group-writable at start; it holds
    # the Wi-Fi password, keep it private.
    serviceConfig.ExecStartPre = lib.mkAfter [ "+${pkgs.coreutils}/bin/chmod 0600 ${wifiConf}" ];
  };

  services.tailscale.authKeyFile = "${secretsDir}/tailscale-authkey";
  systemd.services.tailscaled-autoconnect = {
    wants = [ "soloist-config.service" ];
    after = [ "soloist-config.service" ];
    # Without a key, `tailscale up` would wait forever for an interactive login.
    unitConfig.ConditionFileNotEmpty = "${secretsDir}/tailscale-authkey";
  };

  # Copy the template onto the firmware partition of the image.
  sdImage.populateFirmwareCommands = lib.mkForce (
    lib.mkAfter ''
      cp ${./soloist.env.example} firmware/soloist.env.example
    ''
  );
}
