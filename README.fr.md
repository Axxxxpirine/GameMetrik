# GameMetrik

*[English version](README.md)*

GameMetrik est une application macOS native, avec un compagnon iPhone, qui rassemble les chiffres d'un petit studio de jeux : ventes des boutiques, revenus publicitaires, joueurs actifs, gameplay et rétention. Elle lit chaque fournisseur directement depuis ton Mac. Il n'y a ni serveur, ni compte à créer, ni télémétrie.

Elle a été écrite par un développeur indépendant pour ses propres jeux, puis ouverte. Lis la section suivante avant de prévoir de l'utiliser pour les tiens.

## À quoi t'attendre

- **L'interface est en français**, comme les guides détaillés. Les commentaires du code sont en anglais.
- **Un mode démonstration est fourni.** Il montre tous les écrans avec des données fictives et se compile sans compte développeur Apple.
- **Les parties génériques fonctionnent pour tout studio** : rapports de ventes App Store Connect, rapports Google Play, revenus AdMob et catalogue de jeux conservé dans Firestore.
- **Certains rapports sont propres aux deux jeux de l'auteur.** Ils figurent ici sous des noms d'emprunt, Aurora Grove et Ballpark, et appellent des fonctions d'analyse qui n'existent que dans les projets Supabase de ces jeux. Considère-les comme des exemples complets d'un contrat de rapport, de sa validation et de son affichage.

## Ce que fait l'app

- Vue d'ensemble du studio : installations, joueurs actifs, revenus par devise, avec la couverture de chaque source affichée près des chiffres.
- Pages par jeu : acquisition, gameplay, parcours des joueurs, rétention, monétisation, avis.
- Synchronisation manuelle avec un cache local chiffré : une journée définitive n'est pas relue.
- Export CSV, et un dossier facultatif de tableaux agrégés destiné à un assistant IA.
- Une donnée manquante reste manquante : une source en échec est indiquée comme indisponible, jamais comme zéro, et les devises ne sont pas additionnées.

## Essayer la démonstration

Il faut un Mac sous macOS 14 ou ultérieur et Xcode 16 ou ultérieur (Swift 6).

```sh
git clone https://github.com/Axxxxpirine/GameMetrik.git
cd GameMetrik
GAMEMETRIK_DEMO_BUILD=1 ./NativeApp/scripts/build.sh
open "NativeApp/dist/GameMetrik Demo.app"
```

Clique **Déverrouiller** et confirme avec Touch ID ou le mot de passe du Mac. L'app s'ouvre sur les données de démonstration.

Le paquet de démonstration est signé ad hoc, pour ton Mac uniquement. Il n'a pas de groupe de trousseau et ne peut donc enregistrer aucune connexion : il affiche des données fictives, rien d'autre.

## Compiler pour tes propres données

Les connexions réelles sont rangées dans le trousseau Data Protection, dans un groupe que macOS n'accorde qu'à une app signée avec un profil de provisionnement. Il te faut donc :

1. Une adhésion Apple Developer.
2. Un identifiant d'app `ch.gamemetrik.native` dans ton équipe (ou le tien, remplacé partout dans les sources), avec un profil de provisionnement macOS qui inclut son groupe de trousseau.
3. L'identité de signature dans ton trousseau.

```sh
./NativeApp/scripts/build.sh
```

Le script trouve seul une identité et un profil compatibles. Pour les choisir explicitement, définis `GAMEMETRIK_SIGNING_IDENTITY` et `GAMEMETRIK_SIGNING_PROFILE`. Il ne revient jamais à une signature ad hoc, sauf si tu demandes le paquet de démonstration.

Suis ensuite le guide de connexion : [NativeApp/CONNEXION.md](NativeApp/CONNEXION.md).

## Tests

```sh
swift test --package-path NativeApp
```

Les tests utilisent des fixtures synthétiques et des clés créées à l'exécution. Ils ne font aucun appel réseau.

## App iPhone

[iOSApp/](iOSApp/README.md) est un client SwiftUI qui partage le module `GameMetrikCore`. Il reçoit ses connexions du Mac par un fichier de transfert chiffré et de courte durée. Renseigne ta propre équipe Apple avant de compiler pour un appareil.

## Sécurité et confidentialité

- Les identifiants restent dans le trousseau de ton appareil, protégés par Touch ID, Face ID ou ton mot de passe. Ils ne sont jamais écrits dans le paquet de l'app, les préférences ou les journaux.
- L'app démarre verrouillée, et se verrouille à la veille, au verrouillage de l'écran et après cinq minutes sans activité.
- L'app tourne dans l'App Sandbox avec le Hardened Runtime. Son seul trafic réseau va vers les fournisseurs que tu connectes.
- Les parties brutes et les profils des joueurs restent en mémoire. Le cache sur disque ne contient que des agrégats, chiffrés en AES-256-GCM.

Le détail est dans [NativeApp/SECURITE.md](NativeApp/SECURITE.md). Pour signaler une faille, voir [SECURITY.md](SECURITY.md).

## Organisation

| Chemin | Contenu |
| --- | --- |
| `NativeApp/Sources/GameMetrikCore` | Modèles, clients des fournisseurs, contrats de rapports, agrégation, exports. Aucune interface. |
| `NativeApp/Sources/GameMetrikNative` | L'app macOS : vues SwiftUI, état de l'app, coffre du trousseau. |
| `NativeApp/Tests` | Tests unitaires et d'intégration sur fixtures synthétiques. |
| `NativeApp/scripts` | Scripts de compilation, de paquet et de notarisation. |
| `iOSApp` | Le client iPhone. |

`NativeApp` ne dépend que des SDK Apple : ni Node, ni vue web, ni serveur local.

## Licence

[MIT](LICENSE). GameMetrik est un projet indépendant, sans lien avec Apple, Google, Firebase, AdMob ou Supabase.
