# Collecte native — 0.4

La Vue d’ensemble personnelle lit le catalogue Firestore, puis collecte les fournisseurs. Elle ne lit ni ne modifie les snapshots web. Les identifiants proviennent uniquement du trousseau déverrouillé. Les rapports bruts et événements individuels sont temporaires en mémoire ; aucune copie brute n’est écrite sur disque, dans les logs ou les préférences. Les agrégats sont conservés dans le cache chiffré décrit ci-dessous. La collecte s’annule au verrouillage, au changement de contexte, et par le bouton Annuler. Aucune réponse tardive ne peut réafficher un tableau après verrouillage.

## Sources attendues

Les préférences locales peuvent désactiver Google Play par jeu même si un package est déjà présent dans le catalogue. Aurora Grove est désactivé par défaut à la demande du propriétaire (iOS uniquement). Une source désactivée ne participe ni aux appels réseau ni au calcul de complétude. Ce réglage ne supprime aucune donnée distante.

## Périodes et valeurs

La période choisie est entièrement demandée : 1, 7, 30, 90 ou 365 jours, journée courante comprise. AdMob est interrogé par blocs de 28 jours. Apple fournit des rapports journaliers jusqu’à hier dans son fuseau. Google publie ses exports mensuels. Les dates sont celles du fournisseur, non réattribuées artificiellement au fuseau suisse : AdMob utilise le fuseau de son compte, Apple le Pacifique, Google les journées de ses exports. L’activité utilise le fuseau du projet Supabase. La journée courante et les données récemment publiées restent provisoires.

Les rapports absents, refusés, corrompus ou tronqués restent inconnus. Un rapport complet sans activité peut produire un zéro ; aucun succès de catalogue n’est utilisé comme preuve de données financières. La couverture d’un indicateur compte les jours disponibles pour toutes ses sources, tandis que son total additionne les valeurs reçues. Un jour ne peut pas être dit complet si l’une des sources attendues manque.

AdMob : `ESTIMATED_EARNINGS` en micros, devise demandée CHF, contrôle du footer, du nombre de lignes et des avertissements. Rattachement par identifiants AdMob enregistrés, ou par identifiant exact de boutique dans son catalogue. Une absence de rattachement ne déclenche jamais un rapport de tout le compte.

Apple : rapport SALES/SUMMARY quotidien, gzip décompressé en mémoire avec zlib système. Les achats intégrés sont associés par SKU parent obtenu via l’API App Store Connect ; l’Apple Identifier seul ne suffit pas. Nouvelles acquisitions hors updates et redownloads ; remboursements de recettes conservés avec leur signe. Les recettes développeur sont multipliées par les unités. Les devises ne sont pas converties implicitement : les montants par devise restent visibles par source, et un total CHF non calculable reste absent.

Google Play : exports d’installations par pays uniquement, sans additionner les autres dimensions. Liste paginée des rapports de recettes du mois avec fichiers de corrections, puis téléchargement et lecture CSV UTF-8/UTF-16 et ZIP en mémoire. Les montants marchand attribués au package incluent frais et remboursements. Les ventes estimées brutes en devise acheteur ne sont pas mélangées aux recettes nettes. Le rapport de recettes du mois courant peut ne pas être publié ; il ne devient pas un zéro. Les droits Google Cloud Storage/Play Console sont indépendants de l’accès au catalogue Reporting.

## Activité

Lecture paginée de `completion_events` (colonnes `user_id,run_id,completed_at`, ordre stable), avec limite de 100 000 lignes et erreur explicite au-delà. Aucun changement SQL, RLS, SDK ou clé publique. Les réponses non lisibles restent des erreurs et ne deviennent pas une liste vide.

Déduplication par joueur et partie. Depuis 0.14, les événements invalides (identifiant ou date illisible) et les doublons contradictoires sont écartés, comptés et signalés dans les alertes, sans bloquer les autres joueurs. Dans Gameplay/Joueurs, un nouveau mode ou niveau de difficulté est compté sous son propre nom ; seules les parties à date, identifiant ou valeur négative invalides sont écartées et signalées. Les événements futurs sont exclus. Un actif a terminé au moins une partie. Le quotidien est la moyenne des uniques par jour sur la période sélectionnée, journées à zéro comprises. Le mensuel mesure toujours les uniques des 30 jours glissants, quelle que soit la période sélectionnée. Le retour J7 mesure les joueurs ayant terminé une partie exactement sept jours après leur première partie **observée dans l’historique conservé** ; les cohortes sont dans la période choisie et leur septième jour est complètement écoulé. Ce n’est pas la rétention depuis l’installation. Au niveau studio, les joueurs sont comptés séparément par jeu.

L’ARPDAU utilise exclusivement les journées financières complètes et les joueurs de ces mêmes dates. Un dénominateur nul ou une devise incompatible reste indéterminé.

## Références de contrat consultées le 7 septembre 2026

- [Rapports AdMob](https://developers.google.com/admob/api/v1/reporting) et [footer](https://developers.google.com/admob/api/reference/rest/v1/ReportFooter).
- [Rapport de ventes Apple](https://developer.apple.com/help/app-store-connect/reference/reporting/summary-sales-report) et [types de produits](https://developer.apple.com/help/app-store-connect/reference/reporting/product-type-identifiers).
- [Formats et exports Google Play](https://support.google.com/googleplay/android-developer/answer/6135870?hl=en).
- [Pagination Supabase](https://supabase.com/docs/reference/javascript/using-modifiers-range). Changelog consulté ; aucun changement de schéma ni de droits n’est requis pour ces tables existantes.

## Limites du jalon

Cette version ne porte pas encore les collecteurs d’avis, crash/ANR, les ventilations financières pays/plateforme et la gestion des jeux. Le mode membre conserve ses snapshots et protections existants. L’accès réel aux nouveaux rapports doit être confirmé par le propriétaire dans le paquet 0.4 ; les tests simulés n’établissent pas ses droits chez chaque fournisseur. La signature Developer ID est reconstruite ; une notarisation de la version 0.3 ne couvre pas ce nouveau binaire.


## Cache 0.5

- Cache du tableau par jeu/studio et période, valable 15 minutes pour une navigation sans réseau ; un changement de journée (Europe/Zurich) impose une mise à jour. Les résultats anciens restent datés et affichables hors ligne.
- Totaux quotidiens de chaque fournisseur réutilisés entre périodes. Rafraîchissement automatique des journées absentes, des journées des sept derniers jours âgées de 15 minutes et des journées historiques âgées d’une semaine. Les rapports Google sont redemandés par mois si une de leurs journées doit être actualisée. Actualiser force toutes les journées de la période.
- Les corrections remplacent les totaux précédents. En cas d’échec, les montants précédents sont conservés et la source signale le recours au cache. L’activité agrégée pour la même période peut également servir de secours daté ; sa mise à jour recalcule toujours les uniques et cohortes depuis les événements uniquement en mémoire.
- Conservation bornée lors de l’enregistrement : 400 jours de totaux quotidiens, 40 tableaux et 200 agrégats d’activité au maximum ; tableaux et agrégats d’activité de plus de 30 jours retirés lors de cet entretien. Taille maximale d’un fichier : 16 Mio.
- Depuis 0.14, le nom du fichier chiffré dépend seulement du projet Firebase et de l’organisation. Le cache enregistre les comptes fournisseurs utilisés (éditeur AdMob, vendeur Apple, bucket et compte Google Play, projets Supabase).
- Les invalidations sont ciblées :
  - un autre compte fournisseur écarte uniquement les journées de ce fournisseur ;
  - un nouvel identifiant de boutique d’un jeu écarte uniquement les rapports de ce jeu ;
  - un changement de nom, de version, de description ou de statut conserve toutes les journées reçues et recalcule seulement les tableaux ;
  - activer ou désactiver Google Play pour un jeu recalcule ses tableaux et ceux du studio.
- Une nouvelle clé Apple pour le même vendeur, l’ajout d’Ballpark ou un réimport identique ne font rien retélécharger. Le cache d’une version antérieure est repris une fois sous le nouveau nom. Retirer les connexions ou « Vider le cache » suppriment toujours tout. Démo et mode membre ne le consultent pas.

### Lecture Apple corrigée en 0.5.1

Les acquisitions gratuites à recettes explicitement nulles peuvent avoir une devise vide : elles comptent pour les installations, sans inventer de devise. Une devise reste obligatoire pour un montant non nul. Un HTTP 404 n’est transformé en zéro que si Apple indique exactement NOT_FOUND / « There were no sales for the date specified. » ; les autres réponses restent inconnues. Un fichier malformé est signalé sans interrompre les dates suivantes. Les jours en cours Apple sont distingués des absences historiques : pending en gris, sans les compter comme complets ni leur attribuer zéro. Les journées sans ventes restent revérifiées selon la politique de cache, comme les autres journées reçues.


## Politique actuelle depuis 0.5.2 — uniquement manuelle

Cette règle remplace le déclenchement automatique décrit pour 0.5 : aucune collecte à l’ouverture, au déverrouillage, à la navigation ou après expiration du cache. Les vues locales restent consultables sans limite de fraîcheur déclenchant du réseau. Un changement de période sans tableau enregistré propose Synchroniser ; il ne collecte pas implicitement. Le bouton Synchroniser / ⌘R relit explicitement la période sélectionnée. Les critères de fraîcheur des journées restent disponibles dans le moteur de cache, mais ne déclenchent aucune tâche d’interface.

Le catalogue est conservé avec sa date de lecture. Les vues individuelles disposent d’un cache en mémoire limité à 16 contextes, partagé entre Joueurs et Gameplay pour le même jeu et la même période. Elles ne sont jamais persistées. Ce cache est vidé au verrouillage, au retrait/changement de connexion et à la déconnexion. Ouvrir une autre fenêtre sur le même contexte ne lance pas de requête et n’annule pas une synchronisation manuelle déjà en cours.

La date affichée en haut est celle des données de la vue, conservée lors d’une simple réouverture. Une vue sans lecture antérieure indique qu’elle n’a pas encore été synchronisée. Les actions explicites d’authentification/import/vérification des connexions peuvent toujours interroger les fournisseurs pour valider l’accès, sans collecter les statistiques.


## Acquisitions et inspection des courbes — 0.6.0

La métrique `newPlayers` compte la première date de partie terminée observée pour chaque joueur dans l’ensemble de l’historique reçu, puis retient celles de la période sélectionnée. Le fuseau est celui du jeu. Doublons, ordre des événements et casse des UUID ne multiplient pas les joueurs ; les dates futures sont exclues. Un joueur déjà observé avant la période ne compte pas comme nouveau. L’absence d’un ancien historique peut donc limiter la définition à une première observation, et non à la première partie réelle.

Le cache ajoute uniquement un dictionnaire date → nombre de nouveaux joueurs et les valeurs quotidiennes du tableau. Ces champs sont optionnels : les anciens caches restent lisibles, et l’absence de la métrique ne devient pas zéro. Sans agrégat pour tous les jeux sélectionnés, le total studio reste inconnu. Aucune lecture réseau supplémentaire n’est déclenchée par l’affichage, les onglets du graphique, le survol ou le clavier.

Les infobulles suivent la journée la plus proche du pointeur dans la zone de tracé ; elles s’effacent à sa sortie. Les valeurs indisponibles restent explicites et les courbes ne relient pas les points à travers une journée manquante. Les installations du graphique additionnent les rapports reçus et peuvent donc être partielles ; les indications de couverture sont disponibles sur la carte du tableau de bord.


## Synchronisation du studio — 0.12.0

La collecte manuelle n’est plus limitée à la page ouverte : Synchroniser/⌘R charge les tableaux du studio et de chaque jeu, le catalogue, Gameplay/Joueurs pour chaque jeu et les Avis, sur la période sélectionnée. Les vues sont conservées en mémoire sans la limite ancienne de 16 snapshots qui pouvait évincer des résultats de la même collecte. Les agrégats chiffrés restent les seules statistiques persistées. Les rapports récents sont relus à chaque clic ; les rapports historiques sont revérifiés après sept jours ou avec ⇧⌘R. Le bilan présente les lectures incomplètes, et la navigation réutilise les résultats sans réseau. Les erreurs ordinaires n’empêchent pas les autres rubriques de charger ; les refus d’accès arrêtent la collecte et retirent les données protégées.


## Rapports Ballpark — 0.13.0

Ballpark n’utilise pas les tables historiques `completion_events` de GameMetrik. Son projet Supabase expose un unique RPC administratif versionné, `gamemetrik_ballpark_report_v1`, avec cinq rapports paginés : `overview`, `questions`, `series`, `habits` et `quality`. Chaque demande fixe période, fuseau Europe/Zurich, mode, version d’app, instant de lecture et curseur. Les pages suivantes doivent conserver exactement filtres, couverture et `as_of` ; les doublons, boucles de curseur et réponses hors contrat sont refusés.

Les agrégats reçus ne sont pas recalculés dans le client. Les rapports conservent les numérateurs, dénominateurs, valeurs nulles, motifs d’indisponibilité, limites de collecte v1/v2 et avertissements. Les questions et séries suivent le jour de jeu commençant à 09:00 Europe/Zurich ; les autres mesures utilisent les jours civils documentés par le contrat. Les petits échantillons restent masqués par la fonction serveur.

La connexion utilise uniquement `PersonalSupabase`, avec une clé administrative saisie par le propriétaire et enregistrée dans le trousseau. Aucune identité, réponse brute, estimation, résultat, code de groupe ni profil joueur n’est demandé ou persisté. Le mode membre n’obtient pas ce RPC. Une erreur 401/403 purge les données protégées ; l’échec d’un volet ordinaire peut laisser les autres rapports disponibles et signalés comme partiels.


## Synchronisation ciblée — 0.13.1

Cette règle remplace le périmètre du bouton décrit en 0.12.0. Synchroniser/⌘R et la relecture complète ⇧⌘R prennent le jeu actuellement sélectionné comme frontière : Vue d’ensemble, Gameplay/Joueurs et Avis pour un jeu historique ; Analyse Ballpark uniquement pour Ballpark. Lorsque **Tout le studio** est sélectionné, seules la vue agrégée et les Avis sont actualisés. Les rapports fournisseurs, les événements joueurs et les vues locales des autres jeux ne sont ni interrogés ni remplis par cette action. La synchronisation ordinaire continue de revérifier les journées récentes du jeu ciblé à chaque clic.

Les rubriques ciblées continuent après une erreur ordinaire et le bilan nomme le jeu concerné. Les refus 401/403 interrompent toujours la collecte et purgent les données protégées de la mémoire. Depuis 0.14, le fichier chiffré est conservé : un seul service refusé n’efface plus l’historique des autres fournisseurs. La préparation d’un export reste une action distincte et charge uniquement les vues requises pour le jeu sélectionné.


## Journées définitives — 0.15.1

Cette règle précise la revérification hebdomadaire décrite en 0.5 et 0.12.0. Une journée fournisseur lue au moins 45 jours après sa date est définitive : clôture mensuelle AdMob, rapports quotidiens Apple et exports mensuels Google sont alors publiés. Elle n’est plus relue par Synchroniser/⌘R ; seule la relecture complète ⇧⌘R la redemande. Une journée lue plus tôt reste revérifiée chaque semaine (ou à chaque clic dans les sept derniers jours), puis devient définitive après une lecture faite au-delà de ce délai. Une année déjà synchronisée ne demande donc plus qu’environ 45 journées.

L’export d’installations Google Play couvre son mois jusqu’à sa dernière ligne publiée. Une journée antérieure sans ligne pour le package vaut zéro installation ; une journée postérieure reste inconnue. Sans ce zéro, une seule journée sans installation faisait retélécharger tout le mois à chaque synchronisation.

L’activité joueurs est toujours relue depuis les événements en mémoire : aucun identifiant ni événement n’est persisté pour la rendre incrémentale.
