# Raspberry Pi 4 running Spotify Soloist (Spotify Connect speaker).
# See README.md.
{
  config,
  lib,
  pkgs,
  modulesPath,
  nixpkgs,
  nixos-hardware,
  nixpkgs-kernel,
  nixos-hardware-kernel,
  settings,
  ...
}:
let
  amp2 = settings.audioOutput == "hifiberry-amp2";
in
{
  imports = [
    nixos-hardware.nixosModules.raspberry-pi-4
    "${modulesPath}/installer/sd-card/sd-image.nix"
    ./sd-config.nix
    ./autoupgrade.nix
    ./soloist.nix
    ./airplay.nix
    ./bluetooth.nix
    ./arbiter.nix
    ./equalizer.nix
  ];

  assertions = [
    {
      assertion = lib.elem settings.audioOutput [
        "jack"
        "hifiberry-amp2"
      ];
      message = "settings.nix: audioOutput must be \"jack\" or \"hifiberry-amp2\".";
    }
  ];

  nixpkgs.hostPlatform = "aarch64-linux";
  system.stateVersion = "26.05";

  # Kernel: the nixos-hardware Raspberry Pi kernel (it is in no binary cache),
  # cross-compiled from x86_64 if requested. It only depends on the
  # nixpkgs-kernel and nixos-hardware-kernel pins (flake.lock), bumped weekly by
  # the "kernel" workflow, and is built by the "ci" workflow, which pushes it to
  # the Cachix cache (autoupgrade.nix): the Pis and the image workflow download
  # it.
  # autoModules = false: bcm2711_defconfig plus the NixOS options, instead of
  # turning every driver of the tree into a module (aarch64 default). Several
  # times less to compile; enough for a Pi that only plays audio.
  boot.kernelPackages =
    let
      kpkgs =
        if settings.crossCompileKernel then
          import nixpkgs-kernel {
            localSystem = "x86_64-linux";
            crossSystem = "aarch64-linux";
          }
        else
          pkgs;
    in
    kpkgs.linuxPackagesFor (
      kpkgs.callPackage "${nixos-hardware-kernel}/raspberry-pi/common/kernel.nix" {
        rpiVersion = 4;
        autoModules = false;
      }
    );
  # sd-image.nix enables enableAllHardware, whose initrd modules (sunxi,
  # rockchip...) do not exist in the Raspberry Pi kernel.
  hardware.enableAllHardware = lib.mkForce false;
  # Same for the generic PC defaults (ahci, sata_*, ...): keep only what this
  # board boots from, plus the nixos-hardware modules.
  boot.initrd.includeDefaultModules = false;
  boot.initrd.availableKernelModules = [
    "mmc_block"
    "ext4"
  ];

  # Boot: Pi firmware -> U-Boot -> extlinux.conf (NixOS generations).
  # The firmware partition is rewritten on every switch (config.txt, overlays).
  hardware.raspberry-pi.firmware = {
    enable = true;
    uboot.enable = true;
  };
  boot.loader.generic-extlinux-compatible.configurationLimit = 5;

  image.baseName = settings.hostName;
  sdImage = {
    firmwareSize = 256;
    populateRootCommands = ''
      mkdir -p ./files/boot
      ${config.boot.loader.generic-extlinux-compatible.populateCmd} -c ${config.system.build.toplevel} -d ./files/boot
    '';
  };

  # Audio output, through config.txt (applied by the firmware).
  hardware.raspberry-pi.configtxt = {
    settings.all = lib.mkIf amp2 {
      # Onboard audio off; the HAT EEPROM must not load its own overlay.
      dtparam = [ "audio=off" ];
      force_eeprom_read = 0;
    };
    deviceTreeOverlays.all = [
      # No HDMI audio: a single output, so it is the default one.
      { vc4-kms-v3d.noaudio = true; }
    ]
    # HiFiBerry Amp2 on kernels >= 6.1.77 (HiFiBerry documentation).
    ++ lib.optional amp2 { hifiberry-dacplus-std = { }; };
  };

  # Amp2: the onboard headphones card (snd_bcm2835) still shows up although
  # audio is off in config.txt, and PipeWire picked it as the default output.
  boot.blacklistedKernelModules = lib.optional amp2 "snd_bcm2835";

  # PipeWire, system-wide: Soloist runs as a system user.
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    systemWide = true;
    alsa.enable = true;
    pulse.enable = false;
    wireplumber.enable = true;
    wireplumber.extraConfig."50-soloist"."monitor.alsa.rules" = [
      {
        matches = [ { "node.name" = "~alsa_output.*"; } ];
        actions.update-props = {
          # Keep the output open: avoids clicks from the amplifier and
          # the start of tracks being cut.
          "session.suspend-timeout-seconds" = 0;
        };
      }
    ];
  };

  # Network: Wi-Fi from soloist.env (sd-config.nix), Ethernet by DHCP.
  networking.hostName = settings.hostName;
  networking.useDHCP = true;
  # Spotify Connect discovery (mDNS + a local HTTP port that Soloist does not
  # document) must be reachable from the LAN.
  networking.firewall.trustedInterfaces = [
    "end0"
    "wlan0"
  ];

  # Remote admin: Tailscale SSH only (no OpenSSH, no password).
  services.tailscale = {
    enable = true;
    extraUpFlags = [
      "--ssh"
      "--hostname=${settings.hostName}"
    ];
  };
  users.users.admin = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
  };
  security.sudo.wheelNeedsPassword = false;

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    trusted-users = [ "@wheel" ];
  };
  # No automatic garbage collection nor store optimisation: both rewrite the
  # store on the SD card. Updates are built on the admin machine; clean by hand
  # (nix-collect-garbage --delete-older-than 14d) if the card fills up.

  # Fewer writes to the SD card. Logs and /tmp live in RAM (journalctl is lost
  # at reboot: read it before rebooting to debug), the root filesystem is not
  # touched on every file read and flushes in batches every 60 s.
  services.journald.settings.Journal = {
    Storage = "volatile";
    RuntimeMaxUse = "50M";
  };
  boot.tmp.useTmpfs = true;
  systemd.coredump.enable = false;
  fileSystems."/".options = [
    "noatime"
    "commit=60"
  ];
  boot.kernel.sysctl = {
    "vm.dirty_writeback_centisecs" = 6000;
    "vm.dirty_expire_centisecs" = 6000;
  };
  documentation.enable = false;

  time.timeZone = "Europe/Paris";
  i18n.defaultLocale = "fr_FR.UTF-8";
  console.keyMap = "fr";
}
