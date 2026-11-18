# GameMetrik Native (macOS)

Application SwiftUI et AppKit pour macOS 14 ou ultérieur. Elle ne dépend que des SDK Apple : ni Node, ni vue web, ni serveur local.

## Compiler

```sh
# Paquet de démonstration, sans compte développeur Apple
GAMEMETRIK_DEMO_BUILD=1 ./NativeApp/scripts/build.sh

# Paquet complet, signé avec ton identité et ton profil Apple
./NativeApp/scripts/build.sh

# Tests
swift test --package-path NativeApp
```

Les paquets sont écrits dans `NativeApp/dist/`. Le paquet de démonstration s'appelle `GameMetrik Demo.app` et porte un identifiant distinct (`ch.gamemetrik.native.demo`) : il ne partage ni les préférences, ni le schéma d'URL du paquet complet.

`scripts/notarize.sh PROFIL_NOTARYTOOL` soumet un paquet signé Developer ID à la notarisation Apple. `scripts/archive.py` crée une archive Xcode locale.

## Modules

- `Sources/GameMetrikCore` : modèles, clients des fournisseurs (App Store Connect, Google Play, AdMob, Firestore, Supabase), contrats de rapports et leur validation, agrégation, cache chiffré, exports. Aucune interface, utilisable sur macOS et iOS.
- `Sources/GameMetrikNative` : l'app. `AppState.swift` porte l'état et la synchronisation, `SecureVault.swift` le trousseau et le déverrouillage, les autres fichiers sont les vues.
- `Tests/GameMetrikCoreTests` et `Tests/GameMetrikSecurityTests` : tests sur transport simulé et fixtures synthétiques.

## Guides

- [CONNEXION.md](CONNEXION.md) : connecter Firebase, Supabase, AdMob, Google Play et App Store Connect. Ce fichier est aussi embarqué dans l'app.
- [SECURITE.md](SECURITE.md) : protections en place, signature, risques résiduels.
- [SYNCHRONISATION.md](SYNCHRONISATION.md) : ce que lit chaque collecteur et comment les indicateurs sont calculés.

Ces guides sont tenus par version, la plus récente en haut. Ils mentionnent parfois des documents internes de validation qui ne sont pas publiés.
