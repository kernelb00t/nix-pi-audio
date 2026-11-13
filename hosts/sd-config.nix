# Reads /boot/firmware/soloist.env (FAT partition, editable from any computer)
# at boot and turns it into the Wi-Fi config and secret files under
# /run/soloist-secrets. The file is parsed, never sourced: it may contain any
# character and must not be able to run code.
{
  config,
  lib,
  pkgs,
  settings,
  ...
}:
let
  envFile = "/boot/firmware/soloist.env";
  secretsDir = "/run/soloist-secrets";
  wifiConf = "/etc/wpa_supplicant/imperative.conf";

  # Dynamically generate the environment template based on the host configuration.
  # Modules not enabled for this device (e.g. Onkyo on non-TV devices) are omitted.
  soloistEnvTemplate = pkgs.writeText "soloist.env.template" (
    ''
      # ==============================================================================
      # Configuration for ${settings.deviceName} (${settings.hostName})
      # ==============================================================================
      # This file is read on every boot from the FAT firmware partition (/boot/firmware).
      # Format: KEY=value, one per line. Quotes around values are optional.

      # Wi-Fi network. Leave WIFI_SSID empty to use Ethernet only.
      # Leave WIFI_PASSWORD empty for an open network.
      WIFI_SSID=
      WIFI_PASSWORD=
      WIFI_COUNTRY=FR

      # Spotify Soloist API key (https://developer.spotify.com/dashboard/soloist).
      SOLOIST_API_KEY=

      # Tailscale auth key, used only for the first login (or after a logout).
      TAILSCALE_AUTHKEY=

      # Optional: address of the Shelly plug that powers the speakers (IP address or
      # host name). The Pi switches it on when a source plays and off after
      # 20 seconds of silence. Leave empty if there is no plug.
      SHELLY_HOST=

      # Optional: Discord webhook (https://discord.com/api/webhooks/...) where the Pi
      # reports a failed automatic update, or a reboot to do. Leave empty for no notification.
      DISCORD_WEBHOOK=
    ''
    + lib.optionalString (settings.onkyo.enable or false) ''

      # Optional: Onkyo AV receiver address for devices controlling an Onkyo receiver
      # over eISCP. The Pi turns on the receiver, sets the input and manages the volume.
      # - Leave empty (default): auto-discover the Onkyo receiver on the local network via UDP.
      # - IP address or host name (e.g. 192.168.0.208): connect directly to this receiver.
      # - "false": disable the Onkyo receiver integration.
      ONKYO_HOST=
    ''
  );

  # Python tool to merge the current generation template with existing user values.
  # Preserves existing configuration while adding new template keys/comments.
  updateSoloistEnv = pkgs.writeShellApplication {
    name = "update-soloist-env";
    runtimeInputs = with pkgs; [
      coreutils
      python3
    ];
    text = ''
      TEMPLATE="''${1:-${soloistEnvTemplate}}"
      TARGET="''${2:-${envFile}}"

      if [ ! -f "$TEMPLATE" ]; then
        echo "Template $TEMPLATE not found" >&2
        exit 1
      fi

      TARGET_DIR=$(dirname "$TARGET")
      if [ ! -d "$TARGET_DIR" ]; then
        exit 0
      fi

      python3 - "$TEMPLATE" "$TARGET" << 'EOF'
import os
import re
import sys

template_path = sys.argv[1]
target_path = sys.argv[2]

if not os.path.exists(target_path):
    with open(template_path, "r", encoding="utf-8") as f_in, open(target_path, "w", encoding="utf-8") as f_out:
        f_out.write(f_in.read())
    sys.exit(0)

# Parse existing target file
old_values = {}
with open(target_path, "r", encoding="utf-8", errors="replace") as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        m = re.match(r"^([A-Z_]+)\s*=\s*(.*)$", line)
        if m:
            key = m.group(1)
            raw_val = m.group(2).strip()
            old_values[key] = raw_val

# Read template and fill with old values
out_lines = []
seen_keys = set()
with open(template_path, "r", encoding="utf-8") as f:
    for line in f:
        m = re.match(r"^([A-Z_]+)\s*=(.*)$", line)
        if m:
            key = m.group(1)
            seen_keys.add(key)
            if key in old_values:
                out_lines.append(f"{key}={old_values[key]}\n")
            else:
                out_lines.append(line)
        else:
            out_lines.append(line)

# Preserve any custom / extra keys from the old file
extra_keys = [k for k in old_values if k not in seen_keys]
if extra_keys:
    out_lines.append("\n# Preserved custom / legacy settings:\n")
    for k in extra_keys:
        out_lines.append(f"{k}={old_values[k]}\n")

# Atomic write with fallback for FAT32 filesystems
tmp_path = target_path + ".tmp"
try:
    with open(tmp_path, "w", encoding="utf-8") as f:
        f.writelines(out_lines)
    os.replace(tmp_path, target_path)
except OSError:
    with open(target_path, "w", encoding="utf-8") as f:
        f.writelines(out_lines)
    try:
        os.remove(tmp_path)
    except OSError:
        pass
EOF
    '';
  };

  soloistConfig = pkgs.writeShellApplication {
    name = "soloist-config";
    runtimeInputs = with pkgs; [
      coreutils
      gnugrep
      updateSoloistEnv
    ];
    text = ''
      # Keep soloist.env up-to-date with this generation's template.
      if [ -d "/boot/firmware" ]; then
        ${lib.getExe updateSoloistEnv} "${soloistEnvTemplate}" "${envFile}"
      fi

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

  # Live updates (nixos-rebuild switch / nixos-upgrade.service) update soloist.env.
  system.activationScripts.updateSoloistEnv = {
    deps = [ ];
    text = ''
      if grep -qs " /boot/firmware " /proc/mounts; then
        ${lib.getExe updateSoloistEnv} "${soloistEnvTemplate}" "${envFile}"
      fi
    '';
  };

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

  # Place the host-specific soloist.env directly on the firmware partition of the SD image.
  sdImage.populateFirmwareCommands = lib.mkForce (
    lib.mkAfter ''
      cp ${soloistEnvTemplate} firmware/soloist.env
    ''
  );
}
