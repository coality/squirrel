# file-deploy — move-mode specification

**Revision 2** · bash ≥ 4.2 · 2026-09-03

file-deploy drains pickup directories on a mounted NAS share: it **deploys** each
file into a mirror tree, then **moves it out** of the source, keeping it in a
local archive.

This document is normative — it states what the implementation does and why each
guard exists. The [README](README.md) is the operator's guide.

---

## §1 — Scope

file-deploy is a single cron-driven bash script watching one or more locally mounted
source trees. Under each tree it locates directories with a given name (`input`
by default), and for every file found there it runs the transaction of
[§5](#5--the-per-file-transaction): verified deployment, then removal from the
source.

```
before                             after
─────────────────────────────      ────────────────────────────────────────────
A/proj/input/report.xml            A/proj/input/archive/report.xml     (moved)
B/proj/input/            (empty)   B/proj/input/report.xml          (deployed)
```

Dependencies are bash ≥ 4.2, GNU coreutils/findutils and `flock`. No daemon, no
systemd, no external service. Mounting the shares is out of scope: file-deploy
observes their state and refuses to act when in doubt.

---

## §2 — Terms

| Term | Definition |
|---|---|
| **Source (A)** | A target's `source_root`. file-deploy writes to it and deletes from it — the substantive change from earlier versions. |
| **Deployment tree (B)** | A target's `deploy_root`. Mirrors the source layout and carries the *current* state of what has been delivered. It is not a version store. |
| **Pickup directory** | A directory actually scanned: a discovered `input` directory, or one of its direct subdirectories. It is the immediate parent of the files processed. |
| **Local archive** | The `$LOCAL_ARCHIVE_DIR` directory (default `archive`) created *inside* the pickup directory. It receives every file taken out of the source, and is never scanned. |
| **Target** | A `(project, env)` pair declared in `targets.tsv`, or an `EXTRA_DIRS` rule. Each target has its own state, logs and key. |
| **Key** | `<project>__<env>` after the filter `[^A-Za-z0-9._-] → _`. Names the state files and the log directory. |
| **Cycle** | One pass over one target. A run loops for up to `RUN_DURATION` seconds, waking each target every `scan_interval`. |
| **Deep pass** | A cycle that ignores the directory-mtime skip. Due every `DEEP_SCAN_INTERVAL` seconds. |

---

## §3 — Invariant

> **A file never leaves the source unless it is durably present, hash-verified,
> in both the local archive and the deployment tree.**

Corollaries:

- **One irreversible operation per file.** Removal from the source is a
  `rename(2)` into the local archive — atomic, same filesystem, same inode. The
  archived copy therefore cannot be truncated or corrupt: there is nothing to
  verify after the fact.
- **Removal is the last step.** Removing before deploying would make a
  deployment failure unrecoverable: nothing would be left in the pickup
  directory to retry from.
- **Every retry is idempotent.** An interruption leaves the file in its pickup
  directory. The next cycle re-deploys identical content to the same path and
  re-attempts the same `rename`, whose target name is a pure function of the
  name, mtime and hash. No retry can invent a path, so nothing accumulates.
- **The state "archived but not deployed" cannot exist.** It is structurally
  impossible, archiving being posterior to deployment.

---

## §4 — Selection

### Discovery

A full walk locates directories whose name appears in `input_dir_name`. It
**prunes at every match**: it never descends into a pickup tree, so it does not
walk the large subtrees. It re-runs only when the cache is absent, older than
`DISCOVERY_INTERVAL`, when its signature changed, or on `--rediscover`.

Names are separated by **commas only** — a name may contain spaces — and are
matched **literally**: the metacharacters `*`, `?` and `[` are escaped before
reaching `find -name`. Case is significant.

### Depth

For each `input` directory, a single bulk read returns the directory itself and
its direct subdirectories with their mtimes. The files taken are those
**directly inside** the `input` directory and **directly inside** each of its
direct subdirectories. Nothing deeper. A new subdirectory is seen on the next
cycle, with no rediscovery.

### Pruning

| Rule | Match | Applies to |
|---|---|---|
| `$LOCAL_ARCHIVE_DIR` | Exact name, case-sensitive | All three walks: per-cycle scan, discovery walk, `fixed`-mode walk |
| `EXCLUDE_DIR_PATTERNS` | Case-insensitive globs | Same — directory skipped and never descended |
| The walk's own root | Never excluded by its own name | An `input` directory, or an `EXTRA_DIRS` rule's source |

> **Why pruning the archive is normative.** The local archive is created *inside*
> a scanned directory. Without this, every archived file would be seen again on
> the next cycle under a different relative path, deployed a second time, then
> removed from the source — destroying exactly the archive the feature exists to
> build. The match is exact: a directory named `archived` stays deployable
> content.

---

## §5 — The per-file transaction

Normative sequence. The order *is* the safety argument; it is not negotiable.

### 1. Stability

The file is ignored while `now − mtime < MIN_STABLE_AGE`. While a producer
writes in place, the mtime keeps moving and the age stays under the threshold.

*Too recent* → left in place, directory marked unsettled, retried next cycle.

### 2. Hash the source

`$HASH_CMD` (default `sha256sum`) computes the digest used to verify the
deployment, classify the collision, and name the archive entry.

*Unreadable* → `HASH_FAILED`; never consumed. We do not delete what we could not
read.

### 3. Deploy, verified before publication

Copy to a hidden temporary `.<name>.file-deploy-tmp.$$` beside the target,
**re-hash the temporary**, then `mv` into place. Verifying before renaming
guarantees a corrupt copy never becomes visible and never clobbers a file that
was already correct.

*Failure* → `DEPLOY_FAILED`; temporary removed, whatever was deployed stays
intact, source kept.

### 4. Re-check the source

`(size, mtime)` is read again and compared to step 1. If it changed, what was
just deployed is a snapshot of a half-written file.

*Changed* → `SOURCE_CHANGED_DURING_COPY`; deployed but **not consumed**. The
next cycle converges on the final content.

### 5. Commit — removal from the source

`rename(2)` of the file into the local archive. **The only irreversible
operation of the sequence**, the only instant at which A changes, and atomic. If
`LOCAL_ARCHIVE_DIR` is empty it is an `rm` instead.

*Failure* → `SOURCE_STUCK`, exit `5`; the file stays, deployed. Every retry is a
no-op on the B side followed by another `rename`.

### Crash safety

| Interruption | Immediate state | Next cycle |
|---|---|---|
| Between 3 and 5 | Deployed; file still in the pickup directory | Re-deploy of identical content (`DEPLOYED_IDENTICAL`), then `rename`. No duplicate. |
| During the `rename` | Atomic: it happened, or it did not | Nothing to reconcile |
| After 5 | Deployed and archived, source drained | Nothing to do |

No interruption leaves the file absent from both the source and the archive.

---

## §6 — Naming

### In the deployment tree

The path is an exact mirror: `A/<rel>` → `B/<rel>`, where `<rel>` is relative to
`source_root` and therefore includes the `input` segment. **No timestamped
version is ever created in B.**

| Destination state | Action | Event |
|---|---|---|
| Absent | Written | `DEPLOYED` |
| Present, identical content | Nothing rewritten — but the source file is **still** archived and removed | `DEPLOYED_IDENTICAL` |
| Present, different content | Decided by `ON_CONFLICT` — see below | |

> **Why the identical case is not a skip.** Skipping a file because the
> destination is already current would leave it in its pickup directory
> indefinitely. A file re-dropped unchanged must be drained like any other.
> Identical content is never a conflict, whatever the policy.

### Conflict policy

`ON_CONFLICT` decides what happens when the destination holds the same relative
path with **different** content. It is validated at startup: an unrecognised
value is a configuration error (exit `1`), never a guess.

| Value | Deployment tree | Source file | Event | Exit |
|---|---|---|---|---|
| `overwrite` (default) | Replaced | Archived and drained | `DEPLOYED_OVERWRITE` + `prev_hash=` in the audit trail | `0` |
| `version` | Existing file kept; the incoming one lands beside it as `<name>_<stamp><ext>` | Archived and drained | `DEPLOYED_VERSION` | `0` |
| `skip` | Untouched, therefore stale | Archived and drained — nothing is lost, nothing piles up | `DEPLOY_SKIPPED` (WARN) | `0` |
| `retry` | Untouched | **Kept**, not archived; re-evaluated every cycle until the collision clears | `DEPLOY_RETRY` (WARN, once per run per file) | `0` |
| `fail` | Untouched | **Kept in the pickup directory**, not archived | `DEPLOY_CONFLICT` (ERROR) | `4` |

Under `version` the stamp comes from the **source mtime**, so the chosen path is
a pure function of `(name, source mtime, hash)` and a retry lands on the same
file rather than creating a third one — the same rule the local archive uses.

`skip` is the one policy that relaxes [§3](#3--invariant): the file leaves the
source while the deployment tree still holds different content. Its content is
never lost — the local archive holds it, hash-verified — but the deployed
version stays stale, which is why every occurrence is logged at `WARN`.

`retry` and `fail` both keep the invariant intact and both keep the source file;
they differ only in how loudly they say so. `retry` treats the collision as a
pending state — `WARN`, exit `0` — and clears by itself as soon as the deployed
file changes or is consumed, which is the natural fit when the destination is a
handover directory someone else empties. `fail` treats it as an incident —
`ERROR`, exit `4` — for when a collision means something upstream is wrong.
Both re-hash the file on every cycle until it resolves, so neither is free on
large files.

### CSV report

When `REPORT_DIR` is set, every file that actually moved appends one row to
`<REPORT_DIR>/file-deploy-<YYYY-MM-DD>.csv`: one file per day, all targets in
it, header written on creation, RFC 4180 quoting on text fields. It is a
reporting side-channel, not state: deleting it changes nothing, and nothing is
written during a rehearsal.

Columns: `run_id`, `deployed_at`, `project`, `env`, `outcome`, `file_name`,
`relpath`, `source_path`, `deploy_path`, `archive_path`, `size_bytes`, `hash`,
`prev_hash`, `source_modified`, `source_created`, `age_at_pickup_s`,
`pickup_dir`, `host`.

`archive_path` is the retrieval key: it is where the file actually is now.
`source_created` is a real birth time and is **empty** on filesystems that do
not record one — CIFS/SMB usually does not, so `source_modified` is the field to
build on. `age_at_pickup_s` is `now − mtime` at pickup, a latency measure of how
long a file waited before being taken.

### In the local archive

The target name is a **pure function** of `(base name, source mtime, hash)` —
never of the wall clock — so that every retry resolves to the same path.

| Condition | Name used |
|---|---|
| Name free | `archive/report.xml` |
| Taken, identical content | Reused as is — no copy created (`ARCHIVE_REUSED`) |
| Taken, different content | `archive/report_<YYYYMMDD_HHMMSS>.xml`, stamp derived from the source mtime |
| That one also taken, different content | `archive/report_<stamp>_<hash8>.xml` |

---

## §7 — Failure matrix

| Event | Level | Cause | File in A | In B | Exit | Then |
|---|---|---|---|---|---|---|
| `MOUNT_MISSING` | ERROR | Source absent, unreadable or not writable | Intact | — | 2 | Target skipped; quiet on repeat |
| `DEPLOY_UNAVAILABLE` | ERROR | Sentinel absent and deployment root empty or missing | **Intact** | Nothing written | 4 | Whole target refused before any byte |
| `SOURCE_NOT_WRITABLE` | WARN | Pickup directory without `w+x` | **Intact** | Nothing written | 5 | Whole directory skipped |
| `FILE_VANISHED` | WARN | Gone between listing and `stat` | Absent | — | 0 | Nothing to do |
| `META_UNREADABLE` | WARN | Nonsensical size or mtime | Kept | — | 0 | Retried every cycle |
| `SKIP_UNSTABLE` | DEBUG | Younger than `MIN_STABLE_AGE` | Kept | — | 0 | Retried |
| `HASH_FAILED` | WARN | Unreadable file | **Kept** | — | 0 | Retried; never consumed |
| `DEPLOY_FAILED` | ERROR | `stage=mkdir\|cp\|verify\|mv` | **Kept** | Previous version intact | 4 | Retried, temporary cleaned up |
| `SOURCE_CHANGED_DURING_COPY` | WARN | Writer racing the copy | **Kept** | Partial snapshot | 0 | Converges on the final content |
| `ARCHIVE_DIR_FAILED` | ERROR | Local archive cannot be created | **Kept** | Deployed | 5 | Retried |
| `SOURCE_STUCK` | ERROR | `rename` into the archive refused | **Kept** | Deployed | 5 | Idempotent retry, no duplicate |

> **Operational reading.** `4` means "the data was not delivered": the
> destination is broken. `5` means "delivered, but the source is filling up":
> permissions to fix on the pickup share. Both deserve their own alert.

Any failure leaving a file in a pickup directory marks that directory
**unsettled**, so it is never recorded as unchanged: it is re-read every cycle
until resolved. The *log*, in contrast, is deduplicated to one line per run per
file.

---

## §8 — Guards

### 8.1 Deployment-root sentinel

An unmounted destination is the worst failure mode: `mkdir -p` would happily
populate the local mount point, every file would then be removed from the source
because of it, and on remount the tree would be empty and the sources gone —
with exit code `0`.

Each `deploy_root` therefore carries a sentinel file `$DEPLOY_MARKER`, which the
script provisions itself:

| Situation | Decision |
|---|---|
| Sentinel present | Normal operation |
| Never deployed here yet | Root and sentinel created (`DEPLOY_MARKER_CREATED`) |
| Deployed before, root exists and is non-empty | Pre-existing tree adopted (`DEPLOY_MARKER_ADOPTED`) |
| Deployed before, root missing or empty | **Refused** (`DEPLOY_UNAVAILABLE`) — nothing written, nothing removed |

"Deployed here before" is recorded by `state/<key>.deployed`, written on the
first successful move.

### 8.2 Pickup-directory drainability

Before any file is processed, the directory must be `w+x`: unlinking a file
requires those rights on its *parent*, whatever the file's own mode. Otherwise
the whole directory is skipped. Deploying out of a directory that cannot be
drained would re-deploy the same files every cycle, forever.

### 8.3 Stability and in-place writes

`MIN_STABLE_AGE=0` is safe only if **every** producer publishes atomically —
writes elsewhere, then renames into the pickup directory. Common NAS producers
(Windows Explorer copies, SMB clients, `rsync` without `--partial-dir`,
scanners, ERP exports) generally do not.

> **What changed with move mode.** Under a copy-only tool, picking up a
> half-written file produced a junk copy and the original stayed put: the next
> pass healed it. Here the truncated snapshot is deployed and the source is
> moved away — on Linux the writer's open descriptor follows the inode, so the
> *complete* file quietly lands in `archive/`, which is never deployed.

Step 4 of [§5](#5--the-per-file-transaction) is the backstop: `MIN_STABLE_AGE`
is the tuning knob, the re-check is the guarantee.

---

## §9 — Configuration

`file-deploy.conf`, sourced by the script. Any value is overridable per target
where a column exists.

| Key | Default | Role |
|---|---|---|
| `INPUT_DIR_NAME` | `"input"` | Exact names, comma-separated, matched literally |
| `SCAN_INTERVAL` | `10` | Seconds between internal passes |
| `RUN_DURATION` | `55` | Maximum duration of one run |
| `MIN_STABLE_AGE` | `5` | **Safety setting** — see §8.3 |
| `LOCAL_ARCHIVE_DIR` | `"archive"` | Name of the local archive; `""` disables it |
| `ON_CONFLICT` | `"overwrite"` | `overwrite` / `version` / `skip` / `retry` / `fail` when the destination holds different content — see [§6](#6--naming) |
| `REPORT_DIR` | `""` | Directory receiving the daily CSV of everything that moved; `""` disables it |
| `REPORT_DELIMITER` | `","` | CSV field separator (`";"` for a French-locale Excel/Power BI) |
| `DEPLOY_MARKER` | `".file-deploy-root"` | Deployment-root sentinel |
| `HASH_CMD` | `"sha256sum"` | Hash command, single word |
| `DRY_RUN` | `false` | Inert rehearsal: no write, no delete |
| `DISCOVERY_INTERVAL` | `1800` | Seconds between full rediscoveries |
| `DISCOVERY_MAXDEPTH` | `0` | Depth cap; 0 = unlimited |
| `USE_DIR_MTIME_SKIP` | `true` | Skip a directory whose mtime has not moved |
| `DEEP_SCAN_INTERVAL` | `300` | Seconds between passes ignoring that skip |
| `EXCLUDE_DIR_PATTERNS` | `()` | Case-insensitive globs to ignore anywhere |
| `EXTRA_DIRS` | `()` | Explicit source → destination rules |
| `LOG_LEVEL` | `"INFO"` | `DEBUG` / `INFO` / `WARN` / `ERROR` |
| `LOG_FORMAT` | `"text"` | `text` or `json` |
| `LOG_CONSOLE` | `"auto"` | Mirror log lines to stderr: `auto` (when interactive), `always`, `never` |
| `LOG_ROTATE_MAX_BYTES` | `10485760` | Rotate past this; 0 = never |
| `LOG_ROTATE_KEEP` | `7` | Rotated files kept |
| `AUDIT_LOG` | `true` | Per-target provenance trail |
| `HEARTBEAT_INTERVAL` | `60` | Periodic summary; 0 = off |

Command-line options: `--config FILE`, `--dry-run` (`-n`), `--once`,
`--debug`, `--verbose` (`-v`), `--rediscover`, `--help`. `--dry-run`, `--once`,
`--debug` and `--verbose` are applied *after* the configuration is sourced, so a
flag cannot be overridden by the file.

A rehearsal is inert in both directions: it writes nothing to the source or the
deployment tree, and it records nothing that would change a later run — no
settled-mtime cache, no deep-pass timestamp. Whenever it is active, from the
flag or from the config, the run logs `DRY_RUN_ACTIVE` at `WARN`, because a
rehearsal left switched on is indistinguishable from a healthy run that never
delivers anything.

---

## §10 — Declaring targets

### `targets.tsv`

One line per `(project, env)`, **tab-separated** — paths may therefore contain
spaces. Use `-` or an empty field to inherit the global default.

```
# project ⇥ env ⇥ source_root ⇥ deploy_root ⇥ input_dir_name ⇥ scan_interval ⇥ enabled
projectA	prod	/mnt/nas/projectA/prod	/mnt/nas/deploy/projectA/prod	input	10	true
projectB	prod	/mnt/nas/projectB/prod	/mnt/nas/deploy/projectB/prod	-	-	true
```

A line without a tab falls back to whitespace splitting, which shifts every
column following a value containing a space. The script reports it
(`TARGET_EXTRA_FIELDS`, `TARGET_BAD_ENABLED`) rather than dropping the target
silently, but tabs remain the only reliable form.

### `EXTRA_DIRS`

To drain one specific directory to one specific destination, with no discovery.
Each rule is `label ⇥ source ⇥ destination ⇥ depth`, where `depth` is `0`
(direct files), `N` sublevels, or `-1` / `unlimited` for the whole subtree.

These rules go through the **same engine**: the move, the local archive,
stability, exclusions, the sentinel, and per-rule logs and audit trail. Their
state lives under `<label>__extra`. They are additive: they run whether or not
`targets.tsv` has any enabled target.

---

## §11 — Persistent state

Four files per target, under `state/`. **None is required for correctness.**

| File | Content | If deleted |
|---|---|---|
| `<key>.deployed` | Empty marker, written on the first successful move | §8.1 loses its "we have deployed here before" signal, so a vanished destination looks like a first run |
| `<key>.inputs.tsv` | Discovered `input` directory locations, preceded by a header signing the settings that shaped the walk | Rediscovery on the next cycle |
| `<key>.leaves.tsv` | Settled mtimes per directory, with a format-version header | One full re-read cycle |
| `<key>.deepscan` | Timestamp of the last deep pass | An immediate deep pass |

The provenance record is `logs/<key>/audit.log`, not a state file: one line per
file that actually moved, carrying the outcome, the mirrored relative path, the
archive path, the hash, the size, and — on an overwrite — the digest that was
replaced. It rotates like the other logs.

There is deliberately no separate "target" field: the deployment tree mirrors the
source, so the relative path is identical on both sides by construction, and the
two roots are logged once per run in the `TARGET` line.

> **Nothing in `state/` drives a correctness decision.** Earlier versions kept a
> ledger used to decide whether a file had already been handled; with move
> semantics that is a trap — a file skipped on the strength of a ledger entry is
> never copied, therefore never removed, and stays in its pickup directory
> forever. "Does the destination already hold this content?" is answered by
> hashing the destination, the only answer that survives a crash.

---

## §12 — Observability

### Logs

One structured line per event, as key/value text or JSON. Values that may
contain tabs, newlines or `%` are escaped reversibly. Three destinations:

- `logs/_run.log` — orchestration: start, targets loaded, heartbeat, summary.
- `logs/<key>/operations.log` — everything concerning one target.
- `logs/<key>/audit.log` — append-only trail, one line per file moved:
  `action=` is the outcome (`DEPLOYED`, `DEPLOYED_OVERWRITE`,
  `DEPLOYED_IDENTICAL`), plus `relpath=`, `archive=`, `hash=`, `size=` and
  `prev_hash=` when an overwrite replaced something.

Every line carries a `run=` correlating the execution; target lines also carry
`project=`, `env=` and `cycle=`.

### Events to alert on

| Event | Operational meaning |
|---|---|
| `DEPLOY_UNAVAILABLE` | The destination is not there. Nothing is moving. |
| `DEPLOY_FAILED` | Write refused. The data is not delivered. |
| `SOURCE_STUCK` | Delivered, but the source is not draining. |
| `SOURCE_NOT_WRITABLE` | A whole directory cannot be drained. |
| `MOUNT_MISSING` | Source unavailable; the log gives the deepest existing ancestor. |

### Exit codes

| Code | Meaning | Expected action |
|---|---|---|
| `0` | Success | — |
| `1` | Configuration error | Fix `file-deploy.conf` or `targets.tsv` |
| `2` | No usable target | Check the source mounts |
| `3` | Lock busy | None — expected on every cron tick |
| `4` | A deployment write failed | Repair the destination |
| `5` | File delivered but not removed from the source | Fix permissions on the pickup share |

Precedence: no usable target, then deployment failure, then source stuck.
Undelivered data outranks delivered-but-not-drained.

---

## §13 — Execution

A run acquires a non-blocking `flock` on `run.lock`, then loops for up to
`RUN_DURATION` seconds, waking each target every `scan_interval`. A second
instance exits immediately with `3`. One cron entry per minute therefore
suffices to restart the loop if it died, without ever causing an overlap.

`--rediscover` drops a marker and exits: the running loop forces a full
rediscovery and a deep pass on its next cycle.

> **Commissioning.** Every new target is rehearsed first with `DRY_RUN=true`,
> reading the `WOULD_MOVE` lines one by one. This tool deletes from the source: a
> wrong `source_root` cannot be recovered from the logs.

---

## §14 — Upgrading from copy mode

| Item | Behaviour |
|---|---|
| `leaves.tsv` cache | Carries a format version. The old cache is rejected — otherwise every pickup directory would look "unchanged" since the last copy-mode run and the backlog would not be drained. |
| Old `ledger.tsv` | No longer read or written. Left on disk; delete it at leisure. |
| Backlog in the source | **Every file still present will be deployed then removed**, in a single pass. That is the intended behaviour, but it must be a deliberate decision — rehearse with `DRY_RUN=true`. |
| `targets.tsv` column 4 | Renamed `deploy_root`. Positional: no format change. |
| Versioning | **B is no longer a version store.** A changed file now overwrites; history lives in the local archive. |
| `REQUIRE_MOUNT` | Removed. It only ever selected a log level, never a behaviour; the source guard has always been unconditional. A leftover setting in `file-deploy.conf` is harmless and ignored. |

---

## §15 — Out of scope

- **No retention.** Local archives grow without bound, on the *source* share,
  and nothing purges them. Pickup shares need a retention policy of their own.
- **No mounting.** Shares are assumed mounted; file-deploy observes their state and
  refuses to act when in doubt.
- **No capture guarantee.** file-deploy polls, it does not lock the producer. A file
  whose lifetime is shorter than one `SCAN_INTERVAL` can be missed.
- **No concurrent consumer.** file-deploy is what empties the pickup directories. If
  another process removes files from them, file-deploy simply never sees them.
- **No multi-file transaction.** The transaction covers one file; there is no
  atomic batch.
