# StatsDesk

Widgets système pour le bureau macOS, style cyberpunk, un seul fichier Swift sans dépendance.

- **MEM / CPU / NET** : RAM, CPU, température, total téléchargé, débit
- **BAT / WIFI / USB** : batterie (watts, cycles, santé), Wi-Fi (RSSI, bruit, SNR, débit), périphériques USB et port série
- **DISK / PROC** : espace disque, top 5 des apps (CPU, RAM)

Conçu pour une consommation minimale : un seul timer à 2 s avec tolérance, suspendu quand les panneaux sont masqués, l'écran en veille ou verrouillé, USB sur événements, aucun WebView.

## Prérequis

- macOS 12 ou plus
- Outils développeur Xcode : `xcode-select --install`
- Apple Silicon pour la température (capteurs `PMU tdie`)

## Installation

```sh
git clone https://github.com/IfLoud2/Widget.git
cd Widget
./install.sh
```

`install.sh` compile vers `~/.local/bin/StatsDesk`, crée un LaunchAgent et lance le widget au login.

Compilation seule :

```sh
./build.sh
~/.local/bin/StatsDesk
```

## Utilisation

Icône dans la barre de menus :

| Entrée | Effet |
|---|---|
| Edit layout (⌘⌥E) | Mode édition : glisser un panneau pour le déplacer, glisser le triangle en bas à droite pour le redimensionner |
| Reset layout | Positions et tailles d'origine |
| Panneaux | Afficher ou masquer chaque panneau |
| Background | Opacité du fond : 0, 10, 20, 35, 50 % |
| Quit | Quitter |

Positions, tailles, panneaux masqués et opacité sont mémorisés.

## Désinstallation

```sh
./uninstall.sh
```

## Limites

- Total downloaded : cumul depuis le lancement, interfaces `en*` uniquement
- RAM des apps : mémoire résidente, peut différer d'Activity Monitor
- SSID Wi-Fi : masqué par macOS sans autorisation de localisation, indisponible pour un binaire sans bundle
- Température : API privée `IOHIDEventSystemClient`, susceptible de changer entre versions de macOS
- Disposition calculée sur l'écran principal
