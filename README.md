# SC Companion

Compagnon Star Citizen : infos en jeu en temps réel (perso, vaisseau, alertes) à partir de la télémétrie gRPC locale du jeu, et surveillance de la mémoire (détection de fuite). Pensé pour être le plus léger possible en RAM / CPU, et lisible sur PC comme sur téléphone (Wi-Fi local).

## Contenu

| Dossier | Rôle |
|---|---|
| `service/` | Service Node 24 (TypeScript exécuté nativement) : lit le flux gRPC du jeu (lecture seule) ou rejoue une capture, diffuse à l'interface par WebSocket (5 Hz max, seules les valeurs modifiées, pause totale sans écran connecté) |
| `interface/` | Interface Vue 3 + Vite + TypeScript + SCSS : écrans façon HUD (vol, perso, environnement), alertes plein écran avec son |
| `telemetrie/` | Outils : sonde (`probe`), faux serveur (`fake`), capture brute des champs inconnus (`raw`) |
| `memoire/` | Outil PowerShell de suivi mémoire / CPU / GPU et de détection de fuite (`memoire/METRIQUES.md`) |

## Lancer

Prérequis : Node 24, et la télémétrie activée côté jeu (LIVE 4.10 : variable d'environnement `GRPC_CLIENT_SERVER_ENABLED=true` avant de lancer le RSI Launcher).

Le schéma `.proto` vient du projet communautaire [Sokren/sc-telemetry-deck](https://github.com/Sokren/sc-telemetry-deck) (`schema/sc_extrait.proto`). Il n'a pas de licence, donc il n'est pas inclus : le récupérer et le placer dans `telemetrie/proto/sc_telemetry.proto`.

```
cd interface && npm install && npm run build   # une fois (et après chaque modification de l'interface)
cd service   && npm install && node src/index.ts  # puis ouvrir http://localhost:2950 (ou http://<ip-du-pc>:2950 sur le téléphone)
```

Sans terminal : double-clic sur `Lancer.vbs` (ou un raccourci vers `wscript.exe "…\Lancer.vbs"` avec `icone.ico`). Il démarre le service en arrière-plan s'il ne tourne pas déjà, puis ouvre l'interface ; les messages du service vont dans `service/service.log`. Une icône SC Companion apparaît dans la zone de notification (à côté de l'horloge) : double-clic pour ouvrir l'interface, clic droit pour Sessions, Mobile connect ou **Quit** (arrêt du service) ; l'infobulle indique l'état du jeu. `--no-tray` pour s'en passer.

Données de l'utilisateur (sessions de jeu, réglages communs, données vaisseaux mises à jour) : `%LOCALAPPDATA%\SC Companion\` (copiées depuis l'ancien `service/data/` au premier lancement). Dossier du jeu : celui du dernier lancement noté par le launcher RSI (LIVE, PTU, autre disque…), sinon `C:\Program Files\Roberts Space Industries\StarCitizen\LIVE` ; `--game-dir <dossier>` le force. Si le service tourne déjà, un second lancement le signale et s'arrête sans rien toucher.

Le service sert lui-même l'interface compilée : pas besoin du serveur de développement Vite pour jouer (~500 Mo économisés). `npm run dev` dans `interface/` ne sert qu'à développer.

Options du service : `--replay ../telemetrie/captures` (rejeu de captures), `--game-dir <dossier>` (jeu hors de `…\StarCitizen\LIVE`), `--port <n>`. Le lancer avec `node` directement plutôt que `npm run` (npm garde un processus parent de ~60 Mo).

Empreinte mesurée : ~59 Mo de mémoire privée, ~1 % d'un cœur CPU, ~0,3 Ko/s par écran.

Suivi mémoire : double-clic sur `memoire/app/Lancer.vbs`.

## Ce que le jeu envoie (LIVE 4.10)

Reçu : santé, faim, soif, température, cardio, O₂, environnement, solde, vitesse, H-Fuel, boost, G (valeur totale), altitude radar, cap, vitesse verticale, voyants d'alerte, train, IFCS, alimentation, armes, contre-mesures.

Prévu par le schéma mais jamais envoyé : Q-Fuel, coque, boucliers, mode de vol, événements, retour de force. Aucun vecteur de déplacement : pas de marche arrière, de dérive ni de G par axe. Vérifiable après une mise à jour du jeu avec `npm run raw` dans `telemetrie/`.

## Crédits

Sons d'alerte (`interface/public/sounds/`) :

- alerte rouge : « warning » de **Lyubomir Ikonomov** ([Freesound 787777](https://freesound.org/s/787777/)), libre d'utilisation ;
- alerte orange : « Mechanical gas release alert » ([Mixkit](https://mixkit.co/)).

Données des vaisseaux (`interface/public/data/`, régénérées par `npm run ships` dans `service/` ; quand le wiki annonce une nouvelle version du jeu, le bouton « Update ship data » de l'interface les met à jour sans rebuild) :

- noms, vitesses, rotations, carburant : [API du Star Citizen Wiki](https://api.star-citizen.wiki) ;
- accélérations en G mesurées en jeu : données communautaires de [SPViewer](https://www.spviewer.eu).

## Avertissement

Projet personnel, non affilié à Cloud Imperium Games. Le service est en lecture seule : il n'envoie aucune commande au jeu.

## Licence

SC Companion est libre et open source, sous licence MIT (voir `LICENSE`). Les contenus tiers (sons, polices, données des vaisseaux, schéma de télémétrie) gardent leur propre licence : voir « Crédits » ci-dessus et la fenêtre « About » de l'interface.

Projet de fan non officiel, sans lien avec Cloud Imperium Games. Star Citizen®, Roberts Space Industries® et Cloud Imperium® sont des marques de Cloud Imperium Rights LLC.
