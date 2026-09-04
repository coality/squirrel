# file-deploy — move-mode specification

**Revision 3** · Python ≥ 3.9 · 2026-09-04

file-deploy drains pickup directories on a mounted NAS share: it **deploys** each
file into a mirror tree, then **moves it out** of the source, keeping it in a
local archive.

This document is normative — it states what the implementation does and why each
guard exists. The [README](README.md) is the operator's guide.

---

## §1 — Scope

file-deploy is a cron-driven Python program. **One configuration file
describes one pair**: a source root and a deployment root. Under the source root
it locates directories with a given name (`input` by default), and for every
file found there it runs the transaction of
[§5](#5--the-per-file-transaction): verified deployment, then removal from the
source.

```
before                             after
─────────────────────────────      ────────────────────────────────────────────
A/proj/input/report.xml            A/proj/input/archive/report.xml     (moved)
B/proj/input/            (empty)   B/proj/input/report.xml          (deployed)
```

To handle another pair, write another configuration file and give it its own
run. There is no multi-target file: a configuration is the unit of isolation,
of scheduling and of failure.

Requires **Python 3.9 or newer and nothing else** — standard library only. The
program is `deploy.py`; `engine.py` holds the parts that can be decided without
touching the tree (configuration, conflict policy, naming rule, encoders), and
`file-deploy.sh` is a thin launcher that only picks the interpreter. No daemon,
no systemd, no external service. Mounting the shares is out of scope: file-deploy
observes their state and refuses to act when in doubt.

---

## §2 — Terms

| Term | Definition |
|---|---|
| **Source (A)** | The configuration's `SOURCE_DIR`. file-deploy writes to it and deletes from it — the substantive change from earlier versions. |
| **Deployment tree (B)** | The configuration's `DEPLOY_DIR`. Mirrors the source layout and carries the *current* state of what has been delivered. It is not a version store. |
| **Pickup directory** | A directory actually scanned: a discovered `input` directory, or one of its direct subdirectories. It is the immediate parent of the files processed. |
| **Local archive** | The `$LOCAL_ARCHIVE_DIR` directory (default `archive`) created *inside* the pickup directory. It receives every file taken out of the source, and is never scanned. |
| **Instance** | One configuration file, identified by `INSTANCE_ID`. It names the instance in the logs and in the CSV report, and the state, log and lock paths are derived from it — which is what makes two configurations structurally unable to share them. |
| **Cycle** | One pass over the source. A run loops for up to `RUN_DURATION` seconds, scanning every `SCAN_INTERVAL`. |
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
| The walk's own root | Never excluded by its own name | A discovered `input` directory |

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

`HASH_ALGO` (default `sha256`) computes the digest used to verify the
deployment, classify the collision, and name the archive entry.

*Unreadable* → `HASH_FAILED`; never consumed. We do not delete what we could not
read.

### 3. Deploy, verified before publication

Four separate steps, reported separately, because they fail for different
reasons and only three of them are fatal:

| Step | Fatal? |
|---|---|
| `copy-data` — the bytes, to a hidden sibling temp | yes |
| `copy-metadata` — mode and timestamps (`PRESERVE_METADATA`) | **no** |
| `verify` — re-hash what landed | yes |
| `publish` — rename into place | yes |

Metadata is a nicety, not the payload. A CIFS/SMB share routinely refuses
`chmod`/`utime` with `EPERM` while the data copied perfectly, and failing the
deployment over that would mean refusing to work at all: it is reported once per
run as `METADATA_NOT_PRESERVED` and the deployment proceeds. Verifying before
publishing is what guarantees a corrupt copy never becomes visible and never
clobbers a file that was already correct.

*Failure* → `DEPLOY_FAILED` with `deployed="no" source_kept="yes"`; the temporary
is removed and whatever was deployed stays intact.

### All-or-nothing, and its exact limit

A move spans two filesystems, so no system call can make "write to B" and
"remove from A" indivisible. What can be chosen is *which* partial state is
reachable — and this ordering makes it "present in both", never "present in
neither".

Within one cycle the transaction is nonetheless all-or-nothing, through a
two-phase commit. An overwrite destroys what is already deployed, so the previous
version is first stashed aside as a hidden sibling; if any later step fails, the
published file is removed and the stash is renamed back. The cycle then leaves
**both** trees exactly as it found them, and the log says so explicitly
(`deployed="rolled-back" source_kept="yes"`). A failure never reads as an error
while the destination quietly received the file.

The one window that cannot be closed is between draining the source and dropping
the stash: a crash there leaves a hidden stash file behind. The transaction did
complete, and the next run sweeps it (`STALE_SWEPT`).

If the stash itself cannot be restored — the only genuinely unrecoverable case —
`ROLLBACK_FAILED` names the stash file so it can be put back by hand.

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
`source_created` is a real birth time and is **empty** unless the platform
exposes one to Python — macOS and the BSDs do, **Linux does not, whatever the
filesystem**. Treat it as a bonus and build on `source_modified`. `age_at_pickup_s` is `now − mtime` at pickup, a latency measure of how
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
| `DEPLOY_FAILED` | ERROR | `stage=mkdir\|stash-previous\|copy-data\|verify\|publish` | **Kept** | Previous version intact, rolled back if needed | 4 | Retried |
| `SOURCE_CHANGED_DURING_COPY` | WARN | Writer racing the copy | **Kept** | **Rolled back** — no truncated version left | 0 | Converges on the final content |
| `ARCHIVE_DIR_FAILED` | ERROR | Local archive cannot be created | **Kept** | **Rolled back** | 5 | Retried |
| `SOURCE_STUCK` | ERROR | the source could not be drained | **Kept** | **Rolled back** — unchanged | 5 | Idempotent retry, no duplicate |

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

"Deployed here before" is recorded by `STATE_DIR/deployed`, written on the
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
| `SOURCE_DIR` | — | **Required.** Root searched for `input` directories |
| `DEPLOY_DIR` | — | **Required.** Root receiving the mirror |
| `INSTANCE_ID` | config base name | Identity; the state, log and lock paths derive from it |
| `INPUT_DIR_NAME` | `"input"` | Exact names, comma-separated, matched literally |
| `SCAN_INTERVAL` | `10` | Seconds between internal passes |
| `RUN_DURATION` | `55` | Maximum duration of one run |
| `MIN_STABLE_AGE` | `5` | **Safety setting** — see §8.3 |
| `LOCAL_ARCHIVE_DIR` | `"archive"` | Name of the local archive; `""` disables it |
| `ON_CONFLICT` | `"overwrite"` | `overwrite` / `version` / `skip` / `retry` / `fail` when the destination holds different content — see [§6](#6--naming) |
| `REPORT_DIR` | `""` | Directory receiving the daily CSV of everything that moved; `""` disables it |
| `REPORT_DELIMITER` | `","` | CSV field separator (`";"` for a French-locale Excel/Power BI) |
| `DEPLOY_MARKER` | `".file-deploy-root"` | Deployment-root sentinel |
| `HASH_ALGO` | `"sha256"` | Any algorithm `hashlib` knows |
| `PRESERVE_METADATA` | `yes` | Carry mode and timestamps over; never fatal |
| `DRY_RUN` | `false` | Inert rehearsal: no write, no delete |
| `DISCOVERY_INTERVAL` | `1800` | Seconds between full rediscoveries |
| `DISCOVERY_MAXDEPTH` | `0` | Depth cap; 0 = unlimited |
| `USE_DIR_MTIME_SKIP` | `true` | Skip a directory whose mtime has not moved |
| `DEEP_SCAN_INTERVAL` | `300` | Seconds between passes ignoring that skip |
| `EXCLUDE_DIR_PATTERNS` | `()` | Case-insensitive globs to ignore anywhere |

| `LOG_LEVEL` | `"INFO"` | `DEBUG` / `INFO` / `WARN` / `ERROR` |
| `LOG_FORMAT` | `"text"` | `text` or `json` |
| `LOG_CONSOLE` | `"auto"` | Mirror log lines to stderr: `auto` (when interactive), `always`, `never` |
| `LOG_MAX_BYTES` | `10485760` | Rotate past this; 0 = never |
| `LOG_KEEP` | `7` | Rotated files kept |
| `AUDIT_LOG` | `true` | Per-target provenance trail |
| `HEARTBEAT_INTERVAL` | `60` | Periodic summary; 0 = off |
| `STATE_DIR` | `state/<INSTANCE_ID>` | Optional override — see [§10](#10--configuration-files-and-isolation) |
| `LOG_DIR` | `logs/<INSTANCE_ID>` | Optional override |
| `LOCK_FILE` | `run-<INSTANCE_ID>.lock` | Optional override |

The file is `NAME = value`, one per line, `#` for comments; quotes are optional
and lists are comma-separated. An unknown name or an unusable value is a
configuration error, never a guess, and **every** problem is collected so one
`--check` reports the lot.

Command-line options: `--config FILE` (`-c`), `--dry-run` (`-n`), `--once`,
`--check`, `--rediscover`, `--debug`, `--verbose` (`-v`), `--help`. `--dry-run`,
`--once`, `--debug` and `--verbose` are applied *after* the file is read, so a
flag cannot be overridden by it. `--check` validates, prints the resolved paths
and scans nothing.

A rehearsal is inert in both directions: it writes nothing to the source or the
deployment tree, and it records nothing that would change a later run — no
settled-mtime cache, no deep-pass timestamp. Whenever it is active, from the
flag or from the config, the run logs `DRY_RUN_ACTIVE` at `WARN`, because a
rehearsal left switched on is indistinguishable from a healthy run that never
delivers anything.

---

## §10 — Configuration files and isolation

One configuration file = one source/destination pair = one instance. Run it once
per pair:

```sh
file-deploy.sh --config /etc/file-deploy/compta-prod.conf
file-deploy.sh --config /etc/file-deploy/rh-homol.conf
```

`INSTANCE_ID` is the configuration's identity. It defaults to the file's base
name (`compta-prod.conf` → `compta-prod`), accepts `[A-Za-z0-9._-]` only, and an
invalid value is a configuration error (exit `1`).

Everything an instance owns hangs off it:

| Path | Default |
|---|---|
| `STATE_DIR` | `<script dir>/state/<INSTANCE_ID>` |
| `LOG_DIR` | `<script dir>/logs/<INSTANCE_ID>` |
| `LOCK_FILE` | `<script dir>/run-<INSTANCE_ID>.lock` |

That is the isolation mechanism, not a convenience: two configurations sharing a
`STATE_DIR` would each mistake the other's caches and its "deployed here before"
marker for their own, and a shared `LOCK_FILE` would make them serialise instead
of running in parallel. The defaults make both impossible.

The paths can still be overridden — to put them under `/var/lib` and `/var/log`,
typically. A `STATE_DIR` already claimed by a different instance is then
**refused at startup** (`STATE_DIR_CONFLICT`, exit `1`), before anything moves;
`STATE_DIR/.instance` records the owner. A shared `LOCK_FILE` cannot be detected
the same way — it just looks like a busy lock — so keep them distinct.

`SOURCE_DIR` and `DEPLOY_DIR` are both required; a configuration missing either
is refused (exit `1`).

## §11 — Persistent state

Five files per instance, under `STATE_DIR`. **None is required for correctness.**

| File | Content | If deleted |
|---|---|---|
| `.instance` | The `INSTANCE_ID` owning this directory | The next run reclaims it; the cross-instance guard of [§10](#10--configuration-files-and-isolation) is disarmed until then |
| `deployed` | Empty marker, written on the first successful move | §8.1 loses its "we have deployed here before" signal, so a vanished destination looks like a first run |
| `inputs.tsv` | Discovered `input` directory locations, preceded by a header signing the settings that shaped the walk | Rediscovery on the next cycle |
| `leaves.tsv` | Settled mtimes per directory, with a format-version header | One full re-read cycle |
| `deepscan` | Timestamp of the last deep pass | An immediate deep pass |

The provenance record is `LOG_DIR/audit.log`, not a state file: one line per
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

- `LOG_DIR/file-deploy.log` — everything: startup, per-file events, heartbeat,
  summary. One configuration means one target, so there is no second stream to
  keep it apart from.
- `LOG_DIR/audit.log` — append-only trail, one line per file moved:
  `action=` is the outcome (`DEPLOYED`, `DEPLOYED_OVERWRITE`,
  `DEPLOYED_IDENTICAL`), plus `relpath=`, `archive=`, `hash=`, `size=` and
  `prev_hash=` when an overwrite replaced something.

Every line carries `run=` to correlate an execution and `instance=` to name the
configuration; per-cycle lines also carry `cycle=`.

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
| `1` | Configuration error | Fix the configuration file |
| `2` | The source is missing, unreadable or not writable | Check the source mount and its permissions |
| `3` | Lock busy | None — expected on every cron tick |
| `4` | A deployment write failed | Repair the destination |
| `5` | File delivered but not removed from the source | Fix permissions on the pickup share |

Precedence: unusable source, then deployment failure, then source stuck.
Undelivered data outranks delivered-but-not-drained.

---

## §13 — Execution

A run acquires a non-blocking `flock` on the instance's `LOCK_FILE`, then loops
for up to `RUN_DURATION` seconds, scanning every `SCAN_INTERVAL`. A second run of
the *same* configuration exits immediately with `3`; a different configuration
has a different lock and runs in parallel. One cron entry per minute per
configuration therefore suffices to restart a loop that died, without ever
causing an overlap.

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
| `targets.tsv` | Gone. One configuration describes one pair; write one file per pair and run each. `EXTRA_DIRS` is gone with it — it was the escape hatch for exactly this, and it is now the whole model. |
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
