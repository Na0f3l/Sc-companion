# SC Companion

Compagnon Star Citizen : surveillance de la mémoire (détection de fuite, alertes) et, à terme, infos en jeu en temps réel (santé du perso, état du vaisseau…) via la télémétrie gRPC locale du jeu.

## Contenu

| Dossier | Rôle | État |
|---|---|---|
| `memoire/` | Outil PowerShell de suivi mémoire / CPU / GPU, tracking CSV, détection de fuite, rapports | opérationnel |
| `memoire/app/` | L'application (`Lancer.vbs` → `SuiviMemoireSC.ps1`, `reglages.json`) | |
| `memoire/tracking/` | Sessions enregistrées (CSV, rapports, incidents, copies du Game.log), non versionnées | |
| `memoire/partage/` | Version distribuable (zip + installeur), non versionnée | |
| `memoire/METRIQUES.md` | Ce que mesure l'outil et comment | |
| `telemetrie/` | Sonde de connexion à la télémétrie gRPC du jeu (`127.0.0.1:2942`) + faux serveur de test (port 2943) | sonde testée sur LIVE 4.10 |

## Lancer

- **Suivi mémoire** : raccourci « Suivi mémoire SC » du Bureau, ou double-clic sur `memoire/app/Lancer.vbs`.
- **Sonde gRPC** (dans `telemetrie/`) :
  - Schéma : le fichier `.proto` vient du projet communautaire [Sokren/sc-telemetry-deck](https://github.com/Sokren/sc-telemetry-deck) (`schema/sc_extrait.proto`). Il n'a pas de licence, donc il n'est pas inclus ici : le récupérer et le placer dans `telemetrie/proto/sc_telemetry.proto`.
  - `npm install` (première fois)
  - `npm run fake` : faux serveur pour tester sans le jeu
  - `npm run probe -- --seconds 60` : écoute le vrai jeu (nécessite `GRPC_CLIENT_SERVER_ENABLED=true` avant de lancer le RSI Launcher)

## Avertissement

Projet personnel, non affilié à Cloud Imperium Games. La sonde est en lecture seule : elle n'envoie aucune commande au jeu.
