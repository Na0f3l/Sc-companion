# Suivi mémoire Star Citizen — mesures et méthodes de calcul

Ce document décrit ce que mesure l'application, comment chaque valeur est obtenue, et les limites à garder en tête.
Toutes les heures sont en **heure locale**. Les événements du Game.log (horodatés en UTC par le jeu) sont convertis en heure locale.

## 1. Les trois notions de mémoire à ne pas confondre

| Notion | Ce que c'est | Où on la voit |
|---|---|---|
| **RAM physique** | Pages réellement présentes en mémoire vive | `Sys_RAM_Utilisee_Go`, `Sys_RAM_Dispo_Go`, `SC_WorkingSet_Go`, `SC_PrivateWS_Go` |
| **Mémoire engagée (« validée »)** | Mémoire que Windows a garantie à un programme, en RAM **ou** dans le fichier d'échange. Limitée par la *limite d'engagement* = RAM + fichier d'échange | `Sys_Validee_Go`, `Sys_Limite_Validee_Go`, `Sys_Validee_pct`, `SC_Validee_Go` |
| **Mémoire virtuelle réservée** | Espace d'adresses réservé. Ne consomme ni RAM ni engagement tant qu'il n'est pas engagé. Plusieurs To sont normaux en 64 bits | `SC_Virtuelle_Go` |

**C'est la mémoire engagée privée de Star Citizen (Private Bytes, `SC_Validee_Go`) qui fuit.** Quand l'engagement système atteint 100 % de la limite, les allocations échouent et le jeu ou le PC plante.

## 2. Sources des mesures

| Source | Mesures | Coût |
|---|---|---|
| `GetPerformanceInfo` (psapi) | engagement système, limite, RAM disponible (relevé, capture **et** lignes du CSV) | instantané |
| `NtQuerySystemInformation(SystemProcessInformation)` : **un instantané par relevé**, partagé | tout ce qui concerne les processus : présence du jeu et des logiciels de head-tracking, Private Bytes, Working Set, Private Working Set, Virtual Bytes, défauts de page (cumul), défauts durs (cumul), handles, threads, temps CPU (pour `SC_CPU_pct`), heure de lancement du jeu, top des autres processus. **N'ouvre pas de handle sur le jeu**, ce qui fonctionne malgré l'anti-triche. Remplace `Get-Process` | ~3 ms |
| Compteurs de performance Windows (PDH, noms anglais) | CPU, disque, `\Memory\Pages Input/sec`, `\Memory\Page Faults/sec`, `\Paging File(_Total)\% Usage`, `\GPU Process Memory(*)\Dedicated/Shared Usage` (VRAM de SC), `\GPU Adapter Memory(*)\Dedicated Usage` (VRAM totale) | rapide |
| WMI (`Win32_PageFileUsage`) | **taille** du fichier d'échange uniquement, au plus toutes les 2 min (son utilisation vient du compteur `% Usage`) | ~30 ms toutes les 2 min |
| `nvml.dll` / D3DKMT / MSI Afterburner | GPU NVIDIA, GPU toutes marques, température CPU | rapide |
| `Get-Process` | uniquement une fois par lancement du jeu (chemin de l'exécutable), et pour le nom d'un programme au premier plan s'il vient tout juste de démarrer | rare |

## 3. Fichiers produits (dossier `tracking`)

| Fichier | Contenu | Fréquence |
|---|---|---|
| `session_<début>.csv` | Ligne de session : valeurs instantanées + **moyennes** des capteurs sur l'intervalle | toutes les 15 s (réglable) |
| `mesures_<début>.csv` | **Mesures brutes horodatées**, sans moyenne, pendant tout le tracking | toutes les 5 s (réglable), **1 s** pendant une anomalie |
| `incident_<1re mesure>.csv` | 2 min avant le début estimé d'une fuite, puis la suite. Écrit ligne par ligne : survit à un plantage | 1 s |
| `incident_<…>_chronologie.txt` | Événements des 120 s avant la fuite (et 30 s après) | à la confirmation |
| `session_<début>_rapport.txt` | Rapport de fin de session (identique au panneau RAPPORT de l'analyse) | à l'arrêt du tracking |
| `Game_<début>[_partieN].log` | Copie des Game.log de la session | à l'arrêt du tracking |
| `cache\*.json` | Résumés pour la comparaison des sessions. Peut être supprimé sans risque : il est recalculé | à la demande |

Séparateur `;`, décimales à la française (`,`), encodage UTF-8. La colonne `Horodatage` (`aaaa-mm-jj hh:mm:ss.mmm`) date chaque ligne à la milliseconde. Les lignes sans `Minutes` sont des lignes de repère (renommage, note, fin du tracking).

## 4. Colonnes

### Système
- `Sys_Validee_Go` : mémoire engagée totale du système.
- `Sys_Limite_Validee_Go` : limite d'engagement (RAM + fichier d'échange).
- `Sys_Validee_pct` = 100 × engagée / limite.
- `Sys_RAM_Utilisee_Go` = RAM totale − RAM disponible ; `Sys_RAM_Dispo_Go` : RAM physique disponible.
- `Pagefile_Go` : fichier d'échange utilisé. Dans le CSV de session, c'est la valeur WMI ; dans les mesures brutes, `taille × % Usage`.
- `Pagefile_Taille_Go` : taille actuelle du fichier d'échange. `Pagefile_pct` : % utilisé.
- `Defauts_Page_s` : défauts de page système par seconde, doux et durs confondus (`\Memory\Page Faults/sec`).
- `Pagination_Mo_s` = `Pages Input/sec` × 4 Ko : pages **lues sur disque** (fichier d'échange ou fichiers mappés).

### Star Citizen
- `SC_Validee_Go` : **Private Bytes** (mémoire privée engagée), somme des processus `StarCitizen`.
- `SC_WorkingSet_Go` : en RAM (pages privées + partagées). `SC_PrivateWS_Go` : partie privée du Working Set.
- `SC_Virtuelle_Go` : Virtual Bytes (réservé + engagé, fichiers mappés compris). Windows ne permet pas d'isoler la part « réservée mais non engagée » sans ouvrir un handle sur le jeu, ce que l'anti-triche bloque.
- `SC_Defauts_s` : défauts de page de SC par seconde = écart du compteur cumulé ÷ temps écoulé depuis le relevé précédent **du même fichier**.
- `SC_Defauts_Durs_s` : idem pour les défauts **durs**, c'est-à-dire ceux qui ont lu le disque. La plupart des défauts de page sont « doux » (page déjà en RAM, page neuve remise à zéro) et ne touchent pas le disque.
- `SC_GPU_Dediee_Go` / `SC_GPU_Partagee_Go` : VRAM de SC (compteurs PDH relevés par la capture, au plus 5 s avant la ligne).
- `SC_CPU_pct` : temps CPU cumulé des processus du jeu entre deux lignes ÷ (durée × nombre de cœurs logiques).
- `SC_Handles`, `SC_Threads` : somme des processus du jeu.
- `SC_Pente15_Mo_s` / `SC_Pente30_Mo_s` : vitesse de la mémoire engagée de SC (voir §5).
- `Fuite_Etat` : `hausse` (seuil dépassé, pas encore confirmé), `FUITE` (fuite suspectée) ou vide.

### Head-tracking
- `AITrack_Mo`, `opentrack_Mo` : mémoire privée des logiciels (vide = non lancé).

## 5. Détection de fuite

- **Vitesse.** C'est la pente de `SC_Validee_Go` en Mo/s, par **régression linéaire (moindres carrés)** sur les relevés des 15 s et des 30 s précédentes. Les relevés ont lieu toutes les 2 s et sont horodatés par une horloge monotone. La régression lisse un relevé isolé sans retard excessif. La pente n'est calculée que si la fenêtre est remplie à au moins 60 %.
- **Hausse rapide.** Pente 15 s ≥ seuil « FUITE » (100 Mo/s par défaut).
- **Fuite suspectée.** La hausse rapide dure sans interruption pendant la durée choisie (15 s par défaut). Deux exceptions :
  - pendant 45 s après un événement de chargement du Game.log (connexion, changement de serveur ou de lieu, saut quantique, fin de chargement), il faut **30 s de plus** ;
  - rien n'est détecté pendant les **3 premières minutes** du jeu (chargement initial).
- **Début estimé.** En remontant depuis le franchissement du seuil, c'est le dernier relevé « calme », où la vitesse sur 2 relevés est inférieure au seuil ÷ 3 : le coude de la courbe. Il reste exact même quand la confirmation est retardée.
- **Fin (retour à la normale).** Pente 30 s < seuil ÷ 3 pendant la durée « FIN APRÈS » (60 s par défaut). Une nouvelle hausse pendant ce délai prolonge le même épisode. Une montée de moins de 90 s accompagnée d'un événement de chargement est marquée « écartée : chargement probable ».
- **Emballement.** Durée du début estimé jusqu'au début du calme ; le gain est la mémoire prise pendant ce temps.
- **Capture.** Tampon circulaire de 3 min (2 min avant le début estimé + 1 min de marge), une mesure toutes les 5 s, ou 1 s dès la hausse rapide. À la confirmation, il est écrit dans `incident_*.csv`, puis chaque mesure est ajoutée aussitôt.
- **Anciennes sessions** (sans pente) : la « variation entre mesures » est l'écart entre deux lignes du CSV ÷ temps (15 s). Elle n'est **pas comparable** à la pente 15 s.

## 6. Événements et corrélation

- **Origine des événements.** Ils viennent **uniquement** de sources observées : lignes du Game.log reconnues (connexion, changement de serveur ou de lieu, saut quantique, chargement, zones, combat, `<SystemQuit>`), changements de premier plan (alt-tab, avec le programme qui prend le focus), lancement ou fermeture des logiciels de head-tracking (liste `$SoftList`) et repères posés à la main. Aucun événement n'est déduit.
- **Chronologie.** Événements de −120 s à +30 s autour du début estimé. Les alertes et les repères de fuite sont exclus.
- **Événements récurrents.** Pour chaque type d'événement (sans les détails entre parenthèses), on compte avant combien de fuites il apparaît dans les 120 s. On le compare au « hasard » : probabilité qu'une fenêtre de 120 s quelconque des sessions le contienne, soit `1 − exp(−n × 120 / durée totale)`. Une même fuite présente dans une session et dans son incident n'est comptée qu'une fois. Un événement n'est mis en avant qu'à partir de 3 fuites, s'il est présent avant ≥ 50 % d'entre elles avec un écart ≥ 25 points sur le hasard.
- **Une corrélation dans le temps n'est pas une preuve de cause.** Un événement fréquent en jeu précède forcément beaucoup de fuites.

## 7. Contexte de session (comparaison)

Ces informations sont lues dans les Game.log copiés de la session :
- **Mode.** `<Join PU>` = univers persistant ; `gamerules="EA_…"` ou `Requesting game mode …/EA_…` = Arena Commander (le mode est indiqué, ex. PirateSwarm).
- **Rendu.** `vkCreateDevice` = Vulkan. Création d'un appareil D3D11 sans Vulkan = DX11. Sinon « ? ». *La signature DX11 n'a pas encore été vérifiée sur un vrai log DX11.*
- **Vaisseau.** `Local client node […] releasing control token for '<vaisseau>'` = vaisseau que le joueur pilotait. Cette ligne n'est écrite que lorsqu'on quitte le vaisseau : un vaisseau jamais quitté (plantage, fin de partie dedans) n'apparaît pas.
- **Head-tracking.** Mémoire d'AITrack ou opentrack présente dans le CSV, ou repère « Logiciel : … lancé ».
- **1re fuite.** Délai entre la première mesure où le jeu tourne et le début estimé de la première fuite.
- **Fuites/h.** Nombre de fuites ÷ heures de jeu, uniquement pour les sessions enregistrées avec la détection.

## 8. Fin de session

- **Arrêt volontaire.** Le jeu disparaît et le Game.log contient `<SystemQuit>` (« Fermeture du jeu ») dans les 3 min précédentes.
- **Plantage ou fermeture forcée probable.** Le jeu disparaît sans `<SystemQuit>`. Un Alt+F4 ou un arrêt par le Gestionnaire des tâches donnent le même résultat, d'où le « probable ».
- **Plantage de l'application ou du PC probable.** Pas de repère « Fin du tracking » alors que le jeu tournait à la dernière mesure. Ce cas n'est évalué que pour les sessions enregistrées avec la version actuelle.
- **Arrêt manuel / application fermée.** Repère « Fin du tracking : … ».

## 9. Impact de la surveillance

Mesuré sur ce PC, sans le jeu (banc d'essai sans fenêtre, médianes) :

| | avant optimisation | après |
|---|---|---|
| Relevé principal (toutes les 2 s) | 13 ms | 6 ms |
| Ligne du CSV de session (toutes les 15 s) | 315 ms (4 requêtes WMI) | 6 ms (aucune) |
| Mesure de capture (5 s, ou 1 s pendant une anomalie) | 8,5 ms | 7,7 ms |
| Dessin de la courbe en direct (toutes les 2 s + au survol) | 91 ms | 2,9 ms |
| Lecture de 1,2 Mo de Game.log d'un coup | 355 ms | 138 ms |
| CPU en régime | 1,8 % d'un cœur | 1,0 % d'un cœur |
| Mémoire de l'appli (1 500 relevés d'affilée) | — | stable, ~135–140 Mo, handles stables |

Ce qui a été fait :
- un seul instantané système des processus par relevé, au lieu de `Get-Process` ;
- aucune requête WMI dans les lignes du CSV ;
- les points des courbes, leurs échelles et la recherche de la mesure sous la souris sont calculés en C# (recherche dichotomique au lieu d'un parcours de toute la session) ;
- les stylos, pinceaux et polices sont créés une fois et réutilisés, au lieu d'être recréés à chaque dessin ;
- le Game.log est préfiltré par une seule expression compilée sur tout le bloc lu ;
- le cache d'expressions régulières est agrandi ;
- le tampon de l'appel système est réutilisé ;
- les textes de l'interface ne sont réécrits que s'ils changent ;
- la minuterie du raccourci et des alt-tab passe de 150 à 250 ms.

La comparaison et la liste des incidents lisent les fichiers **un par un** entre deux rafraîchissements de l'interface, et gardent un résumé en cache.
