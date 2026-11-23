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
cd service    && npm install && node src/index.ts                 # jeu en direct (127.0.0.1:2942)
cd service    && node src/index.ts --replay ../telemetrie/captures # ou : rejeu de captures
cd interface  && npm install && npm run dev                       # http://localhost:5173 (et http://<ip-du-pc>:5173 sur le téléphone)
```

Lancer le service avec `node` directement plutôt que `npm run` (npm garde un processus parent qui coûte ~60 Mo).

Suivi mémoire : double-clic sur `memoire/app/Lancer.vbs`.

## Ce que le jeu envoie (LIVE 4.10)

Reçu : santé, faim, soif, température, cardio, O₂, environnement, solde, vitesse, H-Fuel, boost, G (valeur totale), altitude radar, cap, vitesse verticale, voyants d'alerte, train, IFCS, alimentation, armes, contre-mesures.

Prévu par le schéma mais jamais envoyé : Q-Fuel, coque, boucliers, mode de vol, événements, retour de force. Aucun vecteur de déplacement : pas de marche arrière, de dérive ni de G par axe. Vérifiable après une mise à jour du jeu avec `npm run raw` dans `telemetrie/`.

## Avertissement

Projet personnel, non affilié à Cloud Imperium Games. Le service est en lecture seule : il n'envoie aucune commande au jeu.
