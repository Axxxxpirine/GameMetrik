import SwiftUI
import GameMetrikCore

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var showingMobileTransfer = false
    @State private var ballparkAdminSecret = ""
    @State private var confirmingCacheReset = false
    @State private var confirmingReimport = false
    @State private var confirmingCleanup = false
    @State private var confirmingRemoval = false
    @State private var confirmingAIFolderRemoval = false
    var body: some View {
        TabView {
            Form {
                Section("Espace de travail") {
                    Picker("Données", selection: Binding(get: { state.demo }, set: { state.setMode($0) })) {
                        Text("Démonstration").tag(true)
                        Text("Espace réel").tag(false)
                    }.pickerStyle(.segmented)
                    Text(state.demo ? "La démonstration est disponible hors ligne. Tous ses jeux et joueurs sont fictifs." : "Les données sont lues directement depuis les services de ton espace. Une connexion Internet et un compte autorisé sont nécessaires.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Section("Protection") {
                    LabeledContent("Déverrouillage", value: "Touch ID ou mot de passe macOS")
                    LabeledContent("Verrouillage automatique", value: "Veille, verrouillage du Mac, 5 minutes")
                    Button("Verrouiller maintenant") { state.lock() }
                }
                Section("Cache des statistiques") {
                    Text("Totaux et graphiques conservés localement sous chiffrement. Affichage immédiat depuis le cache. Synchroniser (⌘R) actualise uniquement le jeu sélectionné et ses rubriques sur la période choisie. Avec Tout le studio, seule la vue agrégée est actualisée. Les profils joueurs et parties brutes restent uniquement en mémoire.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Vider le cache des statistiques…") { confirmingCacheReset = true }.disabled(state.isLocked)
                        .confirmationDialog("Vider le cache des statistiques ?", isPresented: $confirmingCacheReset, titleVisibility: .visible) {
                            Button("Vider le cache", role: .destructive) { state.clearAggregateCache() }
                        } message: {
                            Text("Les totaux et rapports conservés sur ce Mac seront supprimés, pour tous les jeux. La prochaine synchronisation devra relire chaque journée auprès des fournisseurs, ce qui peut prendre plusieurs minutes. Aucune donnée distante n’est modifiée.")
                        }
                    if let message = state.settingsMessage, message.localizedCaseInsensitiveContains("cache") {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Dossier pour l’IA") {
                    Text("Après chaque synchronisation réussie, GameMetrik écrit les statistiques agrégées du jeu et de la période dans un dossier que Claude ou Codex peuvent lire, avec leur guide de lecture (AGENTS.md). Ni identifiants, ni profils joueurs, ni parties brutes. Ces fichiers ne sont pas chiffrés.")
                        .font(.callout).foregroundStyle(.secondary)
                    if let path = state.aiFolderPath {
                        LabeledContent("Dossier") { Text(path).font(.caption.monospaced()).textSelection(.enabled).lineLimit(2).truncationMode(.middle) }
                        HStack {
                            Button("Afficher dans le Finder") { state.revealAIFolder() }
                            Button("Changer de dossier…") { state.chooseAIFolder() }
                            Spacer()
                            Button("Désactiver…") { confirmingAIFolderRemoval = true }
                                .confirmationDialog("Désactiver le dossier pour l’IA ?", isPresented: $confirmingAIFolderRemoval, titleVisibility: .visible) {
                                    Button("Désactiver et supprimer les données", role: .destructive) { state.disableAIFolder(removeContents: true) }
                                    Button("Désactiver et conserver les fichiers") { state.disableAIFolder(removeContents: false) }
                                } message: {
                                    Text("Les synchronisations suivantes n’écriront plus dans ce dossier. La suppression retire uniquement les fichiers créés par GameMetrik (AGENTS.md, CLAUDE.md, index.json, donnees et demonstration).")
                                }
                        }
                        Toggle("Autoriser Claude ou Codex à synchroniser sans Touch ID", isOn: Binding(get: { state.aiSyncEnabled }, set: { enabled in
                            if enabled {
                                Task { @MainActor in
                                    do { try await state.enableAISync(); state.aiFolderMessage = "Synchronisation par l’IA activée." }
                                    catch { state.aiFolderMessage = error.localizedDescription }
                                }
                            } else { state.disableAISync(); state.aiFolderMessage = "Synchronisation par l’IA désactivée ; sa copie des connexions est retirée du trousseau." }
                        })).disabled(state.demo || state.accessMode != "personal")
                        Text("Claude ou Codex peuvent alors lancer eux-mêmes la synchronisation, même app verrouillée, grâce à une copie des connexions gardée dans le trousseau sans Touch ID. Elle n’est lisible que par GameMetrik sur ce Mac, session ouverte. Toute personne utilisant ta session ouverte pourrait déclencher une synchronisation, sans voir les clés ni les données dans l’app.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button("Choisir le dossier…") { state.chooseAIFolder() }
                    }
                    if let message = state.aiFolderMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
                }
                Section("Apparence") {
                    Picker("Thème", selection: $state.theme) {
                        Text("Suivre macOS").tag("system"); Text("Clair").tag("light"); Text("Sombre").tag("dark")
                    }
                }
                Section("À propos") {
                    LabeledContent("Application", value: "GameMetrik Native " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "développement"))
                    LabeledContent("Interface", value: "SwiftUI · AppKit · Swift Charts")
                    LabeledContent("Stockage de la session", value: "Trousseau macOS")
                    Text("Les données individuelles des joueurs restent en mémoire pendant la consultation. Elles ne sont pas enregistrées sur le disque.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).tabItem { Label("Général", systemImage: "gearshape") }
            Form {
                Section("Administration personnelle") {
                    Text("Reprends les connexions de ta web app. L’app Mac utilise directement tes services et conserve leurs identifiants dans le trousseau macOS.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button(state.personalReady ? "Réimporter les connexions…" : "Importer les connexions existantes…") {
                        if state.personalReady { confirmingReimport = true } else { state.importPersonalConnections() }
                    }
                        .buttonStyle(.borderedProminent)
                        .confirmationDialog("Réimporter les connexions ?", isPresented: $confirmingReimport, titleVisibility: .visible) {
                            Button("Choisir le dossier…") { state.importPersonalConnections() }
                        } message: {
                            Text("Les identifiants trouvés dans le dossier remplaceront ceux du trousseau. La clé Apple, la connexion Ballpark, le numéro vendeur, le bucket et AdMob ajoutés dans GameMetrik sont conservés s’ils manquent dans le dossier. Le cache des statistiques sera reconstruit à la prochaine synchronisation.")
                        }
                    if state.personalReady {
                        LabeledContent("Projet Firebase", value: state.personalProject)
                        // Exporting the administrator keys belongs to personal administration only.
                        if state.accessMode == "personal", !state.demo {
                            Button("Connecter mon iPhone…") { showingMobileTransfer = true }
                                .disabled(state.isLocked)
                                .sheet(isPresented: $showingMobileTransfer) { MobileTransferView().environmentObject(state) }
                        }

                        if !state.personalOrganizations.isEmpty {
                            Picker("Organisation", selection: Binding(get: { state.personalOrganization }, set: { state.selectPersonalOrganization($0) })) {
                                Text("Choisir…").tag("")
                                ForEach(state.personalOrganizations) { org in Text(org.name ?? org.id).tag(org.id) }
                            }
                        }
                        HStack {
                            Button(state.checkingConnections ? "Vérification en cours…" : "Vérifier les connexions") { state.verifyPersonalConnections() }.disabled(state.checkingConnections)
                            if state.hasAppleConfiguration { Button("Choisir la clé Apple (.p8)…") { state.importAppleKey() } }
                        }
                        DisclosureGroup("Ballpark · statistiques produit") {
                            VStack(alignment: .leading, spacing: 10) {
                                Label(
                                    state.hasBallparkConnection ? "Connexion administrative enregistrée" : "Connexion administrative à ajouter",
                                    systemImage: state.hasBallparkConnection ? "checkmark.circle" : "key"
                                )
                                .foregroundStyle(state.hasBallparkConnection ? Color.metrik : .secondary)
                                Text("GameMetrik utilise une lecture agrégée réservée à l’administration personnelle. La clé reste dans le Trousseau et n’est jamais ajoutée au paquet Ballpark.")
                                    .font(.caption).foregroundStyle(.secondary)
                                SecureField(
                                    state.hasBallparkConnection ? "Remplacer la clé secrète Supabase" : "Clé secrète Supabase Ballpark",
                                    text: $ballparkAdminSecret
                                )
                                .textContentType(.password)
                                HStack {
                                    Button(state.hasBallparkConnection ? "Remplacer la connexion" : "Enregistrer la connexion") {
                                        state.saveBallparkConnection(secret: ballparkAdminSecret)
                                        ballparkAdminSecret = ""
                                    }
                                    .disabled(ballparkAdminSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                    Spacer()
                                    Text(Game.ballparkProjectRef).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }.padding(.vertical, 4)
                        }
                        if !state.connectionChecks.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(state.connectionChecks) { check in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Label(check.name, systemImage: check.success ? "checkmark.circle" : "exclamationmark.circle").foregroundStyle(check.success ? Color.metrik : Color.orange)
                                        Text(check.detail).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                if let checkedAt = state.connectionChecks.first?.checkedAt {
                                    Text("Vérifié à \(checkedAt.formatted(date: .omitted, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 4)
                        }
                        DisclosureGroup("Sources attendues par jeu") {
                            ForEach(state.games.filter { !$0.usesBallparkAnalytics }) { game in
                                Toggle("Google Play · " + game.name, isOn: Binding(get: { state.collectsGooglePlay(game) }, set: { state.setGooglePlay($0, game: game) }))
                            }
                            Text("Active Google Play uniquement pour les jeux publiés sur Android. Aurora Grove est configuré pour iOS uniquement.").font(.caption).foregroundStyle(.secondary)
                        }
                        DisclosureGroup("Rapports des boutiques") {
                            TextField("Bucket Google Play", text: $state.reportBucket, prompt: Text("pubsite_prod_rev_…"))
                            TextField("Issuer ID Apple", text: $state.appleIssuerID)
                            TextField("Key ID Apple", text: $state.appleKeyID)
                            TextField("Numéro vendeur Apple", text: $state.appleVendor)
                            Text("L’import d’un fichier AuthKey_….p8 reprend automatiquement son Key ID et l’Issuer ID saisi ici. Si le fichier a été renommé, renseigne aussi son Key ID. Changer les identifiants sans importer de fichier retire l’ancienne clé active.").font(.caption).foregroundStyle(.secondary)
                            Text("Le bucket se trouve dans Play Console → Télécharger les rapports. La clé Apple doit être ajoutée avec le bouton ci-dessus.").font(.caption).foregroundStyle(.secondary)
                            Button("Enregistrer les paramètres des rapports") { state.saveReportConfiguration() }
                        }
                        DisclosureGroup("Identifiants importés") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(state.personalSummary, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        Button("Ouvrir ma bibliothèque") { state.changeAccess("personal"); state.destination = .library; state.setMode(false); state.refresh(mode: .local) }
                    }
                    Text("Usage personnel : accès administrateur aux services. Aucun compte Apple Firebase à créer pour ce mode.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let message = state.settingsMessage { Section("État") { Text(message).textSelection(.enabled) } }
                Section("Accès actif") {
                    Picker("Connexion", selection: Binding(get: { state.accessMode }, set: { state.changeAccess($0) })) {
                        Text("Administration personnelle").tag("personal")
                        Text("Compte membre").tag("member")
                    }
                }
                if state.personalReady {
                    Section("Trousseau et fichiers d’origine") {
                        Button("Sécuriser les fichiers d’origine…") { confirmingCleanup = true }
                            .confirmationDialog("Retirer les identifiants des fichiers d’origine ?", isPresented: $confirmingCleanup, titleVisibility: .visible) {
                                Button("Choisir le dossier…", role: .destructive) { state.secureOriginalFiles() }
                            } message: {
                                Text("Après une sauvegarde vérifiée dans le trousseau, .env.local est remplacé par une configuration de démonstration et les fichiers de clés référencés sont supprimés. L’ancienne web app perd ses accès de production. Les clés ne sont pas révoquées chez les fournisseurs.")
                            }
                        Text("Sauvegarde les fichiers dans le trousseau protégé, vérifie la sauvegarde, puis retire leurs secrets en clair. L’ancienne web app perd ses accès de production.").font(.caption).foregroundStyle(.secondary)
                        Button("Retirer les connexions actives de ce Mac…", role: .destructive) { confirmingRemoval = true }
                            .confirmationDialog("Retirer les connexions actives de ce Mac ?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
                                Button("Retirer les connexions", role: .destructive) { state.forgetPersonalConnections() }
                            } message: {
                                Text("Les identifiants de l’Administration personnelle, y compris la clé Apple et la connexion Ballpark, seront effacés du trousseau et le cache des statistiques sera vidé. Les sauvegardes de récupération restent dans le trousseau. Si les fichiers d’origine ont été sécurisés, un nouvel import ne sera plus possible depuis ce dossier.")
                            }
                    }
                }
                Section("Diagnostic") {
                    Button("Analyser un dossier sans importer…") { state.inspectWebConfiguration() }
                    if let audit = state.webConfigurationAudit {
                        ForEach(audit.connections) { connection in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack { Text(connection.name).fontWeight(.medium); Spacer(); Text(connection.status).foregroundStyle(.secondary) }
                                Text(connection.detail).font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 3)
                        }
                    }
                }
            }.formStyle(.grouped).tabItem { Label("Connexions", systemImage: "key") }
            Form {
                Section {
                    Text("Configuration facultative pour un accès par compte membre. Pour ton usage personnel, utilise l’onglet Connexions.").foregroundStyle(.secondary)
                }
                Section("Compte Google et Firebase") {
                    if let config = state.config {
                        LabeledContent("Projet", value: config.projectID)
                        LabeledContent("Compte", value: state.session?.email ?? "Non connecté")
                        if let member = state.membership { LabeledContent("Rôle", value: member.role) }
                    } else {
                        Text("La connexion Google par compte membre nécessite une configuration Apple Firebase.").font(.headline)
                        Text("Dans ton projet Firebase, ajoute une application Apple avec l’identifiant ch.gamemetrik.native, active Google dans Authentication, puis télécharge GoogleService-Info.plist.")
                            .foregroundStyle(.secondary).textSelection(.enabled)
                        LabeledContent("Identifiant à utiliser") { Text("ch.gamemetrik.native").font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                    }
                    Button("Importer GoogleService-Info.plist…") { state.importFirebase() }.disabled(state.authenticating)
                    TextField("Organisation (facultatif)", text: $state.organization)
                        .help("Identifiant Firestore de l’organisation. À renseigner si ton compte appartient à plusieurs espaces.")
                        .onSubmit { state.saveOrganization() }
                    Button("Enregistrer l’organisation") { state.saveOrganization() }.disabled(state.config == nil || state.authenticating)
                    HStack {
                        Button(state.authenticating ? "Connexion en cours…" : "Continuer avec Google") { state.connect() }
                            .buttonStyle(.borderedProminent).disabled(state.config == nil || state.authenticating)
                        if state.session != nil {
                            Button("Se déconnecter") {
                                do { try state.logout(); state.settingsMessage = "Compte déconnecté et session effacée du trousseau." }
                                catch { state.settingsMessage = error.localizedDescription }
                            }
                        }
                    }
                }
                Section("Données joueurs Supabase") {
                    Text("La lecture native utilise une clé publique et le compte Firebase. Le projet Supabase doit accepter Firebase Auth et posséder des règles RLS autorisant les administrateurs du studio à lire ces tables.")
                        .font(.callout).foregroundStyle(.secondary)
                    LabeledContent("Connexions importées", value: "\(state.supabaseProjects.count)")
                    Button("Importer les connexions publiques (.json)…") { state.importSupabase() }
                    Button("Ouvrir le guide de connexion") {
                        if let url = Bundle.main.url(forResource: "CONNEXION", withExtension: "md") { NSWorkspace.shared.open(url) }
                    }
                    Text("Ce mode membre utilise uniquement les clés publiques et les autorisations du compte connecté.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let message = state.settingsMessage {
                    Section("État") { Text(message).textSelection(.enabled) }
                }
            }.formStyle(.grouped).tabItem { Label("Compte membre", systemImage: "person.crop.circle") }
        }.padding(8).frame(width: 650, height: 650)
    }
}
