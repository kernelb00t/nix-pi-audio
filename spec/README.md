# Spécifications du Projet `nix-pi-audio`

> **Principe fondamental :** Ce dossier constitue la **Source Unique de Vérité** (*Single Source of Truth*) du projet. Le code source et les modules NixOS ne sont que la matérialisation de ces spécifications. Tout contributeur humain ou agent d'intelligence artificielle doit se référer à ces fiches avant d'apporter des modifications architecturales ou fonctionnelles.

---

## 📑 Sommaire des Fiches de Spécification

| N° | Fiche | Description |
|:---|:---|:---|
| **01** | [`01-architecture-and-pipeline.md`](01-architecture-and-pipeline.md) | Pile audio logicielle, PipeWire système, WirePlumber, égaliseur paramétrique DSP. |
| **02** | [`02-audio-sources-and-arbitration.md`](02-audio-sources-and-arbitration.md) | Sources (Spotify Soloist, AirPlay 2, Bluetooth) et arbitre audio intelligent (`arbiter.py`). |
| **03** | [`03-hardware-and-devices.md`](03-hardware-and-devices.md) | Matériel Raspberry Pi 4, cartes son (Jack, Amp2, Digi), LEDs indicatrices, profils d'hôtes. |
| **04** | [`04-onkyo-receiver-bridge.md`](04-onkyo-receiver-bridge.md) | Protocole eISCP, pont Onkyo (auto-découverte UDP, allumage, rampe subwoofer, volume, veille). |
| **05** | [`05-bootstrap-configuration-and-secrets.md`](05-bootstrap-configuration-and-secrets.md) | Fichier `soloist.env`, secrets en RAM, Wi-Fi wpa_supplicant, protection de la carte SD. |
| **06** | [`06-ci-cd-and-upgrade-lifecycle.md`](06-ci-cd-and-upgrade-lifecycle.md) | Pipeline CI/CD, cross-compilation noyau, cache Cachix, autoupgrade nocturne et Renovate. |

---

## 🎯 Objectifs et Philosophie du Système

1. **Expérience Audiophile Headless « Zéro Friction » :**
   Le système fonctionne sans écran, sans clavier et sans application propriétaire dédiée. Tout se contrôle depuis les applications natives des utilisateurs (Spotify Connect, AirPlay 2 iOS/macOS, Bluetooth Android/Windows).

2. **Résolution Automatique des Conflits (« Dernier Arrivé Gagne ») :**
   Une seule source audio peut jouer à la fois. Lorsqu'un utilisateur lance un morceau sur une autre source, la source précédente est déconnectée proprement (pas simplement mise en pause) pour libérer la carte son et signaler à l'application cliente qu'elle n'a plus la main.

3. **Protection Matérielle et Pérennité :**
   - **Protection de la carte SD :** Aucun log ni cache n'est écrit sur le support flash en fonctionnement normal (journald volatile en RAM, tmpfs pour `/tmp` et le cache Soloist, `noatime`, commit par lots toutes les 60 secondes).
   - **Protection des enceintes / subwoofers :** Rampes de volume progressives à la mise sous tension de l'amplificateur Onkyo pour éviter les chocs acoustiques et la saturation de l'étage de grave.
   - **Indication visuelle claire :** Les LEDs de statut intégrées du Pi restent allumées au démarrage tant que l'ensemble des démons audio ne sont pas sains et prêts.

4. **Automatisation Totale du Cycle de Vie :**
   - Les Pi ne compilent **aucun paquet** localement.
   - Le noyau est cross-compilé en x86_64 sur GitHub Actions en 3 minutes.
   - Les mises à jour sont validées en CI sur `main`, promues sur `prod`, puis déployées automatiquement la nuit sans coupure.

---

## 📖 Glossaire & Abréviations

- **A2DP :** *Advanced Audio Distribution Profile* (profil audio stéréo Bluetooth).
- **ALSA :** *Advanced Linux Sound Architecture* (pilotes et sous-système audio noyau Linux).
- **Arbiter :** Démon Python (`audio-arbiter.service`) coordonnant l'arbitrage exclusif entre les flux audio.
- **eISCP :** *Ethernet Interactive Serial Control Protocol* (protocole réseau Onkyo/Pioneer sur les ports TCP/UDP 60128).
- **HAT :** *Hardware Attached on Top* (carte fille d'extension pour Raspberry Pi, ex: HiFiBerry).
- **nqptp :** *Not Quite PTP* (démon de synchronisation d'horloge réseau pour AirPlay 2).
- **PEQ :** *Parametric Equalizer* (égaliseur paramétrique DSP à base de biquads PipeWire).
- **Soloist :** Démon officiel et propriétaire Spotify Connect pour Linux embarqué.
- **S/PDIF :** *Sony/Philips Digital Interface* (sortie audio numérique optique/coaxiale).
