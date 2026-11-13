# Spécification 03 : Matériel, Cartes Son & Profils d'Hôtes

## 1. Plateforme Cible

- **Micro-ordinateur :** Raspberry Pi 4 Model B (Broadcom BCM2711, ARM Cortex-A72 quadri-cœur 1.5 GHz, 2 Go à 8 Go de RAM LPDDR4).
- **Architecture NixOS :** `aarch64-linux`.
- **Amorçage :** Firmware Raspberry Pi -> U-Boot -> Extlinux (`extlinux.conf`).
- **Délai de bootloader :** `boot.loader.timeout = 0;` (démarrage instantané sans attendre les 5 secondes par défaut de Syslinux/Extlinux).

---

## 2. Périphériques Audio & Overlays Matériels

Le paramètre `audioOutput` dans la configuration d'un hôte sélectionne la carte son physique :

| Valeur de `audioOutput` | Périphérique physique | Overlay `config.txt` | Modules noyau blacklistés |
|:---|:---|:---|:---|
| `"jack"` | Sortie analogique 3.5 mm intégrée | Aucun (sortie BCM2835 native) | Aucun |
| `"hifiberry-amp2"` | HAT Amplificateur HiFiBerry Amp2 | `dtoverlay=hifiberry-dacplus-std`<br>`dtparam=audio=off`<br>`force_eeprom_read=0` | `snd_bcm2835` |
| `"hifiberry-digi"` | HAT Sortie Numérique S/PDIF (Optique/Coax) | `dtoverlay=hifiberry-digi`<br>`dtparam=audio=off`<br>`force_eeprom_read=0` | `snd_bcm2835` |

### 2.1 Règles de Configuration Matérielle (`config.txt`)
- Pour toute carte HiFiBerry (`amp2` ou `digi`) :
  1. `dtparam = [ "audio=off" ]` : Désactive le circuit audio analogique interne du SoC BCM2711.
  2. `force_eeprom_read = 0` : Empêche le firmware de charger automatiquement les overlays depuis l'EEPROM physique du HAT (qui entre parfois en conflit avec les versions modernes du noyau Linux >= 6.1).
  3. `vc4-kms-v3d.noaudio = true` : Désactive l'audio HDMI afin de ne laisser subsister qu'une seule et unique interface ALSA de sortie.
  4. Blacklist de `snd_bcm2835` dans le noyau pour garantir qu'aucun périphérique virtuel d'écouteur ne parasite la sélection automatique de PipeWire.

### 2.2 Suppression des Modules Inutiles
Pour réduire la consommation mémoire, accélérer le boot et éliminer les réveils processeur superflus, les modules suivants sont blacklistés :
```text
bcm2835_v4l2, bcm2835_codec, bcm2835_isp, rpi_hevc_dec
```

---

## 3. Protocole des LEDs Indicatrices de Santé (`disable-leds.service`)

Les voyants lumineux intégrés au Raspberry Pi 4 (LED rouge PWR et LED verte ACT) sont utilisés comme **indicateur matériel de réussite du démarrage** :

1. **Phase de démarrage (Boot) :**
   Les deux LEDs restent allumées normalement pour indiquer que le matériel est alimenté et charge le système.
2. **Phase de vérification de santé :**
   Le service systemd `disable-leds.service` s'exécute après `multi-user.target`. Il scrute l'état des services fondamentaux du système :
   - `pipewire.service`
   - `wireplumber.service`
   - `audio-arbiter.service`
   - `shairport-sync.service`
   - `bluetooth.service`
   - `soloist.service` (si une clé API est configurée)
3. **Transition :**
   - Dès que tous les services sont confirmés `active (running)`, le script désactive les triggers matériels des LEDs et bascule leur luminosité à `0` dans `/sys/class/leds/*/brightness`.
   - Si l'un des démons essentiels échoue ou plante, le service échoue et **les LEDs restent allumées**, signalant immédiatement une anomalie sans avoir besoin d'ouvrir une console SSH.

---

## 4. Profils d'Hôtes Actuels

Les hôtes sont définis dans `hosts/devices/<name>.nix` :

### 4.1 Chambre de Léo — [`hosts/devices/chambre-de-leo.nix`](../hosts/devices/chambre-de-leo.nix)
- **Nom d'hôte :** `chambre-de-leo`
- **Nom d'affichage :** `Chambre de Léo`
- **Sortie audio :** `hifiberry-amp2`
- **DSP :** Égaliseur paramétrique actif (courbe Lo Boost Moode Audio : 31 Hz +12.24 dB, 63 Hz +4.32 dB, préamplification -4.80 dB).

### 4.2 Chambre de Sarah — [`hosts/devices/chambre-de-sarah.nix`](../hosts/devices/chambre-de-sarah.nix)
- **Nom d'hôte :** `chambre-de-sarah`
- **Nom d'affichage :** `Chambre de Sarah`
- **Sortie audio :** `jack`
- **DSP :** Désactivé (réponse plate standard).

### 4.3 Télévision — [`hosts/devices/television.nix`](../hosts/devices/television.nix)
- **Nom d'hôte :** `television`
- **Nom d'affichage :** `Télévision`
- **Sortie audio :** `hifiberry-digi` (S/PDIF optique/coaxial vers amplificateur Onkyo).
- **Intégration Amplificateur :** Pont eISCP Onkyo actif (`onkyo.enable = true`).
