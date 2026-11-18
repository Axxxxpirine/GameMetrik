# GameMetrik

*[Version française](README.fr.md)*

GameMetrik is a native macOS app, with an iPhone companion, that brings a small game studio's numbers into one place: store sales, ad revenue, active players, gameplay and retention. It reads each provider directly from your Mac. There is no server, no account to create and no telemetry.

It was built by an indie developer for their own games, then opened up. Read the next section before you plan to use it for yours.

## What to expect

- **The interface is in French.** So are the in-depth guides. This README and the code comments are in English.
- **A demonstration mode ships with the app.** It shows every screen with fictitious data, and you can build it without an Apple developer account.
- **The generic parts work for any studio**: App Store Connect sales reports, Google Play reports, AdMob revenue, and a games catalogue stored in Firestore.
- **Some reports are specific to the author's two games.** They appear here under placeholder names, Aurora Grove and Ballpark, and they call analytics functions that exist only in those games' Supabase projects. Treat them as worked examples of a report contract, its validation and its display.

## What it does

- Studio overview: installs, active players, revenue per currency, with the coverage of each source shown next to the figures.
- Per-game pages: acquisition, gameplay, player journey, retention, monetization, reviews.
- Manual synchronization with an encrypted local cache, so days that are final are not fetched twice.
- CSV export, and an optional folder of aggregated tables meant to be read by an AI assistant.
- Missing data stays missing: a source that failed is shown as unavailable, never as zero, and currencies are not added together.

## Try the demonstration

You need a Mac with macOS 14 or later and Xcode 16 or later (Swift 6).

```sh
git clone https://github.com/Axxxxpirine/GameMetrik.git
cd GameMetrik
GAMEMETRIK_DEMO_BUILD=1 ./NativeApp/scripts/build.sh
open "NativeApp/dist/GameMetrik Demo.app"
```

Click **Déverrouiller** and confirm with Touch ID or your Mac password. The app opens on the demonstration data.

The demonstration build is signed ad hoc, for your Mac only. It has no keychain group, so it cannot store connections: it shows fictitious data and nothing else.

## Build it for your own data

Real connections are stored in the Data Protection keychain, in a group that macOS grants only to an app signed with a provisioning profile. You therefore need:

1. An Apple Developer membership.
2. An App ID `ch.gamemetrik.native` in your team (or your own identifier, replaced throughout the sources), with a macOS provisioning profile that includes its keychain access group.
3. The signing identity in your keychain.

```sh
./NativeApp/scripts/build.sh
```

The script finds a matching identity and profile on its own. To pick them explicitly, set `GAMEMETRIK_SIGNING_IDENTITY` and `GAMEMETRIK_SIGNING_PROFILE`. It never falls back to an ad-hoc signature unless you ask for the demonstration build.

Then follow the connection guide: [NativeApp/CONNEXION.md](NativeApp/CONNEXION.md) (in French).

## Tests

```sh
swift test --package-path NativeApp
```

The tests use synthetic fixtures and keys generated at run time. They make no network calls.

## iPhone app

[iOSApp/](iOSApp/README.md) is a SwiftUI client that shares the same `GameMetrikCore` module. It receives its connections from the Mac through an encrypted, short-lived transfer file. Set your own Apple team before building for a device.

## Security and privacy

- Credentials live in the keychain of your device, protected by Touch ID, Face ID or your password. They are never written to the app bundle, the preferences or the logs.
- The app starts locked, and locks again on sleep, on screen lock and after five minutes without activity.
- The app runs in the App Sandbox with the Hardened Runtime. Its only network traffic goes to the providers you connect.
- Raw game sessions and player profiles are kept in memory only. The cache on disk holds aggregates, encrypted with AES-256-GCM.

Details are in [NativeApp/SECURITE.md](NativeApp/SECURITE.md) (in French). To report a vulnerability, see [SECURITY.md](SECURITY.md).

## Layout

| Path | Content |
| --- | --- |
| `NativeApp/Sources/GameMetrikCore` | Models, provider clients, report contracts, aggregation, exports. No UI. |
| `NativeApp/Sources/GameMetrikNative` | The macOS app: SwiftUI views, app state, keychain vault. |
| `NativeApp/Tests` | Unit and integration tests with synthetic fixtures. |
| `NativeApp/scripts` | Build, packaging and notarization scripts. |
| `iOSApp` | The iPhone client. |

`NativeApp` has no dependency outside the Apple SDKs: no Node, no web view, no local server.

## License

[MIT](LICENSE). GameMetrik is an independent project. It is not affiliated with Apple, Google, Firebase, AdMob or Supabase.
