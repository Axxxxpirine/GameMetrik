# Aurora Grove sur iOS — version 0.4.2

Aurora Grove est publié uniquement sur iOS, selon la confirmation du propriétaire du 7 septembre 2026. Google Play est désactivé par défaut pour ce jeu dans **Réglages → Connexions → Sources attendues par jeu**. Le paramètre est local au Mac et peut être activé lors d’une sortie Android ; aucun document Firestore n’est modifié. Les rapports financiers attendus pour ce jeu sont Apple et AdMob.

Pour retrouver la clé Apple existante, rechercher le fichier `AuthKey_XXXXXXXXXX.p8` sur le Mac ou dans une sauvegarde. App Store Connect ne propose qu’un téléchargement de chaque clé. Si une nouvelle clé est nécessaire : **Utilisateurs et accès → Intégrations → App Store Connect API → Clés d’équipe**, créer une clé autorisée à lire les rapports de ventes et télécharger son `.p8`. Les clés individuelles ne donnent pas accès aux rapports Sales and Finance.

Dans GameMetrik : **Réglages → Connexions → Rapports des boutiques**, saisir l’Issuer ID et le Key ID de la clé d’équipe et le numéro vendeur, puis enregistrer. Ensuite, utiliser **Choisir la clé Apple (.p8)…**. Modifier l’Issuer ID ou le Key ID retire la clé privée précédente de la configuration active ; elle ne sera pas utilisée avec une autre identité. Actualiser Aurora Grove sur 30 jours pour vérifier la lecture Apple.

---

# Synchroniser les indicateurs — version 0.4

Si tes connexions sont déjà dans le trousseau, **ne réimporte pas le dossier web nettoyé**. Ouvre l’app, déverrouille-la, sélectionne **Vue d’ensemble → Aurora Grove → 30 jours**, puis **Actualiser**. La collecte native remplace la lecture des anciens bilans dans le mode personnel.

L’état de chaque fournisseur apparaît sous le graphique. AdMob récupère toute la période sélectionnée, Apple demande les rapports journaliers disponibles et Google Play récupère les exports mensuels d’installations et de recettes, corrections comprises. Les fichiers et données joueurs restent en mémoire. Aucun schéma ou document distant n’est modifié.

Pour compléter une source : **Réglages → Connexions → Choisir la clé Apple (.p8)…**, puis **Rapports des boutiques** pour le numéro vendeur Apple et le bucket Google Play (`pubsite_prod_rev_…`). Enregistre les paramètres et actualise. Le compte de service Google doit disposer des droits de lecture des rapports statistiques/financiers dans Play Console ; l’accès au catalogue Reporting seul ne suffit pas.

Un rapport non publié ou une source refusée reste manquant, même après la collecte. Les devises différentes ne sont pas additionnées. Les indicateurs joueurs reposent sur les parties terminées, pas les simples ouvertures du jeu. Le retour J7 utilise la première partie observée dans l’historique conservé, pas une date d’installation.

---

# Connexions protégées — version 0.3

À l’ouverture, cliquer **Déverrouiller** et valider Touch ID ou l’authentification macOS. La première ouverture migre les connexions existantes dans le trousseau Data Protection isolé de l’app, puis supprime les anciennes entrées seulement après comparaison des copies. Une demande d’accès à l’ancienne entrée GameMetrik peut apparaître pendant cette migration.

**⌘⇧L** verrouille l’app immédiatement. Le verrouillage est aussi automatique à la veille, au verrouillage du Mac et après cinq minutes sans activité dans l’app. Il faut ensuite s’authentifier à nouveau ; aucune connexion n’est chargée au démarrage avant cette étape.

**Réglages → Connexions → Sécuriser les fichiers d’origine…** sauvegarde les fichiers en clair dans le trousseau protégé, vérifie la sauvegarde, puis remplace la configuration web par une démo sans identifiants et retire les fichiers de clés référencés. L’ancienne web app perd alors ses accès de production. Chaque fichier extérieur au dossier choisi nécessite une autorisation de fichier macOS distincte. Aucun secret de récupération n’est écrit sur disque.

L’app est isolée par App Sandbox et Hardened Runtime. Le groupe du trousseau est imposé par la signature Apple. La présence de secrets en mémoire pendant une consultation reste nécessaire ; le verrouillage annule les opérations et retire ces données de l’état de l’app, sans garantie d’effacement physique de toutes les copies temporaires de Swift.

Voir **SECURITE.md** et **VALIDATION.md** dans le projet pour les détails et le statut de notarisation.

---

# Connecter GameMetrik Native

## Administration personnelle

Ce mode reprend les connexions du propriétaire de la web app. Aucun nouveau client Apple Firebase ni connexion Google interactive n’est nécessaire.

1. Ouvrir `dist/GameMetrik Native.app` puis **Réglages → Connexions**.
2. Cliquer **Importer les connexions existantes…** et choisir `/chemin/vers/GameMetrik`, qui contient `.env.local`.
3. Les identifiants sont lus une fois et copiés dans le **trousseau macOS**, accessible seulement sur ce Mac déverrouillé. Le dossier original n’est pas modifié. La bibliothèque réelle s’ouvre automatiquement.
4. Si plusieurs organisations existent, choisir celle à consulter dans les réglages.
5. Cliquer **Vérifier les connexions** pour tester les lectures Firebase, Supabase, AdMob, Google Play et Apple indépendamment. Le résultat indique précisément l’accès testé, pas une synchronisation complète.

L’app retrouve le compte Google JSON pointé par `GOOGLE_APPLICATION_CREDENTIALS` (ou les champs Firebase explicites), les projets Supabase et leurs clés, le client OAuth AdMob et son jeton de renouvellement, les références Apple et le compte Google Play. Les chemins relatifs sont résolus depuis le dossier importé. Aucun script `.env` n’est exécuté.

Les comptes de service signent des assertions RSA via Security.framework, puis obtiennent un jeton OAuth de courte durée conservé en mémoire. Firestore applique les droits IAM du compte de service. Supabase utilise explicitement la clé administrateur du propriétaire. Ces accès sont distincts du mode membre ; les règles distantes ne sont pas modifiées.

**Après import, la lecture de Firebase/Supabase ne dépend plus des fichiers de la web app.** Le choix de l’espace personnel réel est conservé ; l’accès nécessite un nouveau déverrouillage au prochain lancement. La démo reste sélectionnable dans Général et ne remplace jamais une lecture en erreur.

Les identifiants ne sont ni intégrés au paquet `.app`, ni conservés dans les préférences publiques, ni inscrits dans les journaux. **Retirer les connexions actives de ce Mac** efface leur entrée du trousseau. Les sauvegardes de récupération créées lors du nettoyage sont conservées séparément et restent protégées par authentification. Après nettoyage, les fichiers d’origine ne sont plus disponibles pour un nouvel import. Le paquet utilise une signature Apple et un profil autorisant son groupe de trousseau ; aucun secours ad hoc n’est utilisé.

## Clé Apple manquante

La configuration d’origine référence un fichier `.p8` absent. Les autres connexions peuvent être importées malgré cette absence. Utiliser **Choisir la clé Apple (.p8)…** dans Connexions pour sélectionner la clé correspondant à l’issuer et au key ID importés. L’app valide son format P-256, la conserve dans le trousseau puis teste le catalogue App Store Connect.

## Données lues et synchronisation

- Firebase : organisations, jeux, snapshots de tableaux de bord, avis enregistrés.
- Supabase : profils, parties terminées, achats et attributions Jardin paisible. Calculs gameplay et fiches exécutés en Swift sur les données actuelles.
- AdMob : renouvellement OAuth et vérification d’accès au catalogue.
- Google Play : vérification du catalogue Play Developer Reporting. Les droits Android Publisher, ventes et rapports Cloud Storage sont distincts et ne sont pas validés par cette lecture.
- Apple : signature JWT et vérification du catalogue après import d’une clé valide.

**Actualiser** relit les données. Il ne collecte pas encore les nouveaux rapports de ventes/publicités/qualité et ne recalcule pas les snapshots fournisseurs. Leur date de calcul reste affichée. La création/modification des jeux et les collecteurs complets restent à porter avant l’abandon de la web app. Aucun service distant n’est créé, activé, modifié ou déployé.

Les requêtes réseau utilisent une session éphémère et refusent les redirections. Les profils et parties restent en mémoire. Les lectures Supabase sont paginées, annulables, limitées à 100 000 lignes par table, et dédupliquées par joueur/run. Une lecture incomplète produit une erreur.

## Compte membre — facultatif

Dans **le même projet Firebase que la web app** :

1. Ouvrir Paramètres du projet → Général → Ajouter une application → Apple (iOS).
2. Utiliser l’identifiant exact **`ch.gamemetrik.native`**. Le client Apple sert aussi à la connexion macOS ; aucun nouveau projet Firebase n’est nécessaire.
3. Vérifier que Google est activé dans Authentication → Fournisseurs de connexion, puis télécharger **GoogleService-Info.plist**. Il doit contenir `CLIENT_ID`, `REVERSED_CLIENT_ID`, `API_KEY`, `PROJECT_ID` et `BUNDLE_ID`.
4. Dans GameMetrik Native : **⌘, → Compte membre → Importer GoogleService-Info.plist…**.
5. Si ton compte appartient à plusieurs organisations, renseigner l’identifiant du document Firestore de l’organisation et cliquer sur Enregistrer l’organisation.
6. Cliquer sur **Continuer avec Google** puis choisir un compte membre du studio. La fenêtre sécurisée de macOS traite le retour OAuth ; aucun port local n’est ouvert.

La session Firebase est conservée dans le trousseau de ce Mac, sans synchronisation iCloud. L’app vérifie `/users/{uid}` et `/organizations/{org}/members/{uid}` avant de lire le catalogue et les tableaux. Les règles Firestore existantes restent appliquées. Se déconnecter efface les jetons du trousseau et les données en mémoire.

Le paramètre `requestUri: http://localhost` de l’échange REST Firebase est une valeur de contexte documentée ; ce code ne crée aucun serveur et n’envoie aucune requête à localhost.


Le mode membre utilise les clés publiques Supabase `sb_publishable_…` et le JWT Firebase. Il nécessite une intégration Third-party Auth Firebase et des règles RLS autorisant les administrateurs du studio à lire les tables nécessaires. Ce mode est facultatif pour l’usage personnel actuel et ses accès de production n’ont pas été testés. Les configurations publiques JSON s’importent dans l’onglet Compte membre ; les clés administrateur y restent refusées.

## Références techniques

- [Firestore REST : identité Firebase ou OAuth/IAM](https://firebase.google.com/docs/firestore/use-rest-api)
- [Google : authentification des comptes de service](https://developers.google.com/identity/protocols/oauth2/service-account)
- [AdMob : lecture du catalogue](https://developers.google.com/admob/api/reference/rest/v1/accounts.apps/list)
- [Google Play : catalogue Reporting](https://developers.google.com/play/developer/reporting/reference/rest/v1beta1/apps/search)
- [Apple : jetons JWT](https://developer.apple.com/documentation/appstoreconnectapi/generating-tokens-for-api-requests)

### Remplacer une clé Apple (0.4.3)

Dans Connexions → Rapports des boutiques, renseigner l’Issuer ID de l’équipe et le numéro vendeur. Cliquer sur **Choisir la clé Apple (.p8)…** et sélectionner le fichier téléchargé depuis App Store Connect : le nom officiel `AuthKey_<ID>.p8` remplace automatiquement l’ancien Key ID. L’import enregistre aussi les champs Apple saisis, puis vérifie l’accès au catalogue. Si le fichier a été renommé, renseigner le Key ID avant l’import. Actualiser ensuite la Vue d’ensemble pour vérifier les rapports de ventes.
