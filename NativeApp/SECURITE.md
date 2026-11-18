# Sécurité — GameMetrik Native 0.3

## Protections mises en œuvre

L’app démarre verrouillée. Le déverrouillage passe par LocalAuthentication (Touch ID ou authentification du propriétaire proposée par macOS). Les connexions sont stockées dans le trousseau Data Protection, avec contrôle `userPresence`, protection `WhenUnlockedThisDeviceOnly` et sans synchronisation iCloud. Le groupe d’accès est limité à `YOUR_TEAM_ID.ch.gamemetrik.native`, autorisé par le profil de provisioning et la signature Apple.

La migration des anciennes entrées est déclenchée après authentification. Elle ne recherche que le service historique GameMetrik. Chaque entrée est copiée dans le nouveau trousseau, relue et comparée avant suppression de l’ancienne copie. Aucune lecture de secours des anciennes entrées ne permet de contourner l’écran de verrouillage.

Le verrouillage manuel (⌘⇧L), la veille, l’extinction des écrans, la désactivation de session et la notification de verrouillage d’écran annulent les tâches, invalident la session réseau et le contexte d’authentification, retirent les identifiants et données personnelles de l’état applicatif et invalident le cache de jetons. Les générations des opérations empêchent une réponse tardive de rétablir des données après verrouillage. Une inactivité de cinq minutes dans l’app déclenche la même fermeture.

La purge retire les références détenues par l’app et efface explicitement certains tampons Data. Swift, Foundation et les bibliothèques réseau peuvent créer des copies temporaires ; ce mécanisme ne garantit pas un effacement physique de chaque octet de RAM. Le processus n’est pas présenté comme résistant à une compromission du système.

Le paquet active App Sandbox et Hardened Runtime, sans exceptions JIT, mémoire exécutable non signée, injection de bibliothèques ou débogage. Les seuls accès supplémentaires sont le réseau sortant et les fichiers explicitement choisis par l’utilisateur en lecture/écriture, nécessaires au nettoyage demandé. Aucun accès permanent aux Documents, au dossier personnel ou à un groupe de trousseau partagé. Les autorisations de fichiers ne sont pas conservées dans des bookmarks.

## Retrait des originaux

Dans Connexions, « Sécuriser les fichiers d’origine… » compare la configuration choisie aux connexions actives, sauvegarde les fichiers complets dans une entrée du trousseau protégée par authentification, puis relit et compare cette sauvegarde. Les fichiers originaux sont comparés une nouvelle fois avant mutation. Un fichier modifié, une clé différente ou une sauvegarde non vérifiée interrompt le nettoyage.

Le `.env.local` est remplacé par une configuration de démonstration sans identifiants. Seuls les fichiers de clés explicitement référencés sont retirés. Les clés hors du dossier sélectionné nécessitent leur propre sélection dans le panneau macOS. Les sauvegardes successives sont conservées séparément dans le trousseau pour permettre une récupération sur demande ; retirer les connexions actives ne supprime pas ces sauvegardes.

La suppression de fichiers ne révoque pas les clés chez les fournisseurs et ne supprime pas les copies historiques APFS/Time Machine ou d’autres sauvegardes. Une rotation des identifiants reste nécessaire si une exposition antérieure est suspectée ; elle n’est pas effectuée automatiquement.

## Signature et notarisation

`build.sh` choisit une identité Apple et un profil valides pour cet identifiant. Il privilégie Developer ID Application et refuse de revenir silencieusement à une signature ad hoc. Pour sélectionner explicitement l’identité et le profil : `GAMEMETRIK_SIGNING_IDENTITY` et `GAMEMETRIK_SIGNING_PROFILE`.

`notarize.sh NOM_DU_PROFIL_NOTARYTOOL` réalise une soumission explicite à Apple, attend l’acceptation, agrafe le ticket puis vérifie Gatekeeper. Une signature Developer ID seule ne prouve pas la notarisation : voir VALIDATION.md pour le statut réel du paquet livré. Aucun hébergement ni publication n’est réalisé.

## Risque résiduel

Les clés reprises sont des clés d’administration. L’app effectue des lectures mais les clés ne deviennent pas pour autant limitées à la lecture côté fournisseur. L’isolation locale ne remplace pas le moindre privilège, la révocation et la sécurité du Mac. Les essais couvrent les invariants ciblés ; ils ne constituent pas un audit de pénétration indépendant.


## Cache agrégé depuis la version 0.5

Le dossier Application Support/GameMetrik/AggregateCache du conteneur de l’app contient uniquement des fichiers `.gmc` chiffrés et authentifiés par AES-256-GCM. Le répertoire a les permissions 700 et les fichiers 600 ; il est exclu des sauvegardes. La clé aléatoire de 256 bits est enregistrée sous `aggregate-cache.key` dans le même trousseau protégé par présence utilisateur, après relecture vérifiée.

Un HMAC du projet Firebase et de l’organisation (depuis 0.14) distingue les fichiers sans exposer d’identifiant en clair dans leurs noms. Les comptes fournisseurs utilisés sont enregistrés à l’intérieur du fichier chiffré pour n’invalider que les journées concernées. Aucun secret n’y figure. Un refus d’accès purge la mémoire mais conserve le fichier, illisible sans la clé du trousseau. Le contexte et la version du format sont authentifiés comme données associées. Un fichier altéré, incompatible ou illisible est ignoré, avec reconstruction depuis les fournisseurs. Aucun cache n’est ouvert avant le déverrouillage. Le verrouillage retire la clé, le cache déchiffré et les vues de l’état applicatif ; les limites d’effacement physique de RAM indiquées plus haut restent applicables.

Le schéma persistant ne contient que le catalogue des jeux, les totaux financiers quotidiens, les décomptes d’activité et les tableaux agrégés. Les profils, identifiants joueurs, événements, rapports bruts, clés privées et jetons ne sont pas persistés dans ce cache. L’annulation ou un changement de génération empêchent un résultat tardif d’être enregistré. Vider le cache supprime tous les fichiers de ce format dans son répertoire dédié, y compris ceux d’un ancien contexte.
