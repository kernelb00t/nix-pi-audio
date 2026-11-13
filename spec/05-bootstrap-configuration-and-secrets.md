# Spécification 05 : Bootstrap, Configuration & Gestion des Secrets

## 1. Structure du Support de Stockage (Carte SD)

L'image générée (`sdImage`) partitionne la carte SD en deux volumes distincts :

1. **Partition Firmware FAT32 (`/boot/firmware`) :**
   - Taille : **64 Mo** (optimisée pour minimiser l'empreinte disque).
   - Lisible et modifiable nativement sur n'importe quel ordinateur (macOS, Windows, Linux) sans pilote additionnel.
   - Héberge le firmware Broadcom, le noyau Linux, `config.txt`, et le fichier de configuration utilisateur `soloist.env`.
2. **Partition Système Ext4 (`/`) :**
   - Formate le reste de l'espace pour le magasin Nix (`/nix/store`) et le système d'exploitation NixOS.

---

## 2. Contrat de Configuration : `soloist.env`

Le fichier `/boot/firmware/soloist.env` constitue l'interface de paramétrage utilisateur sans écran (*Zero-Touch Configuration*).

### 2.1 Analyseur Sécurisé (`soloist-config.service`)
Le fichier `soloist.env` n'est **jamais sourcé** par un shell pour prévenir toute injection de commande arbitraire :
- Il est analysé ligne par ligne par un script Bash strict (`LC_ALL=C`).
- Format attendu : `CLE=VALEUR` (espaces tolérés, guillemets optionnels mais préservant les espaces internes).
- Les lignes vides ou débutant par `#` sont ignorées.

### 2.2 Répertoire des Secrets en RAM (`/run/soloist-secrets`)
Au boot, `soloist-config.service` extrait les paramètres et les écrit dans un répertoire temporaire en mémoire vive (`tmpfs`) :
- Permissions strictes : `0700` appartenant à `root:root`.
- Fichiers générés :
  - `soloist-api-key` : Clé d'API Spotify Soloist (lue par `soloist.service`).
  - `tailscale-authkey` : Clé d'authentification Tailscale pour le premier enregistrement.
  - `shelly-host` : Adresse IP ou nom de la prise d'alimentation des enceintes.
  - `discord-webhook` : URL du webhook Discord pour les alertes de mise à jour.
  - `onkyo-host` : Adresse IP Onkyo ou instruction `false`.
  - `onkyo-disabled` : Fichier marqueur créé si `ONKYO_HOST=false` pour inhiber le service systemd.

---

## 3. Génération de la Configuration Wi-Fi

`soloist-config.service` génère un fichier de configuration impératif pour `wpa_supplicant` dans `/etc/wpa_supplicant/imperative.conf` :
- **Sécurité SSID :** Le nom du réseau (SSID) est encodé en hexadécimal pur (`od -An -v -tx1`) afin d'éviter tout bogue lié aux caractères spéciaux, espaces ou émoticônes dans le nom de la box.
- **Protocoles supportés :** Transition fluide WPA2-PSK et WPA3-SAE (`ieee80211w=1`).
- **Mode Ethernet :** Si `WIFI_SSID` est laissé vide, le fichier Wi-Fi n'est pas configuré et le système utilise exclusivement l'interface filaire `eth0`.
- **Permissions :** Le fichier est restreint à `chmod 0600` sous la propriété de l'utilisateur système `wpa_supplicant`.

---

## 4. Stratégie de Longévité de la Carte SD (*Flash Wear Prevention*)

Les cartes micro-SD s'usent rapidement lorsqu'elles subissent des écritures aléatoires fréquentes. NixOS est durci pour réduire ces écritures au strict minimum :

1. **Journaux système volatils :**
   ```nix
   services.journald.settings.Journal = {
     Storage = "volatile";
     RuntimeMaxUse = "50M";
   };
   ```
   Les logs système sont stockés en RAM et ne sont jamais écrits sur la carte SD. (En cas de redémarrage, ils sont réinitialisés ; pour déboguer, lire le journal avant de rebooter).
2. **Répertoires temporaires en RAM :**
   `boot.tmp.useTmpfs = true;` monte `/tmp` en mémoire vive.
3. **Cœur du système de fichiers :**
   - Option `noatime` : Empêche la mise à jour de la date de dernier accès lors de la lecture d'un fichier.
   - Option `commit=60` : Regroupe les écritures disque en mémoire tampon et ne les vide sur la carte SD que par lots toutes les 60 secondes.
   - Réglages sysctl `vm.dirty_writeback_centisecs = 6000` et `vm.dirty_expire_centisecs = 6000`.
4. **Pas de Garbage Collector agressif :**
   Aucun nettoyage automatique quotidien du store Nix n'est programmé afin d'éviter les réécritures massives de blocs flash.
