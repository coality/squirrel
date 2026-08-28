# squirrel

Copy files dropped into `input` directories on a mounted NAS share into a mirror
archive tree — **exactly once**, with content-hash deduplication. Driven by cron.

The source tree is treated as **strictly read-only**: the script only reads and
copies, it never modifies or deletes a source file.

## Features

- **Multi-target**: many `(project, environment)` pairs, each with its own
  source and archive roots, described in a simple tab-separated `targets.tsv`.
- **Exact mirror**: a file at `<source>/a/b/input/test.xml` is copied to
  `<archive>/a/b/input/test.xml`.
- **Extra directories**: besides the discovered `input` trees, archive one or
  more **specific directories to specific destinations** (no discovery, per-rule
  depth) via `EXTRA_DIRS` — see [Extra directories](#extra-directories-specific-source--destination).
- **What is collected**: for each `input` directory, the files **directly inside it**
  *and* the files **directly inside its direct sub-directories** (e.g.
  `input/supplier/`). Deeper levels are never scanned — `input/supplier/archive/`
  is ignored. Sub-directories are re-checked every cycle (a new one is picked up
  immediately); new `input` directories themselves are found at discovery
  (`DISCOVERY_INTERVAL` or `--rediscover`). Directories whose name matches
  `EXCLUDE_DIR_PATTERNS` (case-insensitive globs) are skipped entirely and never
  descended into.
- **Archive once, dedup by hash**:
  - never seen → copied under its own name;
  - same name **and** same content hash → nothing to do;
  - same name, **different** content → copied as `test_YYYYMMDD_HHMMSS.xml`
    (the previous archived version is kept).
- **In-progress safe**: a file is archived only once it has been stable for
  `MIN_STABLE_AGE` seconds, so partially written files are never archived.
- **Minimal disk I/O**: input directory locations are cached and only
  rediscovered periodically; a directory whose modification time has not
  changed is skipped without listing it.
- **Production logging, per target**: one operations log and one append-only
  audit log per target, with correlation ids, rotation, text or JSON output.
- **Safe concurrency**: an internal `flock` prevents overlapping cron runs.

## Requirements

Only very basic, universally available Linux tools — **nothing to install**:

- `bash` >= 4
- GNU coreutils: `stat`, `cp`, `mv`, `mkdir`, `date`, `sha256sum`
- `find` (GNU findutils, or any compatible implementation)
- `flock` (util-linux)
- `cron`

Works the same on RedHat/CentOS/Rocky, Debian/Ubuntu, Slackware, SUSE, Arch, …
No systemd, no external services. A locally mounted SMB/CIFS share is assumed to
already exist (mounting the share is out of scope).

## Install

```sh
cp squirrel.conf.example squirrel.conf
cp targets.tsv.example targets.tsv
mkdir -p logs state          # created on first run too, but the cron line below writes to logs/
# edit squirrel.conf and targets.tsv to match your environment
```

## Configuration

### `squirrel.conf`

Global defaults, sourced by the script. See `squirrel.conf.example` for the
full list. Most-used options:

| Option | Default | Meaning |
|---|---|---|
| `INPUT_DIR_NAME` | `input` | exact name(s) of the scanned directory; several allowed, space/comma-separated (case-sensitive, no globs), e.g. `"input Input input_"` |
| `SCAN_INTERVAL` | `10` | seconds between internal passes |
| `RUN_DURATION` | `55` | max seconds per cron run (keep < 60) |
| `MIN_STABLE_AGE` | `5` | min file age before it is archived |
| `REQUIRE_MOUNT` | `true` | skip a target whose source is missing/unreadable |
| `DISCOVERY_INTERVAL` | `1800` | seconds between full-tree rediscoveries |
| `DISCOVERY_MAXDEPTH` | `0` | cap the discovery walk depth (0 = unlimited) |
| `USE_DIR_MTIME_SKIP` | `true` | skip directories whose mtime is unchanged |
| `EXCLUDE_DIR_PATTERNS` | `()` | dir-name globs (case-insensitive) to ignore anywhere, e.g. `('*archived*')` |
| `EXTRA_DIRS` | `()` | explicit `label⇥source⇥destination⇥depth` rules (see [Extra directories](#extra-directories-specific-source--destination)) |
| `HASH_CMD` | `sha256sum` | content hash command |
| `DRY_RUN` | `false` | simulate without writing anything |
| `LOG_LEVEL` | `INFO` | `DEBUG`/`INFO`/`WARN`/`ERROR` |
| `LOG_FORMAT` | `text` | `text` or `json` |
| `LOG_ROTATE_MAX_BYTES` | `10485760` | rotate a log past this size (0 = never) |
| `LOG_ROTATE_KEEP` | `7` | rotated files kept |

### `targets.tsv`

One line per `(project, environment)`, **tab-separated** (so paths may contain
spaces). Use `-` or an empty field to inherit the global default. Lines starting
with `#` are comments.

```
# project   env    source_root                 archive_root                       input_dir_name  scan_interval  enabled
projectA     prod   /mnt/nas/projectA/prod      /mnt/nas/archive/projectA/prod     input           10             true
projectB     prod   /mnt/nas/projectB/prod      /mnt/nas/archive/projectB/prod     -               -              true
```

- Required columns: `project`, `env`, `source_root`, `archive_root`.
- Optional (inherit the default if `-`): `input_dir_name`, `scan_interval`, `enabled`.
  `input_dir_name` may list **several exact names** (space- or comma-separated,
  case-sensitive, no globs), e.g. `input Input input_` — a directory is scanned
  if its name matches any of them.
- `project`/`env` also name the per-target state and logs, and appear as
  correlation fields in every log line.

### Extra directories (specific source → destination)

`targets.tsv` describes trees to *scan* for `input` directories. When you instead
want to archive **one specific directory to one specific place** — with no
discovery — declare it in `EXTRA_DIRS` in `squirrel.conf`. Each rule is a
tab-separated array element (paths may contain spaces):

```
label ⇥ source ⇥ destination ⇥ depth
```

```sh
EXTRA_DIRS=(
  $'reports\t/mnt/nas/app/reports\t/mnt/nas/archive/reports\t2'
  $'daily\t/mnt/nas/daily out\t/mnt/nas/archive/daily\t0'
  $'exports\t/mnt/nas/app/exports\t/mnt/nas/archive/exports\tunlimited'
)
```

- **`label`** — the rule's identity. Its ledger and logs live under
  `<label>__extra` (`state/<label>__extra.ledger.tsv`, `logs/<label>__extra/`),
  exactly like a `(project, env)` target. Must be unique.
- **`source`** — the exact directory to archive (a fixed path; no `input` lookup).
- **`destination`** — where content is mirrored: `<source>/sub/f` →
  `<destination>/sub/f`.
- **`depth`** — how deep to go: `0` = only files directly in `source`; `N` = also
  `N` sub-levels deep (`1` matches the `input` scanner); `-1` (or `unlimited` /
  `inf` / `all`) = the whole subtree. Empty or `-` defaults to `1`.

Extra directories go through the **same engine** as targets — content-hash
deduplication, timestamped versioning, `MIN_STABLE_AGE` stability,
`EXCLUDE_DIR_PATTERNS`, `DRY_RUN`, per-rule operations/audit logs and the mount
guard — and appear in `HEARTBEAT` / `RUN_SUMMARY` alongside regular targets. They
are **additive**: they run whether or not `targets.tsv` has any enabled target.

## How it works

Each cron run acquires the lock, then loops for up to `RUN_DURATION` seconds,
scanning every enabled target once per `SCAN_INTERVAL`. For each target it:

1. locates the `input` directories (cached; full-tree walk only every
   `DISCOVERY_INTERVAL`, pruned at each input so it never walks their subtrees —
   a new `input` dir is seen at the next rediscovery or via `--rediscover`);
2. each cycle, one bulk directory read per `input` returns the input and its
   direct sub-directories with their mtimes in a single round-trip; unchanged
   dirs are skipped, the rest have their direct files listed (each file lands in
   the mirror under `…/input/…` or `…/input/<subdir>/…`). A new sub-directory is
   picked up on the next cycle;
3. for each file: skips it if too recent (stability), or already archived
   (per-target ledger); otherwise hashes it and copies new content into the
   mirror (base name, or a timestamped version), appending to the ledger and
   the audit log.

Copies are atomic (`cp` to a temporary name, then `mv`), so an interrupted run
never leaves a partial archive file. The source is never written to.

### Capture reliability

This tool is a passive, read-only poller: it captures a file only while the file
is still present. Whether every file is archived before an external consumer
removes it depends on timing:

- The scanner runs **continuously** (an internal loop every `SCAN_INTERVAL`
  seconds), so a new file is seen within roughly one `SCAN_INTERVAL` — there is
  no per-minute gap.
- If files are written **atomically** (temp then rename/mv into `input`), set
  `MIN_STABLE_AGE=0` so there is no extra delay before archiving.
- Capture is reliable as long as a file stays in `input` longer than one
  `SCAN_INTERVAL` before the consumer moves it. With `SCAN_INTERVAL=2` and a
  consumer that sweeps every ~30 minutes, even a file dropped a few seconds
  before a sweep is captured.
- Idle passes only `stat` each input directory (no listing, no file reads, no
  tree walk), so scanning every couple of seconds stays cheap even over a NAS.
- The directory-mtime skip **assumes the NAS updates a directory's modification
  time when a file is added**. Most SMB/CIFS servers do; verify it on your share,
  or set `USE_DIR_MTIME_SKIP=false` (lists every directory each pass — a bit more
  I/O but immune to that assumption).
- If new `input` directories can appear over time, set `DISCOVERY_INTERVAL` well
  below the consumer's cycle; if the set is fixed, it can stay high.

Because `input` is never written to, the tool cannot hold a file: this is
best-effort capture. A file whose entire lifetime is shorter than one
`SCAN_INTERVAL` can still be missed; a hard guarantee would require archiving in
the critical path (before the consumer can take the file).

### State

Per target, under `state/`:

- `<project>__<env>.ledger.tsv` — one line per archived version
  (`relpath, size, mtime, hash, archive_target, archived_at`). It is the source
  of truth for "already archived".
- `<project>__<env>.inputdirs.tsv` — cached input directory locations and their
  last settled mtime.

If an archived file is deleted by hand, the ledger still considers it archived
and will not re-copy it. To force re-archiving, remove the matching ledger
line(s) for that relative path (or delete the ledger to re-archive everything).

### Forcing rediscovery

Input directory locations are only refreshed every `DISCOVERY_INTERVAL`. To pick
up a newly created `input` directory immediately (without waiting), run:

```sh
./squirrel.sh --rediscover --config squirrel.conf
```

This drops a marker that the running scanner detects on its next cycle and then
does a full-tree rediscovery for every target. It does not start a scan and exits
right away, so it is safe to run while the scanner is active.

## Run with cron

The scanner runs **continuously** (internal loop scanning every `SCAN_INTERVAL`),
so there is no gap between minutes. A single cron entry every minute is a
**watchdog**: if the process ever dies (crash, reboot) the next tick restarts it,
while the internal `flock` guarantees only one instance runs. No root, no systemd.

Replace `/opt/squirrel` with your install directory:

```cron
* * * * * /opt/squirrel/squirrel.sh --config /opt/squirrel/squirrel.conf >> /opt/squirrel/logs/cron.err 2>&1
```

With `RUN_DURATION` set high (e.g. 24 h) the loop runs continuously and recycles
about once a day; the once-a-day restart gap is negligible next to a consumer
that sweeps every ~30 minutes. The every-minute `LOCK_BUSY` from the watchdog is
expected and logged only at `DEBUG`.

## Logs & troubleshooting

**Quick diagnosis** — do a single pass with everything printed to the terminal:

```sh
./squirrel.sh --config squirrel.conf --debug --once
```

It prints the resolved paths, the effective configuration, every target's
`source`/`archive`, and exactly why nothing is being archived. When a source
cannot be scanned it logs, for example:

```
event=MOUNT_MISSING src=".../homologation/Avanteam" reason="path does not exist" deepest_existing="/cifs/aldnas" require_mount="true"
```

- `reason` — what failed: missing / not a directory / not readable / not searchable.
- `deepest_existing` — how far the path resolves: if it stops at `/cifs`, the
  share is not mounted; if it resolves deep but the last component is wrong, it is
  a path typo.

Other useful signals: `NO_INPUT_DIRS` (source is fine but no directory named
`input` was found under it) and the periodic `HEARTBEAT` (`mount_missing=` shows a
loop that is stuck rather than archiving).

Log files:

- `logs/<project>__<env>/operations.log` — per-target operational log.
- `logs/<project>__<env>/audit.log` — per-target append-only archive trail.
- `logs/_run.log` — orchestration events (`START`, `PATHS`, `CONFIG`, `TARGET`,
  `TARGETS_LOADED`, `HEARTBEAT`, `RUN_SUMMARY`, `END`, `LOCK_BUSY`).
- `logs/cron.err` — raw stderr captured by cron (last-resort safety net).

`LOG_CONSOLE=auto` mirrors every line to the terminal when run interactively (set
`always`/`never` to force it); `LOG_LEVEL=DEBUG` adds per-file and per-directory
detail. Every operational line carries `run`, `project`, `env`, `cycle` ids.

Event glossary: `START`, `PATHS`, `CONFIG`, `CONFIG_NOT_FOUND`, `TARGET`,
`TARGETS_LOADED`, `TARGET_DISABLED`, `TARGET_MALFORMED`, `TARGET_DUPLICATE`,
`EXTRA_MALFORMED`, `EXTRA_BAD_DEPTH`, `EXTRA_DUPLICATE`,
`TARGET_BEGIN`, `MOUNT_MISSING`, `MOUNT_OK`, `DISCOVERY`, `EXCLUDED_DIR`,
`NO_INPUT_DIRS`, `FORCE_REDISCOVER`, `SKIP_DIR_UNCHANGED`, `DIR_RESCAN`, `SKIP_UNSTABLE`,
`SKIP_LEDGER`, `SKIP_SAME_HASH`, `COPIED`, `VERSIONED`, `COPY_FAILED`,
`LEDGER_CORRUPT`, `HEARTBEAT`, `CYCLE_SUMMARY`, `TARGET_SUMMARY`.

Exit codes: `0` success · `1` configuration error · `2` no usable target ·
`3` lock busy (another run is active) · `4` at least one archive copy failed.

## Production notes

- **Run it in homologation first.** Point a homolog target at the real NAS mount
  and watch `logs/` for at least one full consumer cycle before enabling any
  production target.
- **Verify the directory-mtime assumption** on your actual share (drop a file,
  check the parent directory's mtime changed). If in doubt, run with
  `USE_DIR_MTIME_SKIP=false`.
- **The archive only grows** — nothing is ever deleted. Monitor archive disk
  usage; the per-target ledger and `audit.log` grow over time too.
- **Monitor errors**: alert on `COPY_FAILED`, `MOUNT_MISSING` and `LEDGER_CORRUPT`
  in the logs, and on `errors=` in `RUN_SUMMARY` / `CYCLE_SUMMARY`.
- **Permissions**: the cron user needs read access to the NAS mount and write
  access to each `archive_root`. No root required.

## Testing

Pure-bash end-to-end suite, no external dependency:

```sh
bash tests/run-e2e.sh
```

It builds isolated sandboxes, runs the real script against them, and asserts on
the filesystem, the logs and the exit codes. A non-zero exit means a test failed.

## License

MIT — see [LICENSE](LICENSE).
