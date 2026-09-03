# Squirrel — spécification du mode déplacement

**Révision 2** · bash ≥ 4.2 · 2026-09-03

Squirrel draine des répertoires de dépôt sur un partage NAS monté : il **déploie**
chaque fichier dans une arborescence miroir, puis le **retire** de la source en le
conservant dans une archive locale.

Ce document est normatif : il décrit ce que l'implémentation fait, et pourquoi chaque
garde existe. Il complète le [README](README.md), qui reste le guide d'installation et
d'exploitation.

---

## §1 — Portée

Squirrel est un script bash unique, piloté par cron, qui surveille un ou plusieurs
arbres source montés localement. Sous chaque arbre il localise les répertoires portant
un nom donné (`input` par défaut), et pour chaque fichier qui s'y trouve il exécute la
transaction décrite en [§5](#5--la-transaction-par-fichier) : déploiement vérifié, puis
retrait de la source.

```
avant                              après
─────────────────────────────      ──────────────────────────────────────────
A/proj/input/report.xml            A/proj/input/archive/report.xml   (déplacé)
B/proj/input/            (vide)    B/proj/input/report.xml           (déployé)
```

L'outil ne dépend que de bash ≥ 4.2, des coreutils/findutils GNU et de `flock`. Pas de
démon, pas de systemd, pas de service externe. Le montage des partages est hors
périmètre : squirrel constate, il ne monte pas.

---

## §2 — Termes

| Terme | Définition |
|---|---|
| **Source (A)** | La racine `source_root` d'une cible. Squirrel y écrit et y supprime — c'est le changement de fond par rapport aux versions antérieures. |
| **Déploiement (B)** | La racine `deploy_root`. Miroir de l'arborescence source, portant l'état *courant* de ce qui a été livré. Ce n'est pas un magasin de versions. |
| **Répertoire de dépôt** | Un répertoire effectivement scanné : un répertoire `input` découvert, ou l'un de ses sous-répertoires directs. C'est le parent immédiat des fichiers traités. |
| **Archive locale** | Le répertoire `$LOCAL_ARCHIVE_DIR` (défaut `archive`) créé *dans* le répertoire de dépôt. Il reçoit chaque fichier retiré de la source, et n'est jamais scanné. |
| **Cible** | Un couple `(project, env)` déclaré dans `targets.tsv`, ou une règle `EXTRA_DIRS`. Chaque cible a son état, ses journaux et sa clé. |
| **Clé** | `<project>__<env>` après passage au filtre `[^A-Za-z0-9._-] → _`. Nomme les fichiers d'état et le répertoire de journaux. |
| **Cycle** | Un passage sur une cible. Une exécution boucle jusqu'à `RUN_DURATION` secondes, en réveillant chaque cible tous les `scan_interval`. |
| **Passe profonde** | Un cycle qui ignore l'optimisation de saut par mtime de répertoire. Déclenchée tous les `DEEP_SCAN_INTERVAL` secondes. |

---

## §3 — Invariant

> **Un fichier ne quitte jamais la source à moins d'être durablement présent, vérifié
> par hachage, à la fois dans l'archive locale et dans l'arborescence de déploiement.**

Corollaires :

- **Une seule opération irréversible par fichier.** Le retrait de la source est un
  `rename(2)` vers l'archive locale — atomique, même système de fichiers, même inode.
  La copie archivée ne peut donc être ni tronquée ni corrompue : il n'y a rien à
  vérifier après coup.
- **Le retrait est la dernière étape.** Retirer avant de déployer rendrait un échec de
  déploiement irrécupérable : il ne resterait rien dans le répertoire de dépôt pour
  réessayer.
- **Toute reprise est idempotente.** Une interruption laisse le fichier dans son
  répertoire de dépôt. Le cycle suivant redéploie un contenu identique au même chemin
  et retente le même `rename`, dont le nom cible est une fonction pure du nom, de la
  mtime et du hachage. Aucune reprise ne peut inventer un chemin, donc rien ne
  s'accumule.
- **L'état « archivé mais pas déployé » n'existe pas.** Il est structurellement
  impossible, l'archivage étant postérieur au déploiement.

---

## §4 — Sélection

### Découverte

Une marche complète localise les répertoires dont le nom figure dans `input_dir_name`.
Elle **élague à chaque correspondance** : elle ne descend jamais dans un répertoire
d'entrée, donc ne parcourt pas les sous-arbres volumineux. Elle n'est relancée que si le
cache est absent, plus vieux que `DISCOVERY_INTERVAL`, si sa signature a changé, ou sur
`--rediscover`.

Les noms sont séparés par des **virgules uniquement** — un nom peut contenir des
espaces — et sont mis en correspondance **littéralement** : les métacaractères `*`, `?`
et `[` sont échappés avant d'atteindre `find -name`. La casse est significative.

### Profondeur

Pour chaque répertoire d'entrée, une seule lecture en masse retourne le répertoire
lui-même et ses sous-répertoires directs avec leurs mtimes. Les fichiers pris sont ceux
**directement dans** le répertoire d'entrée et **directement dans** chacun de ses
sous-répertoires directs. Rien au-delà. Un nouveau sous-répertoire est vu au cycle
suivant, sans redécouverte.

### Élagage

| Règle | Correspondance | Portée |
|---|---|---|
| `$LOCAL_ARCHIVE_DIR` | Nom exact, sensible à la casse | Les trois parcours : scan par cycle, marche de découverte, marche du mode `fixed` |
| `EXCLUDE_DIR_PATTERNS` | Globs insensibles à la casse | Idem — répertoire sauté et jamais descendu |
| Racine du parcours | Jamais exclue par son propre nom | Un répertoire d'entrée, ou la source d'une règle `EXTRA_DIRS` |

> **Pourquoi l'élagage de l'archive est normatif.** L'archive locale est créée *dans* un
> répertoire scanné. Sans cet élagage, chaque fichier archivé serait re-vu au cycle
> suivant sous un chemin relatif différent, redéployé, puis retiré de la source —
> détruisant précisément l'archive que la fonctionnalité existe pour constituer. La
> correspondance est exacte : un répertoire nommé `archived` reste du contenu déployable.

---

## §5 — La transaction par fichier

Séquence normative. L'ordre est l'argument de sûreté ; il n'est pas négociable.

### 1. Stabilité

Le fichier est ignoré tant que `now − mtime < MIN_STABLE_AGE`. Pendant qu'un producteur
écrit en place, la mtime avance et l'âge reste sous le seuil.

*Trop récent* → laissé en place, répertoire marqué non stabilisé, réessayé au cycle
suivant.

### 2. Hachage de la source

`$HASH_CMD` (défaut `sha256sum`) calcule l'empreinte qui servira à vérifier le
déploiement, à classer la collision, et à nommer l'entrée d'archive.

*Illisible* → `HASH_FAILED` ; jamais consommé. On ne supprime pas ce qu'on n'a pas pu
lire.

### 3. Déploiement, vérifié avant publication

Copie vers un temporaire caché `.<nom>.squirrel-tmp.$$` voisin de la cible,
**re-hachage du temporaire**, puis `mv` en place. Vérifier avant de renommer garantit
qu'une copie corrompue ne devient jamais visible et n'écrase jamais un fichier déjà
correct.

*Échec* → `DEPLOY_FAILED` ; temporaire supprimé, ce qui était déployé reste intact,
source conservée.

### 4. Re-vérification de la source

`(size, mtime)` est relu et comparé à la valeur de l'étape 1. S'il a changé, ce qui
vient d'être déployé est l'instantané d'un fichier à demi écrit.

*Modifié* → `SOURCE_CHANGED_DURING_COPY` ; déployé mais **non consommé**. Le cycle
suivant converge sur le contenu final.

### 5. Commit — retrait de la source

`rename(2)` du fichier vers l'archive locale. **Unique opération irréversible de la
séquence**, unique instant où A change, et atomique. Si `LOCAL_ARCHIVE_DIR` est vide,
c'est un `rm`.

*Échec* → `SOURCE_STUCK`, sortie `5` ; le fichier reste, déployé. Chaque reprise est un
no-op côté B suivi d'un nouveau `rename`.

### Sûreté au crash

| Interruption | État immédiat | Cycle suivant |
|---|---|---|
| Entre 3 et 5 | Déployé ; fichier encore dans le dépôt | Redéploiement d'un contenu identique (`DEPLOYED_IDENTICAL`), puis `rename`. Aucun doublon. |
| Pendant le `rename` | Atomique : il a eu lieu, ou pas | Rien à réconcilier |
| Après 5 | Déployé et archivé, source vidée | Rien à faire |

Il n'existe aucune interruption laissant le fichier absent à la fois de la source et de
l'archive.

---

## §6 — Nommage

### Dans l'arborescence de déploiement

Le chemin est le miroir exact : `A/<rel>` → `B/<rel>`, où `<rel>` est relatif à
`source_root` et inclut donc le segment `input`. **Aucune version horodatée n'est jamais
créée dans B.**

| État de la destination | Action | Événement |
|---|---|---|
| Absente | Écrite | `DEPLOYED` |
| Présente, contenu différent | Écrasée, les deux empreintes journalisées | `DEPLOYED_OVERWRITE` |
| Présente, contenu identique | Rien réécrit — mais le fichier source est **quand même** archivé et retiré | `DEPLOYED_IDENTICAL` |

> **Pourquoi le cas identique n'est pas un saut.** Sauter un fichier parce que la
> destination est déjà à jour le laisserait indéfiniment dans son répertoire de dépôt.
> Un fichier redéposé à l'identique doit être drainé comme les autres.

### Dans l'archive locale

Le nom cible est une **fonction pure** de `(nom de base, mtime source, hachage)` —
jamais de l'horloge murale — afin que toute reprise vise exactement le même chemin.

| Condition | Nom retenu |
|---|---|
| Nom libre | `archive/report.xml` |
| Pris, contenu identique | Réutilisé tel quel — aucune copie créée (`ARCHIVE_REUSED`) |
| Pris, contenu différent | `archive/report_<AAAAMMJJ_HHMMSS>.xml`, horodatage issu de la mtime source |
| Celui-ci aussi pris, contenu différent | `archive/report_<stamp>_<hash8>.xml` |

---

## §7 — Matrice de défaillance

| Événement | Niv. | Cause | Fichier dans A | Dans B | Sortie | Suite |
|---|---|---|---|---|---|---|
| `MOUNT_MISSING` | ERROR | Source absente, illisible ou non inscriptible | Intact | — | 2 | Cible sautée ; discret sur répétition |
| `DEPLOY_UNAVAILABLE` | ERROR | Sentinelle absente et racine de déploiement vide ou absente | **Intact** | Rien écrit | 4 | Cible entière refusée avant tout octet |
| `SOURCE_NOT_WRITABLE` | WARN | Répertoire de dépôt sans `w+x` | **Intact** | Rien écrit | 5 | Répertoire entier sauté |
| `FILE_VANISHED` | WARN | Disparu entre le listage et le `stat` | Absent | — | 0 | Rien à faire |
| `META_UNREADABLE` | WARN | Taille ou mtime aberrante | Conservé | — | 0 | Réessayé à chaque cycle |
| `SKIP_UNSTABLE` | DEBUG | Plus jeune que `MIN_STABLE_AGE` | Conservé | — | 0 | Réessayé |
| `HASH_FAILED` | WARN | Fichier illisible | **Conservé** | — | 0 | Réessayé ; jamais consommé |
| `DEPLOY_FAILED` | ERROR | `stage=mkdir\|cp\|verify\|mv` | **Conservé** | Version précédente intacte | 4 | Réessayé, temporaire nettoyé |
| `SOURCE_CHANGED_DURING_COPY` | WARN | Écrivain en course avec la copie | **Conservé** | Instantané partiel | 0 | Converge sur le contenu final |
| `ARCHIVE_DIR_FAILED` | ERROR | Création de l'archive locale impossible | **Conservé** | Déployé | 5 | Réessayé |
| `SOURCE_STUCK` | ERROR | `rename` vers l'archive refusé | **Conservé** | Déployé | 5 | Reprise idempotente, sans doublon |

> **Lecture opérationnelle.** `4` signifie « la donnée n'est pas livrée » : la
> destination est cassée. `5` signifie « livrée, mais la source se remplit » : ce sont
> des droits à corriger sur le partage de dépôt. Les deux méritent des alertes
> distinctes.

Tout échec laissant un fichier dans un répertoire de dépôt marque ce répertoire comme
**non stabilisé**, donc jamais mémorisé comme inchangé : il est relu à chaque cycle
jusqu'à résolution. Le *journal*, lui, est dédupliqué à une ligne par exécution et par
fichier.

---

## §8 — Gardes

### 8.1 Sentinelle de la racine de déploiement

Une destination démontée est le pire mode de défaillance : `mkdir -p` peuplerait
joyeusement le point de montage local, chaque fichier serait ensuite retiré de la source
à cause de cela, et au remontage l'arborescence serait vide et les sources parties —
avec un code de sortie `0`.

Chaque `deploy_root` porte donc un fichier sentinelle `$DEPLOY_MARKER`, que le script
provisionne lui-même :

| Situation | Décision |
|---|---|
| Sentinelle présente | Fonctionnement normal |
| Sentinelle héritée `.squirrel-archive-root` | Acceptée et mise à niveau (`DEPLOY_MARKER_MIGRATED`) |
| Aucun ledger (première exécution) | Racine et sentinelle créées (`DEPLOY_MARKER_CREATED`) |
| Ledger rempli, racine existante et non vide | Arborescence adoptée (`DEPLOY_MARKER_ADOPTED`) |
| Ledger rempli, racine absente ou vide | **Refus** (`DEPLOY_UNAVAILABLE`) — rien écrit, rien retiré |

### 8.2 Drainabilité du répertoire de dépôt

Avant de traiter le moindre fichier, le répertoire doit être `w+x` : délier un fichier
exige ces droits sur son *parent*, indépendamment du mode du fichier. À défaut, le
répertoire entier est sauté. Déployer depuis un répertoire qu'on ne peut pas vider
redéploierait les mêmes fichiers à chaque cycle, indéfiniment.

### 8.3 Stabilité et écriture en place

`MIN_STABLE_AGE=0` n'est sûr que si **tous** les producteurs publient atomiquement —
écriture ailleurs, puis renommage dans le répertoire de dépôt. Les producteurs NAS
courants (copie par l'explorateur Windows, clients SMB, `rsync` sans `--partial-dir`,
scanners, exports ERP) ne le font généralement pas.

> **Ce qui a changé avec le mode déplacement.** Sous un outil de copie seule, prendre un
> fichier à demi écrit produisait une copie inutile et l'original restait : la passe
> suivante réparait. Ici, l'instantané tronqué est déployé et la source déplacée — sous
> Linux le descripteur ouvert de l'écrivain suit l'inode, donc le fichier *complet*
> atterrit discrètement dans `archive/`, qui n'est jamais déployé.

L'étape 4 de [§5](#5--la-transaction-par-fichier) est le filet : `MIN_STABLE_AGE` est le
bouton de réglage, la re-vérification est la garantie.

---

## §9 — Configuration

`squirrel.conf`, sourcé par le script. Toute valeur est surchargeable par cible lorsque
la colonne existe.

| Clé | Défaut | Rôle |
|---|---|---|
| `INPUT_DIR_NAME` | `"input"` | Noms exacts, séparés par virgules, mis en correspondance littéralement |
| `SCAN_INTERVAL` | `10` | Secondes entre deux passes internes |
| `RUN_DURATION` | `55` | Durée maximale d'une exécution |
| `MIN_STABLE_AGE` | `5` | **Réglage de sûreté** — voir §8.3 |
| `LOCAL_ARCHIVE_DIR` | `"archive"` | Nom de l'archive locale ; `""` la désactive |
| `DEPLOY_MARKER` | `".squirrel-deploy-root"` | Sentinelle de la racine de déploiement |
| `REQUIRE_MOUNT` | `true` | Niveau de journal si la source est indisponible |
| `HASH_CMD` | `"sha256sum"` | Commande de hachage, mot unique |
| `DRY_RUN` | `false` | Répétition inerte : ni écriture, ni suppression |
| `DISCOVERY_INTERVAL` | `1800` | Secondes entre deux redécouvertes complètes |
| `DISCOVERY_MAXDEPTH` | `0` | Plafond de profondeur ; 0 = illimité |
| `USE_DIR_MTIME_SKIP` | `true` | Saute un répertoire dont la mtime n'a pas bougé |
| `DEEP_SCAN_INTERVAL` | `300` | Secondes entre deux passes ignorant ce saut |
| `EXCLUDE_DIR_PATTERNS` | `()` | Globs insensibles à la casse à ignorer partout |
| `EXTRA_DIRS` | `()` | Règles explicites source → destination |
| `LOG_LEVEL` | `"INFO"` | `DEBUG` / `INFO` / `WARN` / `ERROR` |
| `LOG_FORMAT` | `"text"` | `text` ou `json` |
| `LOG_ROTATE_MAX_BYTES` | `10485760` | Rotation au-delà ; 0 = jamais |
| `LOG_ROTATE_KEEP` | `7` | Fichiers tournés conservés |
| `AUDIT_LOG` | `true` | Piste d'audit par cible |
| `HEARTBEAT_INTERVAL` | `60` | Résumé périodique ; 0 = désactivé |

Options de ligne de commande : `--config FILE`, `--rediscover`, `--debug`, `--once`,
`--verbose`, `--help`. `--debug`, `--once` et `--verbose` sont appliqués *après* le
sourcing de la configuration : un drapeau ne peut pas être écrasé par le fichier.

---

## §10 — Déclaration des cibles

### `targets.tsv`

Une ligne par couple `(project, env)`, **séparée par des tabulations** — les chemins
peuvent donc contenir des espaces. Utiliser `-` ou un champ vide pour hériter du défaut
global.

```
# project ⇥ env ⇥ source_root ⇥ deploy_root ⇥ input_dir_name ⇥ scan_interval ⇥ enabled
projectA	prod	/mnt/nas/projectA/prod	/mnt/nas/deploy/projectA/prod	input	10	true
projectB	prod	/mnt/nas/projectB/prod	/mnt/nas/deploy/projectB/prod	-	-	true
```

Une ligne sans tabulation retombe sur un découpage par espaces, ce qui décale toute
colonne suivant une valeur en contenant. Le script le signale (`TARGET_EXTRA_FIELDS`,
`TARGET_BAD_ENABLED`) plutôt que d'abandonner la cible en silence, mais les tabulations
restent la seule forme fiable.

### `EXTRA_DIRS`

Pour drainer un répertoire précis vers une destination précise, sans découverte. Chaque
règle est `label ⇥ source ⇥ destination ⇥ depth`, où `depth` vaut `0` (fichiers
directs), `N` sous-niveaux, ou `-1` / `unlimited` pour tout le sous-arbre.

Ces règles passent par le **même moteur** : déplacement, archive locale, stabilité,
exclusions, sentinelle, journaux et audit par règle. Leur état vit sous
`<label>__extra`. Elles sont additives : elles s'exécutent même si `targets.tsv` n'a
aucune cible active.

---

## §11 — État persistant

Quatre fichiers par cible, sous `state/`. **Aucun n'est requis pour la correction.**

| Fichier | Contenu | Si supprimé |
|---|---|---|
| `<clé>.ledger.tsv` | Journal de provenance en ajout seul : une ligne par fichier déplacé (`relpath, size, mtime, hash, cible, date`) | Aucun effet, sauf que §8.1 perd son signal « on a déjà écrit ici » |
| `<clé>.inputs.tsv` | Emplacements des répertoires d'entrée, précédés d'un en-tête signant les réglages qui ont façonné la marche | Redécouverte au cycle suivant |
| `<clé>.leaves.tsv` | mtimes stabilisées par répertoire, avec en-tête de version de format | Un cycle de relecture complète |
| `<clé>.deepscan` | Horodatage de la dernière passe profonde | Une passe profonde immédiate |

> **Le ledger ne pilote aucune décision.** C'est un enregistrement, pas un index. Les
> versions antérieures l'utilisaient pour décider si un fichier avait déjà été traité ;
> avec la sémantique de déplacement c'est un piège : un fichier sauté sur la foi d'une
> entrée n'est jamais copié, donc jamais retiré, et reste indéfiniment dans son
> répertoire de dépôt. La question « la destination porte-t-elle déjà ce contenu ? » se
> règle en hachant la destination — la seule réponse qui survive à un crash. Un ledger
> corrompu est donc sans effet sur la livraison.

---

## §12 — Observabilité

### Journaux

Une ligne structurée par événement, en texte clé/valeur ou en JSON. Les valeurs pouvant
contenir des tabulations, retours à la ligne ou `%` sont encodées de façon réversible.
Trois destinations :

- `logs/_run.log` — événements d'orchestration : démarrage, cibles chargées, battement
  de cœur, résumé.
- `logs/<clé>/operations.log` — tout ce qui concerne une cible.
- `logs/<clé>/audit.log` — piste en ajout seul, `action=MOVED`, tournée comme les
  autres.

Chaque ligne porte un `run=` corrélant l'exécution, et les lignes de cible portent
`project=`, `env=` et `cycle=`.

### Événements à surveiller

| Événement | Signification opérationnelle |
|---|---|
| `DEPLOY_UNAVAILABLE` | La destination n'est pas là. Rien ne circule. |
| `DEPLOY_FAILED` | Écriture refusée. La donnée n'est pas livrée. |
| `SOURCE_STUCK` | Livré, mais la source ne se vide pas. |
| `SOURCE_NOT_WRITABLE` | Un répertoire entier ne peut pas être drainé. |
| `MOUNT_MISSING` | Source indisponible ; le journal donne l'ancêtre existant le plus profond. |

### Codes de sortie

| Code | Signification | Action attendue |
|---|---|---|
| `0` | Succès | — |
| `1` | Erreur de configuration | Corriger `squirrel.conf` ou `targets.tsv` |
| `2` | Aucune cible exploitable | Vérifier les montages source |
| `3` | Verrou occupé | Aucune — attendu à chaque relance cron |
| `4` | Écriture de déploiement en échec | Réparer la destination |
| `5` | Fichier livré mais non retiré de la source | Corriger les droits sur le partage de dépôt |

Précédence : aucune cible exploitable, puis échec de déploiement, puis source bloquée.
La donnée non livrée prime sur la donnée livrée mais non drainée.

---

## §13 — Exécution

Une exécution acquiert un `flock` non bloquant sur `run.lock`, puis boucle jusqu'à
`RUN_DURATION` secondes en réveillant chaque cible tous les `scan_interval`. Une seconde
instance sort immédiatement en `3`. Une entrée cron par minute suffit donc à relancer la
boucle si elle est morte, sans jamais provoquer de recouvrement.

`--rediscover` dépose un marqueur et sort : la boucle en cours force une redécouverte
complète et une passe profonde au cycle suivant.

> **Mise en service.** Toute nouvelle cible se répète d'abord avec `DRY_RUN=true`, et
> les lignes `WOULD_MOVE` se lisent une par une. Cet outil supprime depuis la source :
> une `source_root` erronée ne se rattrape pas depuis les journaux.

---

## §14 — Migration depuis le mode copie

| Élément | Comportement |
|---|---|
| Sentinelle héritée | `.squirrel-archive-root` est acceptée et le nouveau marqueur est écrit à côté (`DEPLOY_MARKER_MIGRATED`) |
| Cache `leaves.tsv` | Porte une version de format. L'ancien cache est rejeté, sinon tout répertoire aurait été jugé « inchangé » depuis la dernière exécution en mode copie et l'arriéré n'aurait pas été drainé. |
| Ledger existant | Conservé et complété. Il n'est plus lu pour décider quoi que ce soit. |
| Arriéré dans la source | **Tout fichier encore présent sera déployé puis retiré**, en une seule passe. C'est le comportement voulu, mais il doit être une décision consciente. |
| Colonne 4 de `targets.tsv` | Renommée `deploy_root`. Positionnelle : aucun changement de format. |
| Versionnage | **B n'est plus un magasin de versions.** Un fichier modifié écrase désormais ; l'historique vit dans l'archive locale. |

---

## §15 — Hors périmètre

- **Aucune rétention.** Les archives locales croissent sans limite, sur le partage
  *source*, et rien ne les purge. Les partages de dépôt ont besoin d'une politique de
  rétention propre.
- **Aucun montage.** Les partages sont supposés déjà montés ; squirrel constate leur
  état et refuse d'agir dans le doute.
- **Aucune garantie de capture.** Squirrel interroge, il ne verrouille pas le
  producteur. Un fichier dont la durée de vie est plus courte qu'un `SCAN_INTERVAL` peut
  être manqué.
- **Aucun consommateur concurrent.** Squirrel est ce qui vide les répertoires de dépôt.
  Si un autre processus en retire des fichiers, squirrel ne les verra simplement jamais.
- **Aucune reprise transactionnelle multi-fichiers.** La transaction porte sur un
  fichier ; il n'existe pas de lot atomique.
