{
  description = "NixOS images for Raspberry Pi 4 audio receivers (Spotify Soloist, AirPlay 2, Bluetooth)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-hardware.url = "github:NixOS/nixos-hardware";
    nixos-hardware.inputs.nixpkgs.follows = "nixpkgs";

    # Raspberry Pi kernel of hosts/: its own pins, bumped only by the
    # "kernel" workflow (not by Renovate), so that changing the rest
    # of the configuration or updating nixpkgs never rebuilds the kernel.
    nixpkgs-kernel.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-hardware-kernel.url = "github:NixOS/nixos-hardware";
    nixos-hardware-kernel.inputs.nixpkgs.follows = "nixpkgs-kernel";
  };

  outputs = {
    self,
    nixpkgs,
    nixos-hardware,
    nixpkgs-kernel,
    nixos-hardware-kernel,
  }: let
    # One NixOS configuration per Soloist Pi: defaults in settings.nix,
    # overridden by hosts/devices/<name>.nix.
    soloistDevices = ["chambre-de-leo" "chambre-de-sarah"];
    soloistPi = device:
      nixpkgs.lib.nixosSystem {
        specialArgs = {
          inherit nixpkgs nixos-hardware nixpkgs-kernel nixos-hardware-kernel;
          settings = (import ./hosts/settings.nix) // (import (./hosts/devices + "/${device}.nix"));
        };
        modules = [./hosts];
      };
    soloistSystems = nixpkgs.lib.genAttrs soloistDevices soloistPi;
    soloistImages = system:
      nixpkgs.lib.mapAttrs' (name: cfg: nixpkgs.lib.nameValuePair "${name}-image" cfg.config.system.build.sdImage) soloistSystems;
  in {
    nixosConfigurations = soloistSystems;

    # SD card images: nix build .#chambre-de-leo-image (or chambre-de-sarah-image)
    packages.x86_64-linux = soloistImages "x86_64-linux";
    packages.aarch64-linux = soloistImages "aarch64-linux";
  };
}
