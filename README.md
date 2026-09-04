# file-deploy

Drain `input` directories on a mounted NAS share: **deploy** each file into a
mirror tree, then **move it out** of the source into a local `archive/` beside
where it came from. Cron-driven, pure Python, no dependencies to install.

> ⚠️ **file-deploy deletes from the source.** Rehearse every new configuration with
> `DRY_RUN=true` before enabling it. A wrong `source_root` is not recoverable
> from the logs.

```
before                             after
─────────────────────────────      ────────────────────────────────────────────
A/proj/input/report.xml            A/proj/input/archive/report.xml     (moved)
B/proj/input/            (empty)   B/proj/input/report.xml          (deployed)
```

- **A** — the source share. Files land in `input` directories; file-deploy drains
  them. What it takes out is not deleted, it is renamed one level down into
  `archive/`.
- **B** — the deployment tree. Mirrors the source layout and holds the
  **current** state: a changed file overwrites, and says so. Version history
  lives in A's `archive/`, not here.

**[SPEC.md](SPEC.md) is the normative reference** — the per-file transaction, the
failure matrix, the guards and every configuration key. This README is the
operator's guide.

## Requirements

**Python 3.9 or newer, standard library only** — nothing to install. Plus `cron`
to schedule it.

```
file-deploy.sh   thin launcher: picks the interpreter, hands off to deploy.py
deploy.py        the whole program: CLI, lock, discovery, the transaction, logs
engine.py        the pure core: config, conflict policy, naming rule, encoders
```

No daemon, no systemd, no external service. A locally mounted SMB/CIFS share is
assumed to already exist; mounting it is out of scope. Set `FILE_DEPLOY_PYTHON`
if `python3` on `PATH` is not the interpreter you want.

## Install

```sh
cp file-deploy.conf.example compta-prod.conf
# edit it, then check it before it ever touches your files
./file-deploy.sh --config compta-prod.conf --check
```

`--check` validates the configuration, prints the resolved paths and scans
nothing. It reports **every** problem at once rather than stopping at the first.
`logs/` and `state/` are created on first run, namespaced by `INSTANCE_ID`.

## Configure

**One configuration file describes one pair**: a source root and a deployment
root. To handle another pair, write another file and give it its own run.

```sh
cp file-deploy.conf.example compta-prod.conf
```

The format is `NAME = value`, one per line, `#` for comments; quotes are
optional and lists are comma-separated. Unknown names and bad values are refused.

```
INSTANCE_ID = compta-prod              # identity; everything hangs off it
SOURCE_DIR  = /mnt/nas/compta          # root searched for input/ directories
DEPLOY_DIR  = /mnt/nas/deploy/compta   # root receiving the mirror
MIN_STABLE_AGE = 10                    # safety: see below
```

`SOURCE_DIR` is a **root**, not the pickup directory: file-deploy looks under it
for directories named `INPUT_DIR_NAME` (`input` by default) at any depth, and
drains those. The deployment tree receives the same relative paths.

```
SOURCE_DIR/projA/input/facture.xml  ->  DEPLOY_DIR/projA/input/facture.xml
SOURCE_DIR/projB/input/sub/bl.txt   ->  DEPLOY_DIR/projB/input/sub/bl.txt
```

`INSTANCE_ID` is what makes two configurations independent: the state, log and
lock paths are derived from it, so they cannot collide and two configurations
run in parallel rather than serialising.

```
state/compta-prod/   logs/compta-prod/   run-compta-prod.lock
state/rh-homol/      logs/rh-homol/      run-rh-homol.lock
```

Override `STATE_DIR`, `LOG_DIR` and `LOCK_FILE` only to move them elsewhere, and
keep them distinct per configuration — a shared `STATE_DIR` is refused at
startup, but a shared `LOCK_FILE` would silently serialise instead.

The rest is documented inline in
[`file-deploy.conf.example`](file-deploy.conf.example); the full table is in
[SPEC.md §9](SPEC.md#9--configuration). The three worth deciding before you
start:

| Setting | Why it matters |
|---|---|
| `MIN_STABLE_AGE` | **Safety.** A file is only taken once untouched for this long. `0` is safe only if every producer writes elsewhere and renames into place — most NAS producers do not. See [SPEC.md §8.3](SPEC.md#83-stability-and-in-place-writes). |
| `ON_CONFLICT` | What to do when the destination already holds the same path with **different** content: `overwrite` (default, source wins), `version` (keep both), `skip` (destination wins, source still drained), `retry` (leave both, try again next cycle), `fail` (keep the source, exit 4). Identical content is never a conflict. |
| `REPORT_DIR` | Set it to get one CSV row per file moved, one file per day, ready for a BI tool. See [Reporting](#reporting). |

## Rehearse, then enable

```sh
# 1. rehearse: nothing is written, nothing is deleted
./file-deploy.sh --config compta-prod.conf --once --dry-run --verbose

# 2. read every WOULD_MOVE line: the relative path, the deployment verdict
#    (DEPLOYED / DEPLOYED_OVERWRITE / DEPLOYED_IDENTICAL) and the archive path
grep WOULD_MOVE logs/*/operations.log

# 3. same command without --dry-run, for real
./file-deploy.sh --config compta-prod.conf --once --verbose
```

`--dry-run` is the flag form of `DRY_RUN=true`; the flag is applied after the
config is read, so it always wins. Prefer it over editing the config: a
rehearsal left switched on looks exactly like a healthy run that never delivers
anything. Whenever it is active — from either source — the run logs
`DRY_RUN_ACTIVE` at `WARN` so monitoring can catch it.

Check the result: the pickup directory holds only `archive/`, the deployment
tree mirrors it, and `state/<INSTANCE_ID>/deployed` exists.

## Run with cron

The scanner runs **continuously** — an internal loop scanning every
`SCAN_INTERVAL` — so there is no gap between minutes. One cron entry per minute
acts as a **watchdog**: if the process dies the next tick restarts it, and the
internal `flock` guarantees a single instance. No root, no systemd.

One entry per configuration; they run in parallel, each with its own lock.

```cron
* * * * * /opt/file-deploy/file-deploy.sh --config /opt/file-deploy/compta-prod.conf >> /opt/file-deploy/cron.err 2>&1
* * * * * /opt/file-deploy/file-deploy.sh --config /opt/file-deploy/rh-homol.conf   >> /opt/file-deploy/cron.err 2>&1
```

With `RUN_DURATION` set high (e.g. 24 h) the loop recycles about once a day. The
every-minute `LOCK_BUSY` from the watchdog is expected and logged at `DEBUG`
only. `cron.err` should stay empty; anything in it is a real crash.

## Logs and troubleshooting

```
logs/<INSTANCE_ID>/file-deploy.log   everything: startup, per-file events, heartbeat, summary
logs/<INSTANCE_ID>/audit.log         append-only trail of what moved, with outcome and hashes
```

Every line carries `run=` to correlate an execution and `instance=` to name the
configuration. `LOG_FORMAT=json` emits the same fields as JSON.

**Nothing is being deployed?** Run `--once --debug`, which turns on every event
and mirrors it to the terminal. The likely answers, in order:

| Event | Meaning |
|---|---|
| `MOUNT_MISSING` | The source is not there. `deepest_existing=` shows how far the path resolves before it breaks — an unmounted share resolves shallow. |
| `NO_INPUT_DIRS` | The source is fine but no directory matches `input_dir_name`. Names are exact, case-sensitive and comma-separated. |
| `DEPLOY_UNAVAILABLE` | The deployment root is missing or empty and the sentinel is gone. Treated as an unmounted share: nothing written, nothing removed. |
| `SOURCE_NOT_WRITABLE` | A pickup directory lacks `w+x`. file-deploy refuses to deploy out of a directory it cannot then drain. |
| `SKIP_UNSTABLE` | The file is younger than `MIN_STABLE_AGE`. |
| `SKIP_DIR_UNCHANGED` | The directory mtime has not moved. A deep pass (`DEEP_SCAN_INTERVAL`) recovers a share that fails to update it. |
| `DEPLOY_SKIPPED` / `DEPLOY_CONFLICT` | The destination holds different content and `ON_CONFLICT` is `skip` or `fail`. |

**Alert on** `DEPLOY_UNAVAILABLE`, `DEPLOY_FAILED`, `SOURCE_STUCK`,
`SOURCE_NOT_WRITABLE` and `MOUNT_MISSING`, and on `errors=` in `RUN_SUMMARY`.

Exit codes: `0` success · `1` config error · `2` no usable target · `3` lock
busy, same configuration already running · `4` a deployment write failed · `5` a file
was deployed but could not leave the source. **`4` means data was not
delivered; `5` means it was delivered but the source is filling up.** Both
deserve their own alert.

`--rediscover` drops a marker and exits; the running loop re-walks the source and
forces a deep pass on its next cycle.

## Reporting

Set `REPORT_DIR` and every file that moves appends a row to
`<REPORT_DIR>/file-deploy-<YYYY-MM-DD>.csv` — one file per day, every target in
it. In Power BI: **Get Data → Folder →** point at `REPORT_DIR` → **Combine &
Transform**, and new days append themselves on refresh.

18 columns, including `archive_path` (where the file actually is now, so you can
retrieve it), `relpath` (identical on both sides, the natural join key),
`prev_hash` (what an overwrite replaced) and `age_at_pickup_s` (how long a file
waited before being taken — a latency KPI). Every column is documented in
[`file-deploy.conf.example`](file-deploy.conf.example).

Two things to know: `source_created` is a real birth time and is **empty** on
filesystems that do not record one — CIFS/SMB usually does not, so build on
`source_modified`. And `REPORT_DELIMITER=";"` if your Excel/Power BI locale
expects semicolons.

A row that cannot be written is **queued locally and replayed**, not dropped:
by then the file has already been drained, so nothing else could reconstruct it.
Watch for `REPORT_SPOOLED` (queued) and `REPORT_SPOOL_FLUSHED` (recovered), and
alert on `REPORT_ROW_LOST` — the only case where a row is genuinely gone, which
takes both `REPORT_DIR` and the local spool being unwritable.

Nothing is written during a rehearsal, so `--dry-run` stays inert.

## Operating notes

- **The local archives grow without bound**, on the *source* share, and nothing
  purges them. That is deliberate, but the pickup shares need a retention policy
  of their own. Monitor their disk usage alongside the deployment tree.
- **file-deploy is the consumer.** Nothing else should be removing files from
  `input`; if something does, file-deploy simply never sees those files.
- **Permissions**: the cron user needs read access to the source, **write**
  access to each pickup directory (unlinking a file needs `w+x` on its parent)
  and to each `deploy_root`. No root required.
- **State lives in `STATE_DIR`** and none of it is required for correctness — see
  [SPEC.md §11](SPEC.md#11--persistent-state).

## Testing

Standard library `unittest`, no external dependency:

```sh
python3 -m unittest discover -s tests -v
```

`tests/test_engine.py` unit-tests the pure core — the naming rule, the conflict
policy, the encoders, the configuration parser. `tests/test_e2e.py` builds
isolated sandboxes, runs the real entry point as a subprocess and asserts on the
filesystem, the logs and the exit codes.

The suite deliberately leads with the no-loss properties: an unwritable or
unmounted destination, an unreadable file, a rehearsal and a file rewritten
mid-copy must all leave the source intact.

## License

MIT — see [LICENSE](LICENSE).
