import Foundation
import Security

/// One aggregated export kept up to date in the AI folder, described in index.json and AGENTS.md.
public struct AIFolderSnapshot: Codable, Sendable, Equatable {
    public var path: String
    public var demo: Bool
    public var workspace: String
    public var gameID: String?
    public var gameName: String
    public var timeframe: String
    public var timeframeLabel: String
    public var synchronizedAt: String
    public var tables: [String]
    /// Availability checks other than loaded, cached or structurally not collected, as "section [status]".
    public var limits: [String]
}

public struct AIFolderIndex: Codable, Sendable {
    public var schemaVersion = 1
    public var updatedAt: String
    public var snapshots: [AIFolderSnapshot]
}

/// Progress of a synchronization requested by an assistant, written to synchronisation.json.
public struct AISyncStatus: Codable, Sendable, Equatable {
    public struct Step: Codable, Sendable, Equatable {
        public var game: String
        public var timeframe: String
        public var status: String
        public var detail: String
        public init(game: String, timeframe: String, status: String, detail: String) {
            self.game = game; self.timeframe = timeframe; self.status = status; self.detail = detail
        }
    }
    /// en_cours, terminee, partielle, echec or refusee.
    public var state: String
    public var request: String
    public var startedAt: String
    public var finishedAt: String?
    public var message: String
    public var steps: [Step]
    public init(state: String, request: String, startedAt: String, finishedAt: String? = nil, message: String, steps: [Step] = []) {
        self.state = state; self.request = request; self.startedAt = startedAt; self.finishedAt = finishedAt; self.message = message; self.steps = steps
    }
}

/// A plain folder that Claude, Codex or any assistant can read without credentials or network access.
/// It only receives aggregated exports: no player-level tables, raw games, identifiers or secrets.
public struct AIFolder: Sendable {
    public static let folderName = "GameMetrik IA"
    public static let playerTables: Set<String> = ["joueurs", "joueurs_heures", "joueurs_historique", "joueurs_modes", "joueurs_difficultes"]
    /// Every name the app creates at the root. Removal never touches anything else in the folder.
    static let managedNames = ["AGENTS.md", "CLAUDE.md", "index.json", "donnees", "demonstration", tokenName, scriptName, "synchronisation.json"]
    /// Written with the token: asks the app to synchronize, then waits for synchronisation.json.
    public static let scriptName = "actualiser.sh"
    /// Shared secret proving that a synchronization request comes from a local process able to read this folder,
    /// never from a web page opening the app's URL.
    public static let tokenName = ".jeton-synchronisation"
    public let root: URL
    public init(root: URL) { self.root = root }

    /// A folder already named "GameMetrik IA" is used as is; otherwise the AI folder is created inside the chosen one.
    public static func root(forChosen url: URL) -> URL {
        url.lastPathComponent == folderName ? url : url.appendingPathComponent(folderName, isDirectory: true)
    }

    public static func slug(_ value: String) -> String {
        let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr")).lowercased()
        let slug = folded.replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "jeu" : String(slug.prefix(50))
    }

    public static func relativePath(gameSlug: String?, timeframe: Timeframe, demo: Bool) -> String {
        (demo ? "demonstration" : "donnees") + "/" + (gameSlug.map(slug) ?? "studio") + "/" + timeframe.rawValue
    }

    /// Replaces the snapshot for this game, period and mode, then rewrites index.json and the reading guides.
    @discardableResult
    public func write(_ export: DataExport, gameSlug: String?, timeframe: Timeframe, demo: Bool, now: Date = Date()) throws -> AIFolderSnapshot {
        var export = export
        export.tables.removeAll { Self.playerTables.contains($0.id) }
        export.notes.append("Copie automatique pour le dossier IA : statistiques agrégées uniquement, sans tableau par joueur.")
        let wrapper = try export.fileWrapper()
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = Self.relativePath(gameSlug: gameSlug, timeframe: timeframe, demo: demo)
        let destination = root.appendingPathComponent(path, isDirectory: true)
        let staging = root.appendingPathComponent(".ecriture-" + UUID().uuidString, isDirectory: true)
        defer { try? manager.removeItem(at: staging) }
        try wrapper.write(to: staging, options: .atomic, originalContentsURL: nil)
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: staging)
        } else {
            try manager.moveItem(at: staging, to: destination)
        }
        let snapshot = AIFolderSnapshot(
            path: path, demo: demo, workspace: export.mode, gameID: export.gameID, gameName: export.gameName,
            timeframe: timeframe.rawValue, timeframeLabel: timeframe.label, synchronizedAt: Dates.iso(now),
            tables: export.tables.map(\.id),
            limits: export.checks.filter { !["loaded", "cached", "not_collected"].contains($0.status) }.map { $0.section + " [" + $0.status + "]" })
        var snapshots = (try? readIndex())?.snapshots ?? []
        snapshots.removeAll { $0.path == path || !manager.fileExists(atPath: root.appendingPathComponent($0.path).path) }
        snapshots.append(snapshot)
        snapshots.sort { ($0.demo ? 1 : 0, $0.gameName, $0.timeframe) < ($1.demo ? 1 : 0, $1.gameName, $1.timeframe) }
        let index = AIFolderIndex(updatedAt: Dates.iso(now), snapshots: snapshots)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(index).write(to: root.appendingPathComponent("index.json"), options: .atomic)
        try Data(Self.guide(index).utf8).write(to: root.appendingPathComponent("AGENTS.md"), options: .atomic)
        try Data(Self.claudeGuide.utf8).write(to: root.appendingPathComponent("CLAUDE.md"), options: .atomic)
        return snapshot
    }

    public func writeToken(_ token: String, appPath: String) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = root.appendingPathComponent(Self.tokenName)
        try Data(token.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try updateRefreshScript(appPath: appPath)
    }

    /// Upgrades an already enabled trigger after an app update or move, without reading its token.
    public func updateRefreshScript(appPath: String) throws {
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(Self.tokenName).path) else { return }
        let script = root.appendingPathComponent(Self.scriptName)
        try Data(Self.refreshScript(appPath: appPath).utf8).write(to: script, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    }

    public func removeToken() throws {
        for name in [Self.tokenName, Self.scriptName] {
            let url = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }

    static func refreshScript(appPath: String) -> String {
        let app = "'" + appPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return #"""
        #!/bin/bash
        # Généré par GameMetrik Native. Demande à l'app de synchroniser, puis attend la fin (9 minutes au plus).
        # Usage : actualiser.sh [jeu|tous] [périodes]   ex. actualiser.sh aurora-grove 7d,30d,90d
        #         actualiser.sh --attendre <demande>     reprend l'attente d'une demande déjà envoyée
        # Codes : 0 fini (voir "state" : terminee, partielle, echec, refusee), 2 non activé, 3 toujours en cours.
        set -u
        DIR="$(cd "$(dirname "$0")" && pwd)"
        APP=\#(app)
        STATUS="$DIR/synchronisation.json"
        TOKEN_FILE="$DIR/.jeton-synchronisation"
        send() {
          # A moved app is resolved by its registered bundle ID, without activating it.
          local target=(-b ch.gamemetrik.native)
          if [ -d "$APP" ]; then target=(-a "$APP"); fi
          open -g "${target[@]}" "gamemetrik-native://synchroniser?jeton=$(cat "$TOKEN_FILE")&jeu=$GAME&periodes=$PERIODS&demande=$REQ"
        }
        if [ "${1:-}" = "--attendre" ]; then
          REQ="${2:?demande manquante}"; GAME=""; PERIODS=""
        else
          if [ ! -r "$TOKEN_FILE" ]; then
            echo "Synchronisation par l'IA non activée. Dans GameMetrik Native : Réglages → Général → Dossier pour l'IA → « Autoriser Claude ou Codex à synchroniser sans Touch ID »."
            exit 2
          fi
          GAME="${1:-tous}"; PERIODS="${2:-7d,30d,90d}"
          case "$GAME$PERIODS" in *[!A-Za-z0-9_,-]*) echo "Jeu ou périodes invalides."; exit 1;; esac
          REQ="ia-$(date +%Y%m%d-%H%M%S)-$RANDOM"
          send || { echo "Impossible d'ouvrir $APP"; exit 1; }
        fi
        read_status() {
          /usr/bin/python3 -I - "$STATUS" "$REQ" <<'PY'
        import json, sys
        try: s = json.load(open(sys.argv[1]))
        except Exception: print("none"); sys.exit()
        if s.get("request") == sys.argv[2]: print("mine " + s.get("state", ""))
        else: print("other-running" if s.get("state") == "en_cours" else "other-done")
        PY
        }
        resent=0
        for i in $(seq 1 108); do
          sleep 5
          case "$(read_status)" in
            "mine en_cours"|other-running) ;;
            mine*) /usr/bin/python3 -I -m json.tool "$STATUS"; exit 0 ;;
            *) # Demande arrivée pendant le démarrage de l'app ou la fin d'une autre : la renvoyer une fois.
               if [ -n "$GAME" ] && [ "$i" -ge 4 ] && [ "$resent" -eq 0 ]; then send; resent=1; fi ;;
          esac
        done
        echo "Toujours en cours après 9 minutes. Reprendre l'attente avec : "$0" --attendre $REQ"
        exit 3

        """#
    }

    public func writeStatus(_ status: AISyncStatus) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(status).write(to: root.appendingPathComponent("synchronisation.json"), options: .atomic)
    }

    public func readIndex() throws -> AIFolderIndex {
        try JSONDecoder().decode(AIFolderIndex.self, from: Data(contentsOf: root.appendingPathComponent("index.json")))
    }

    /// Deletes only what the app wrote, then the folder itself if nothing else remains in it.
    public func removeContents() throws {
        let manager = FileManager.default
        for name in Self.managedNames {
            let url = root.appendingPathComponent(name)
            if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
        }
        for name in (try? manager.contentsOfDirectory(atPath: root.path)) ?? [] where name.hasPrefix(".ecriture-") {
            try? manager.removeItem(at: root.appendingPathComponent(name))
        }
        if (try? manager.contentsOfDirectory(atPath: root.path))?.allSatisfy({ $0 == ".DS_Store" }) == true {
            try manager.removeItem(at: root)
        }
    }

    static let claudeGuide = """
    @AGENTS.md

    Fichier généré par GameMetrik Native. Le guide complet et la liste des données à jour sont dans AGENTS.md.

    """

    static func guide(_ index: AIFolderIndex) -> String {
        func line(_ s: AIFolderSnapshot) -> String {
            "| \(s.gameName) | \(s.timeframeLabel) (`\(s.timeframe)`) | \(s.synchronizedAt) | \(s.workspace) | `\(s.path)/` | "
                + (s.limits.isEmpty ? "aucune" : s.limits.joined(separator: " ; ")) + " |"
        }
        let live = index.snapshots.filter { !$0.demo }, demo = index.snapshots.filter(\.demo)
        let header = "| Jeu | Période | Synchronisé le | Espace | Dossier | Limites signalées |\n|---|---|---|---|---|---|"
        return """
        # Données GameMetrik pour l’analyse par IA

        Ce dossier est mis à jour automatiquement par l’app Mac **GameMetrik Native** après chaque synchronisation réussie. Fichier généré : ne pas le modifier, il est réécrit à la prochaine synchronisation.

        Tu es en **lecture seule**. N’essaie pas de contacter les fournisseurs (AdMob, App Store Connect, Google Play, Firebase, Supabase) ni de chercher des identifiants : ce dossier n’en contient aucun et n’en a pas besoin. Les données ne deviennent plus récentes que par une synchronisation de l’app Mac.

        **Actualiser :** si `actualiser.sh` existe dans ce dossier, lance-le avant d’analyser (`./actualiser.sh <jeu ou tous> 7d,30d,90d`, délai de 10 minutes) : l’app synchronise elle-même puis met ce dossier à jour. Code 3 : relance `./actualiser.sh --attendre <demande>`. N’ouvre jamais `.jeton-synchronisation` et ne recopie jamais son contenu. Sans ce script, la synchronisation par l’IA n’est pas activée : demande au propriétaire de synchroniser dans l’app.

        Dernière mise à jour du dossier : \(index.updatedAt)

        ## Données disponibles

        \(live.isEmpty ? "Aucune donnée réelle pour l’instant. Demande au propriétaire de synchroniser un jeu dans GameMetrik." : header + "\n" + live.map(line).joined(separator: "\n"))
        \(demo.isEmpty ? "" : "\n### Démonstration (données fictives)\n\nLe dossier `demonstration/` contient des chiffres inventés pour tester l’app. Ne l’analyse que si on te le demande explicitement, et ne le mélange jamais avec `donnees/`.\n\n" + header + "\n" + demo.map(line).joined(separator: "\n"))

        `index.json` contient la même liste sous forme structurée (`snapshots[]` : `path`, `gameID`, `timeframe`, `synchronizedAt`, `tables`, `limits`).

        ## Méthode

        1. Lis `index.json` : il y a au plus un instantané par jeu et par période, toujours le dernier synchronisé. Utilise chaque période pour ce qu’elle montre. Indique toujours sa date de synchronisation ; au-delà de 2 jours, signale que les données sont anciennes et propose au propriétaire de synchroniser.
        2. Dans le dossier de l’instantané, lis d’abord `LIRE-MOI.md` (définitions, unités, limites) puis `export_bilan.csv` (disponibilité de chaque rubrique). N’affirme rien sur une rubrique `partial`, `failed`, `not_loaded`, `not_collected` ou `not_connected` sans le préciser.
        3. Utilise `rapport.json` pour les types et le contexte (fuseau, devise, date de génération de chaque tableau) ; les CSV contiennent les mêmes lignes.
        4. Pour une tendance, compare des périodes de même longueur. Les périodes plus longues (`90d`, `1y`) servent au contexte, les plus courtes (`today`, `7d`) aux derniers jours.

        ## Règles de lecture

        - Une valeur vide ou `null` est **inconnue**, pas zéro. Un vrai zéro est écrit `0`.
        - La journée en cours et les derniers jours sont provisoires : les fournisseurs publient avec retard (`pending` dans `studio_jours_sources`).
        - Les devises ne sont jamais additionnées entre elles, y compris dans `monetisation_*` (montant = `value_micros` / 1 000 000 dans sa devise). Les montants d’origine sont dans `studio_indicateurs_devises` et `studio_historique_devises` ; une colonne CHF vide signifie qu’une conversion aurait été nécessaire.
        - Pourcentages génériques en points (25 = 25 %), durées en minutes. Exception : les taux `ballpark_*`, `parcours_*` et `monetisation_test` sont des fractions (0,25 = 25 %), et les durées `collecte_*` sont en secondes.
        - Le retour J7 de Gameplay compte les joueurs revenus sept jours après leur première partie **observée**, ce n’est pas la rétention depuis l’installation. Pour Aurora Grove, la plupart des joueurs jouent sans compte : utilise les tableaux `parcours_*` pour les nouvelles installations et les retours.
        - Les cohortes immatures (`immature_cohort`) sont exclues des totaux : ne les interprète pas comme des chutes.
        - Aucune donnée par joueur, aucune partie brute et aucun identifiant ne figure ici, par conception. Ne cherche pas à identifier un joueur à partir des avis ou des agrégats.
        - L’attribution des campagnes n’est pas collectée : aucune jointure campagne → joueur → revenu n’est possible.
        - Les requêtes SQL et vérifications décrites dans les LIRE-MOI sont réservées au propriétaire : ne les exécute pas.
        - Une source attendue absente d’un instantané (par exemple Google Play pour un jeu Android) est inconnue, pas nulle.

        ## Tableaux principaux

        - `studio_indicateurs` : indicateurs de la vue d’ensemble avec couverture (`available_days` / `expected_days`) et définition.
        - `studio_historique` : série quotidienne (revenus CHF, joueurs actifs, installations, nouveaux joueurs).
        - `studio_jours_sources` : réception de chaque source par jour (`received`, `cached`, `pending`, `missing`).
        - `studio_revenus_detail`, `studio_pays`, `studio_plateformes` : revenus par pays et plateforme, en devise d’origine.
        - `studio_jeux` : contribution de chaque jeu (instantané « Tout le studio »).
        - `gameplay_*` : activité, modes, difficultés, groupes d’activité, heures de fin de partie.
        - `avis` : avis des boutiques déjà lus dans GameMetrik (toutes dates).
        - `parcours_*` : Aurora Grove, entonnoir J0–J6, étapes anonymes, retours, issues des parties, qualité de collecte. Après la 1.5.1, `consent_accepted` / `consent_declined` ne sont plus alimentés (`consent_signals` = `not_fed`, cellules vides) : ni refus ni acceptations, aucun taux d’acceptation.
        - `monetisation_*` : Aurora Grove, publicité mesurée par les installations autorisées à être mesurées : occasions et motifs de non-affichage (`monetisation_pubs`, `monetisation_pubs_motifs`), revenus OnAdPaid en micros par devise et précision (`monetisation_revenus`), chargements et codes d’erreur Google (`monetisation_chargements*`), étapes de l’offre Jardin paisible (`monetisation_paisible`), test des publicités des Chemins (`monetisation_test*`), couverture (`monetisation_couverture`). Ce revenu est un échantillon, distinct du revenu total AdMob (qui fait foi) ; ne jamais additionner deux devises ; aucune attribution aux campagnes Meta ; les installations sont distinctes par ligne, pas des joueurs uniques. La règle de collecte a changé avec le build qui envoie ces mesures : comparer version par version, jamais avant/après en bloc.
        - `collecte_*` : Aurora Grove 1.6.0+, collecte complète en agrégats : fréquentation (DAU/WAU/MAU, `collecte_frequentation`), présence en direct, par jour et par heure (`collecte_presence_*`), sessions, écrans, fenêtres, actions, parties et chronologies des coups, progression, réglages, rappels, stabilité et erreurs, performance, réseau, serveur, confidentialité, accords et contexte des appareils, couverture (`collecte_couverture`). Durées en **secondes** (`*_ms` en millisecondes, `*_ds` en dixièmes de seconde) ; `null` = inconnu ou masqué (`suppressed` : groupe archivé de moins de 5 installations), jamais zéro ; une période avant la collecte est `not_collected`. Les installations ne sont pas des personnes et ne s’additionnent pas entre lignes ; production ≠ interne (TestFlight, développement) ; seules les installations dont les statistiques couvrent la collecte étendue sont comptées.
        - `ballpark_*` : Ballpark, aperçu, questions, séries, habitudes, qualité technique.
        - `catalogue` : jeux, statuts, plateformes et versions actuelles.

        ## Réponse attendue

        Cite les tableaux et les dates utilisés, distingue les faits mesurés des hypothèses, et termine par les limites de données qui pourraient changer la conclusion.

        """
    }
}

/// gamemetrik-native://synchroniser?jeton=…&jeu=aurora-grove&periodes=7d,30d,90d&demande=…
public struct AISyncRequest: Sendable, Equatable {
    public static let scheme = "gamemetrik-native"
    public var token: String
    /// A game id or slug, or nil for every game of the catalog.
    public var game: String?
    public var timeframes: [Timeframe]
    public var request: String

    public static func parse(_ url: URL) -> AISyncRequest? {
        guard url.scheme == scheme, url.host == "synchroniser",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let token = value("jeton"), token.count >= 32, token.count <= 128 else { return nil }
        let request = value("demande") ?? UUID().uuidString
        guard request.count <= 64, request.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        let game = value("jeu").flatMap { ["", "tous", "all"].contains($0.lowercased()) ? nil : $0 }
        if let game, game.count > 80 || !game.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) { return nil }
        // "Tout" has no provider report window; the periods stay bounded and without duplicates.
        let names = (value("periodes") ?? "7d,30d,90d").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        var timeframes: [Timeframe] = []
        for name in names {
            guard let timeframe = Timeframe(rawValue: name), timeframe != .all else { return nil }
            if !timeframes.contains(timeframe) { timeframes.append(timeframe) }
        }
        guard !timeframes.isEmpty else { return nil }
        return AISyncRequest(token: token, game: game, timeframes: timeframes, request: request)
    }

    /// Constant-time comparison: the token must not leak through response timing.
    public func matches(_ expected: String) -> Bool {
        let a = Array(token.utf8), b = Array(expected.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    public static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return (0..<4).map { _ in UUID().uuidString.replacingOccurrences(of: "-", with: "") }.joined()
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
