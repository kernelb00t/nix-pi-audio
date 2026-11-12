# Spotify Soloist (official headless Spotify Connect client) as a system service,
# plus a daily job that keeps the binary up to date.
#
# Spotify forbids redistributing the binary and publishes it at an unversioned
# URL without checksums, so it cannot be a Nix package: the Pi downloads it
# itself into /var/lib/soloist-bin. Builds expire 90 days after their build date
# (exit code 10), hence the updater.
{
  config,
  lib,
  pkgs,
  settings,
  ...
}:
let
  url = "https://soloist-builds.spotifycdn.com/soloist_release_arm64.tar.gz";
  binDir = "/var/lib/soloist-bin";
  bin = "${binDir}/soloist";
  apiKey = "/run/soloist-secrets/soloist-api-key";

  # The binary is linked against a standard glibc loader path; nix-ld provides
  # it. libpipewire and libpulse are loaded at runtime.
  runtimeEnv = {
    NIX_LD = "/run/current-system/sw/share/nix-ld/lib/ld.so";
    NIX_LD_LIBRARY_PATH = "/run/current-system/sw/share/nix-ld/lib";
  };

  start = pkgs.writeShellScript "soloist-start" ''
    # Cache size from the RAM of this Pi: cacheFillPercent of the tmpfs, which is
    # cacheRamPercent of the RAM. Soloist needs at least 100 MB.
    mem_kb=$(${pkgs.gawk}/bin/awk '/^MemTotal:/ {print $2}' /proc/meminfo)
    cache_mb=$(( mem_kb * ${toString settings.cacheRamPercent} * ${toString settings.cacheFillPercent} / 10000 / 1024 ))
    [ "$cache_mb" -ge 100 ] || cache_mb=100
    exec ${bin} \
      --device-name ${lib.escapeShellArg settings.deviceName} \
      --api-key "$(< "$CREDENTIALS_DIRECTORY/api-key")" \
      --ws 127.0.0.1:${toString settings.soloistWsPort} \
      --data-dir "$STATE_DIRECTORY" \
      --cache-dir "$CACHE_DIRECTORY" \
      --cache-size "$cache_mb"
  '';

  update = pkgs.writeShellApplication {
    name = "soloist-update";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      diffutils
      gnutar
      gzip
      systemd
      util-linux
    ];
    text = ''
      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT
      chmod 0755 "$work"

      curl --fail --silent --show-error --location \
        --retry 5 --retry-all-errors --max-time 900 \
        --output "$work/soloist.tar.gz" ${url}
      tar -xzf "$work/soloist.tar.gz" -C "$work" soloist
      chmod 0755 "$work/soloist"

      if [ -e ${bin} ] && cmp -s "$work/soloist" ${bin}; then
        echo "Soloist already up to date"
        exit 0
      fi

      # Never replace a working binary with one that does not even run
      # (download problem, or a build that is already expired).
      if ! version=$(runuser -u soloist -- "$work/soloist" --version 2>&1); then
        echo "New build fails 'soloist --version', keeping the current one:" >&2
        echo "$version" >&2
        exit 1
      fi

      install -m 0755 "$work/soloist" ${bin}.new
      mv -f ${bin}.new ${bin}
      echo "Soloist updated:"
      echo "$version"
      systemctl restart soloist.service
    '';
  };
in
{
  programs.nix-ld = {
    enable = true;
    libraries = with pkgs; [
      stdenv.cc.cc.lib # libgcc_s, libatomic
      pipewire
      libpulseaudio
    ];
  };

  users.users.soloist = {
    isSystemUser = true;
    group = "soloist";
    extraGroups = [
      "pipewire"
      "audio"
    ];
  };
  users.groups.soloist = { };

  # The playback cache is in RAM: no writes to the SD card, emptied at reboot.
  fileSystems."/var/cache/soloist" = {
    device = "tmpfs";
    fsType = "tmpfs";
    options = [
      "size=${toString settings.cacheRamPercent}%"
      "mode=0755"
      "noatime"
    ];
  };

  systemd.services.soloist = {
    description = "Spotify Soloist (Spotify Connect device)";
    wantedBy = [ "multi-user.target" ];
    wants = [
      "network-online.target"
      "time-sync.target"
      "soloist-config.service"
      "pipewire.service"
      "wireplumber.service"
    ];
    after = [
      "network-online.target"
      "time-sync.target"
      "soloist-config.service"
      "pipewire.service"
      "wireplumber.service"
    ];
    # On first boot the binary is not there yet: soloist-update installs it,
    # then starts this unit.
    unitConfig.ConditionPathExists = bin;
    unitConfig.ConditionFileNotEmpty = apiKey;
    environment = runtimeEnv // {
      PIPEWIRE_RUNTIME_DIR = "/run/pipewire";
      PIPEWIRE_CONFIG_DIR = "${pkgs.pipewire}/share/pipewire";
    };
    serviceConfig = {
      ExecStart = start;
      User = "soloist";
      Group = "soloist";
      LoadCredential = "api-key:${apiKey}";
      StateDirectory = "soloist";
      CacheDirectory = "soloist";
      Restart = "on-failure";
      RestartSec = 10;
      # 10 = expired build: restarting is useless until soloist-update runs.
      RestartPreventExitStatus = 10;

      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
    };
  };
  systemd.services.soloist-update = {
    description = "Download the latest Spotify Soloist build";
    wants = [
      "network-online.target"
      "time-sync.target"
    ];
    after = [
      "network-online.target"
      "time-sync.target"
    ];
    environment = runtimeEnv;
    # Retry a failed update (slow network, CDN) a few times, then wait for the
    # next timer run.
    startLimitIntervalSec = 7200;
    startLimitBurst = 6;
    serviceConfig = {
      Type = "oneshot";
      Restart = "on-failure";
      RestartSec = "10min";
      ExecStart = lib.getExe update;
      StateDirectory = "soloist-bin";
      StateDirectoryMode = "0755";
      PrivateTmp = true;
    };
  };

  # Daily update, at a random time between 04:00 and 04:30.
  systemd.timers.soloist-update = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 04:00:00";
      RandomizedDelaySec = "30min";
      Persistent = true;
    };
  };
  # Plus one run shortly after boot (first install, Pi left off for a while),
  # without the random delay.
  systemd.timers.soloist-update-boot = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      Unit = "soloist-update.service";
    };
  };

  # No RTC on the Pi: wait for NTP before TLS and the build expiry check.
  systemd.additionalUpstreamSystemUnits = [ "systemd-time-wait-sync.service" ];
  systemd.services.systemd-time-wait-sync = {
    wantedBy = [ "time-sync.target" ];
    # Upstream waits forever; without NTP, give up after 5 min and let Soloist
    # try anyway (it logs the problem).
    serviceConfig.TimeoutStartSec = "5min";
  };
}
