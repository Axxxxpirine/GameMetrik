# GameMetrik pour iPhone — 0.1.0

Client SwiftUI de consultation pour un usage personnel, iOS 17 ou ultérieur. Il lit directement Firebase/Firestore, Supabase, AdMob et les rapports Apple/Google Play, même lorsque le Mac est éteint. Aucune infrastructure supplémentaire, aucun serveur embarqué et aucune publication.

Le moteur de données est le même module `GameMetrikCore` que sur Mac. La cible iOS est distincte de la cible macOS ; aucun identifiant réel n’est intégré au projet ou au paquet.

## Consultation

- **Studio** : acquisition, activité, revenus par devise, ventilation par pays/plateforme, inspection d’une journée et couverture des sources.
- **Jeux** : catalogue, indicateurs par jeu, gameplay, recherche et fiches joueurs, avis déjà collectés.
- **Ballpark** : Aperçu, Questions, Séries, Habitudes et Qualité, avec les mêmes contrats et seuils de masquage que sur Mac.
- **Réglages** : import de connexion, verrouillage et retrait des connexions locales.

La période est visible auprès de la provenance. **Synchroniser** actualise explicitement la sélection ; naviguer ne lance pas de collecte. Dans Studio, seule la vue agrégée est chargée. Pour un jeu, ses rubriques sont lues. Garde l’app ouverte pendant la collecte : le passage en arrière-plan la verrouille et annule les requêtes.

Les tableaux fournisseurs agrégés sont conservés sous chiffrement pour consultation hors ligne après déverrouillage. Les profils, parties et cinq rapports Ballpark restent en mémoire, puis sont effacés au verrouillage. Ballpark et les joueurs nécessitent donc une nouvelle synchronisation à la réouverture. Les avis affichés sont filtrés par période et proviennent de Firestore, sans collecte directe des boutiques.

La démonstration est explicite et indépendante des données réelles. Ses rapports Ballpark ont une période fixe du 14 au 20 septembre 2026, affichée à l’écran. Une erreur réelle ne déclenche jamais la démo.

## Connecter l’iPhone une seule fois

1. Ouvre le nouveau paquet local `NativeApp/dist/GameMetrik Native.app` sur le Mac et déverrouille-le.
2. Vérifie que ton organisation est sélectionnée. Dans **Réglages → Connexions → Connecter mon iPhone…**, prépare le transfert.
3. Enregistre le fichier `.gmconnection`, puis envoie-le à ton iPhone, par exemple par AirDrop. Le code de transfert doit voyager séparément.
4. Dans GameMetrik sur l’iPhone, choisis **Connecter mon studio**, sélectionne le fichier, colle le code, confirme ton usage personnel et valide Face ID ou le code de l’iPhone.
5. Appuie sur **Synchroniser** dans Studio. Ouvre ensuite un jeu et synchronise pour lire ses joueurs ou Ballpark.
6. Supprime le fichier de transfert et son code après l’import.

Le transfert reprend **l’identité administrateur du propriétaire**, pas un compte membre Firebase. Il ne réduit pas les droits des clés existantes. Il est réservé à ton iPhone personnel ; ne distribue pas le fichier et son code. Le fichier utilise AES-256-GCM avec une clé aléatoire séparée de 256 bits et une validité de 10 minutes à l’import. Le code est lu en scannant le QR code affiché par le Mac, sans passer par le presse-papiers, et le Mac redemande Touch ID ou le mot de passe avant de préparer le transfert. L’expiration est vérifiée par le client : ce n’est ni une révocation distante des clés ni une garantie contre un destinataire disposant du fichier et du code. Pour révoquer un téléphone compromis, révoque/renouvelle les clés chez les fournisseurs.

Le trousseau iOS utilise `WhenPasscodeSetThisDeviceOnly` et `userPresence`, sans synchronisation iCloud. Un code de verrouillage iPhone est nécessaire. Les fenêtres sont masquées lors d’une interruption avant la capture du sélecteur d’apps ; le passage en arrière-plan efface l’état en mémoire. Le cache agrégé est chiffré, exclu des sauvegardes et protégé par `NSFileProtectionComplete`. Les requêtes utilisent une session éphémère sans cache URL, cookies ou stockage d’identifiants ; les redirections sont refusées par le moteur partagé.

Références Apple : [accès au trousseau avec Face ID/Touch ID](https://developer.apple.com/documentation/localauthentication/accessing-keychain-items-with-face-id-or-touch-id), [accessibilité des éléments](https://developer.apple.com/documentation/security/restricting-keychain-item-accessibility).

## Compiler localement

Prérequis : Xcode avec un SDK iOS et XcodeGen. Depuis la racine :

```sh
./iOSApp/scripts/build.sh
```

Le projet Xcode reproductible est `iOSApp/GameMetrik.xcodeproj`, généré depuis `iOSApp/project.yml`. Le paquet de simulateur se trouve sous `iOSApp/build/Build/Products/Release-iphonesimulator/GameMetrik.app`.

Pour construire un paquet iPhone signé avec tes profils locaux, indique ton équipe Apple (`GAMEMETRIK_APPLE_TEAM=TON_EQUIPE`), sans création de profil distant :

```sh
./iOSApp/scripts/build-device.sh
```

Après branchement et déverrouillage de l’iPhone, `xcrun devicectl list devices` donne son identifiant. L’installation locale seule, sans lancement automatique, se fait avec :

```sh
./iOSApp/scripts/install.sh IDENTIFIANT_IPHONE
```

Pour utiliser Xcode, renseigne ton équipe Apple dans les réglages de signature, choisis ton iPhone comme destination puis lance Run. Le bundle est `ch.gamemetrik.ios`. Utiliser un profil iOS de développement contenant cet appareil, et activer le mode développeur de l’iPhone si demandé. Les opérations App Store/TestFlight ne font pas partie de cette version.

```sh
swift test --package-path NativeApp
xcodebuild -project iOSApp/GameMetrik.xcodeproj -scheme GameMetrik \
  -destination 'platform=iOS Simulator,id=UDID_DU_SIMULATEUR' \
  -derivedDataPath iOSApp/build -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO test
```

Les tests de transfert utilisent des clés RSA fictives créées à l’exécution. Les tests iOS parcourent exclusivement la démonstration.
