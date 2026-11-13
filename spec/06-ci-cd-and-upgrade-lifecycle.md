# Specification 06: CI/CD, Binary Caching & Upgrade Lifecycle

## 1. Two-Tier Flake Architecture (`flake.nix`)

The repository isolates flake inputs into two distinct tiers:

1. **Tier 1: Userspace System Inputs (`nixpkgs`, `nixos-hardware`)**
   - Supplies the entire userspace package set (PipeWire, BlueZ, Soloist, systemd, etc.).
   - Updated continuously by **Renovate** via Pull Requests with automatic merge (`automerge: true`).
2. **Tier 2: Linux Kernel Inputs (`nixpkgs-kernel`, `nixos-hardware-kernel`)**
   - Locks the exact Raspberry Pi kernel derivation.
   - Decoupled from userspace `nixpkgs` updates so software bumps do not force kernel rebuilds.
   - Updated exclusively by [`.github/workflows/kernel.yml`](../.github/workflows/kernel.yml) weekly on Sundays at 03:00 UTC.

---

## 2. Continuous Integration Pipeline (CI/CD)

```mermaid
flowchart TD
    PR["Push or PR on main"] --> CI["Workflow ci.yml (ubuntu-latest x86_64)"]
    
    subgraph Build["Build & Cross-Compilation Stage"]
        K_CHECK{"Has the kernel changed?"}
        K_CHECK -->|"Yes"| K_BUILD["Cross-compile kernel (x86_64 -> aarch64, ~3min)"]
        K_CHECK -->|"No"| K_CACHE["Fetch kernel from Cachix cache"]
        
        K_BUILD --> SYS_BUILD["Build toplevels (chambre-de-leo, chambre-de-sarah, television)"]
        K_CACHE --> SYS_BUILD
        
        SYS_BUILD --> CACHIX["Push paths to Cachix (kernelb00t.cachix.org)"]
    end
    
    CI --> Build
    CACHIX --> TEST["nix flake check --no-build"]
    
    TEST --> PROMOTE{"Branch == main ?"}
    PROMOTE -->|"Yes"| FF_PROD["Fast-forward prod branch (git push origin SHA:prod)"]
    PROMOTE -->|"No"| FINISH["PR checks pass"]
```

---

## 3. Public Binary Cache (Cachix)

- **Cache Name:** `kernelb00t` (`https://kernelb00t.cachix.org`)
- **Public Key:** `kernelb00t.cachix.org-1:8IJNajMb8SDKZVtPIfDZrbm8XPAEmOmZANZ8E+Ps6V0=`
- **Function:** Stores the cross-compiled kernel, AirPlay 2 packages, and complete system closures.
- **Guarantee:** Edge devices download pre-built binaries and never compile code locally.

---

## 4. Device Deployment & Auto-Upgrade (`autoupgrade.nix`)

Raspberry Pis update autonomously without operator intervention:

### 4.1 Nightly Upgrade Service (`nixos-upgrade.service`)
- **Tracked Branch:** `github:kernelb00t/nix-pi-audio/prod#<hostName>`
- **Execution Schedule:** Daily at **04:30** (`randomizedDelaySec = 20min` to prevent network spikes).
- **In-Place Activation:** `operation = "switch"`.
- **Reboot Policy:** `autoUpgradeReboot = false`. Userspace software updates activate seamlessly without rebooting the player.

### 4.2 Hardware/Kernel Change Detection
After a successful upgrade, a verification script checks:
- `/run/booted-system/kernel` vs `/run/current-system/kernel`
- `/run/booted-system/initrd` vs `/run/current-system/initrd`
- `/run/booted-system/kernel-modules` vs `/run/current-system/kernel-modules`
- `/run/booted-system/firmware` vs `/run/current-system/firmware`

If any of these paths changed, a Discord alert is dispatched (if `DISCORD_WEBHOOK` is configured):  
`"Update applied, but the kernel or firmware changed: reboot the Pi to use it."`

### 4.3 Operator CLI Command (`pi-update`)
Operators connected over SSH can initiate upgrades on demand:
```bash
# Upgrade from the verified production branch:
pi-update

# Or test a development branch (e.g. main):
pi-update main
```
The utility streams progress, switches generation, and alerts the operator if `sudo reboot` is required.
