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
| `INPUT_DIR_NAME` | `input` | exact name of the scanned directory |
| `SCAN_INTERVAL` | `10` | seconds between internal passes |
| `RUN_DURATION` | `55` | max seconds per cron run (keep < 60) |
| `MIN_STABLE_AGE` | `5` | min file age before it is archived |
| `REQUIRE_MOUNT` | `true` | skip a target whose source is missing/unreadable |
| `DISCOVERY_INTERVAL` | `1800` | seconds between full-tree rediscoveries |
| `USE_DIR_MTIME_SKIP` | `true` | skip directories whose mtime is unchanged |
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
- `project`/`env` also name the per-target state and logs, and appear as
  correlation fields in every log line.

## How it works

Each cron run acquires the lock, then loops for up to `RUN_DURATION` seconds,
scanning every enabled target once per `SCAN_INTERVAL`. For each target it:

1. finds the `input` directories (cached; full-tree walk only every
   `DISCOVERY_INTERVAL`);
2. skips directories whose mtime is unchanged, otherwise lists their direct
   files;
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

- `logs/<project>__<env>/operations.log` — per-target operational log.
- `logs/<project>__<env>/audit.log` — per-target append-only archive trail.
- `logs/_run.log` — orchestration events (`START`, `CONFIG`, `TARGETS_LOADED`,
  `RUN_SUMMARY`, `END`, `LOCK_BUSY`).
- `logs/cron.err` — raw stderr captured by cron (last-resort safety net).

Every operational line carries `run`, `project`, `env`, `cycle` correlation ids.

Event glossary: `TARGET_BEGIN`, `MOUNT_MISSING`, `DISCOVERY`, `FORCE_REDISCOVER`,
`SKIP_DIR_UNCHANGED`, `DIR_RESCAN`, `SKIP_UNSTABLE`, `SKIP_LEDGER`,
`SKIP_SAME_HASH`, `COPIED`, `VERSIONED`, `COPY_FAILED`, `LEDGER_CORRUPT`,
`CYCLE_SUMMARY`, `TARGET_SUMMARY`.

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
