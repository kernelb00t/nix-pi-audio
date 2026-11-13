# Updates from the "prod" branch of the repository (moved by the ci workflow only
# when everything builds); the kernel and the rest come from the Cachix cache.
#  - pi-update: command to run over SSH, updates this Pi now.
#  - nightly automatic update: off by default (settings.autoUpgrade).
# Failures and pending reboots are reported on Discord if DISCORD_WEBHOOK is set
# in soloist.env (see sd-config.nix). See README.md.
{
  config,
  lib,
  pkgs,
  settings,
  ...
}:
let
  webhookFile = "/run/soloist-secrets/discord-webhook";
  notifiedFile = "/run/autoupgrade-reboot-notified";

  # notify-discord <message>: posts to the webhook, if configured. The URL is
  # a secret: it is read from the file, given to curl through a config file
  # descriptor (not on the command line) and redacted from any error output.
  notify = pkgs.writeShellApplication {
    name = "notify-discord";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      jq
    ];
    text = ''
      [ -s ${webhookFile} ] || exit 0
      url=$(cat ${webhookFile})
      if [[ ! "$url" =~ ^https://discord\.com/api/webhooks/[0-9]+/[A-Za-z0-9_-]+$ ]]; then
        echo "Discord webhook file invalid: no notification" >&2
        exit 0
      fi
      msg="[${settings.hostName}] $1"
      payload=$(jq -cn --arg c "''${msg:0:1900}" '{content: $c, allowed_mentions: {parse: []}}')
      if ! out=$(curl --silent --show-error --fail --max-time 20 \
        -H 'Content-Type: application/json' --data-binary "$payload" \
        --config <(printf 'url = "%s"\n' "$url") 2>&1); then
        echo "Discord notification failed: ''${out//"$url"/<webhook>}" >&2
      fi
    '';
  };

  notifyFailure = pkgs.writeShellScript "autoupgrade-notify-failure" ''
    tail=$(${pkgs.systemd}/bin/journalctl -u nixos-upgrade.service -n 6 --no-pager -o cat 2>/dev/null | tail -c 900)
    ${lib.getExe notify} "Automatic update failed. Last log lines:
$tail"
  '';

  # Kernel, initrd, kernel modules or firmware differ from the running system:
  # a reboot is needed to use the new generation.
  rebootCheck = pkgs.writeShellScript "autoupgrade-reboot-check" ''
    for f in kernel initrd kernel-modules firmware; do
      booted=$(${pkgs.coreutils}/bin/readlink -f /run/booted-system/$f || true)
      current=$(${pkgs.coreutils}/bin/readlink -f /run/current-system/$f || true)
      if [ "$booted" != "$current" ]; then
        current_system=$(${pkgs.coreutils}/bin/readlink -f /run/current-system)
        # One message per generation (the marker is in /run: gone at reboot).
        if [ "$(cat ${notifiedFile} 2>/dev/null || true)" != "$current_system" ]; then
          ${lib.getExe notify} "Update applied, but the kernel or firmware changed: reboot the Pi to use it." \
            && echo "$current_system" > ${notifiedFile}
        fi
        exit 0
      fi
    done
    rm -f ${notifiedFile}
  '';
  # pi-update [branch]: switch this Pi to the latest version of the branch
  # (default: prod). To run over SSH as the admin user.
  piUpdate = pkgs.writeShellApplication {
    name = "pi-update";
    runtimeInputs = with pkgs; [
      coreutils
      nixos-rebuild
      sudo
    ];
    text = ''
      branch="''${1:-prod}"
      echo "Updating ${settings.hostName} from branch $branch..."
      sudo nixos-rebuild switch --refresh \
        --flake "github:kernelb00t/nix-pi-audio/$branch#${settings.hostName}"
      for f in kernel initrd kernel-modules firmware; do
        if [ "$(readlink -f /run/booted-system/$f || true)" != "$(readlink -f /run/current-system/$f || true)" ]; then
          echo
          echo "The kernel or firmware changed: reboot the Pi to use it (sudo reboot)."
          exit 0
        fi
      done
      echo "Done. No reboot needed."
    '';
  };
in
{
  environment.systemPackages = [ piUpdate ];

  system.autoUpgrade = {
    enable = settings.autoUpgrade;
    flake = "github:kernelb00t/nix-pi-audio/prod#${settings.hostName}";
    operation = "switch";
    dates = "04:30";
    randomizedDelaySec = "20min";
    allowReboot = settings.autoUpgradeReboot;
    rebootWindow = lib.mkIf settings.autoUpgradeReboot {
      lower = "04:00";
      upper = "05:30";
    };
  };

  # Kernel and AirPlay 2 build come from the Cachix cache (public, read-only
  # on the Pi): nothing is compiled on the Pi.
  nix.settings = {
    substituters = [ "https://kernelb00t.cachix.org" ];
    trusted-public-keys = [ "kernelb00t.cachix.org-1:8IJNajMb8SDKZVtPIfDZrbm8XPAEmOmZANZ8E+Ps6V0=" ];
  };

  systemd.services.nixos-upgrade = lib.mkIf settings.autoUpgrade {
    onFailure = [ "nixos-upgrade-notify-failure.service" ];
    # Only runs after a successful update ("-": never makes the update fail).
    serviceConfig.ExecStartPost = lib.mkIf (!settings.autoUpgradeReboot) [ "-${rebootCheck}" ];
  };

  systemd.services.nixos-upgrade-notify-failure = {
    description = "Report a failed automatic update on Discord";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = notifyFailure;
    };
  };
}
