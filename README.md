# file-deploy

Drain `input` directories on a mounted NAS share: **deploy** each file into a
mirror tree, then **move it out** of the source into a local `archive/` beside
where it came from. Cron-driven, single bash script, no dependencies to install.

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

Only basic, universally available Linux tools — nothing to install:

- `bash` >= 4.2
- GNU coreutils: `stat`, `cp`, `mv`, `mkdir`, `date`, `sha256sum`
- `find` (GNU findutils)
- `flock` (util-linux)
- `cron`

No systemd, no daemon, no external service. A locally mounted SMB/CIFS share is
assumed to already exist; mounting it is out of scope.

## Install

```sh
cp file-deploy.conf.example file-deploy.conf
cp targets.tsv.example  targets.tsv
# edit both to match your environment
```

`logs/` and `state/` are created on first run.

## Configure

Two files, both documented inline:

- **`file-deploy.conf`** — global defaults. Every key is explained in
  [`file-deploy.conf.example`](file-deploy.conf.example); the full table is in
  [SPEC.md §9](SPEC.md#9--configuration).
- **`targets.tsv`** — one **tab-separated** line per `(project, env)`:

  ```
  project ⇥ env ⇥ source_root ⇥ deploy_root ⇥ input_dir_name ⇥ scan_interval ⇥ enabled
  ```

  Use `-` to inherit the global default. Tabs matter: a space-aligned line is
  split on whitespace, which shifts every column after a value containing one.

The three settings worth deciding before you start:

| Setting | Why it matters |
|---|---|
| `MIN_STABLE_AGE` | **Safety.** A file is only taken once untouched for this long. `0` is safe only if every producer writes elsewhere and renames into place — most NAS producers do not. See [SPEC.md §8.3](SPEC.md#83-stability-and-in-place-writes). |
| `LOCAL_ARCHIVE_DIR` | Name of the archive created beside each drained file (default `archive`). It is matched exactly and pruned from every walk, so a directory of that name is never deployed. Rename it if that collides with a real directory in your tree. |
| `DEPLOY_MARKER` | Sentinel guarding each `deploy_root`. Leave it on: it is what stops an unmounted destination from draining your source into nothing. |

## Rehearse, then enable

```sh
# 1. see what would happen, without writing or deleting anything
./file-deploy.sh --config file-deploy.conf --once --debug   # with DRY_RUN=true

# 2. read every WOULD_MOVE line: source, target, archive path
grep WOULD_MOVE logs/*/operations.log

# 3. set DRY_RUN=false and run one pass for real
./file-deploy.sh --config file-deploy.conf --once --verbose
```

Check the result: the pickup directory holds only `archive/`, the deployment
tree mirrors it, and `state/<project>__<env>.deployed` exists.

## Run with cron

The scanner runs **continuously** — an internal loop scanning every
`SCAN_INTERVAL` — so there is no gap between minutes. One cron entry per minute
acts as a **watchdog**: if the process dies the next tick restarts it, and the
internal `flock` guarantees a single instance. No root, no systemd.

```cron
* * * * * /opt/file-deploy/file-deploy.sh --config /opt/file-deploy/file-deploy.conf >> /opt/file-deploy/logs/cron.err 2>&1
```

With `RUN_DURATION` set high (e.g. 24 h) the loop recycles about once a day. The
every-minute `LOCK_BUSY` from the watchdog is expected and logged at `DEBUG`
only. `cron.err` should stay empty; anything in it is a real crash.

## Logs and troubleshooting

```
logs/_run.log                        orchestration: start, targets, heartbeat, summary
logs/<project>__<env>/operations.log everything about one target
logs/<project>__<env>/audit.log      append-only trail of what moved, with outcome and hashes
```

Every line carries `run=` to correlate an execution, and target lines carry
`project=`, `env=` and `cycle=`. `LOG_FORMAT=json` emits the same fields as JSON.

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

**Alert on** `DEPLOY_UNAVAILABLE`, `DEPLOY_FAILED`, `SOURCE_STUCK`,
`SOURCE_NOT_WRITABLE` and `MOUNT_MISSING`, and on `errors=` in `RUN_SUMMARY`.

Exit codes: `0` success · `1` config error · `2` no usable target · `3` lock
busy (expected from the watchdog) · `4` a deployment write failed · `5` a file
was deployed but could not leave the source. **`4` means data was not
delivered; `5` means it was delivered but the source is filling up.** Both
deserve their own alert.

`--rediscover` drops a marker and exits; the running loop re-walks the source and
forces a deep pass on its next cycle.

## Operating notes

- **The local archives grow without bound**, on the *source* share, and nothing
  purges them. That is deliberate, but the pickup shares need a retention policy
  of their own. Monitor their disk usage alongside the deployment tree.
- **file-deploy is the consumer.** Nothing else should be removing files from
  `input`; if something does, file-deploy simply never sees those files.
- **Permissions**: the cron user needs read access to the source, **write**
  access to each pickup directory (unlinking a file needs `w+x` on its parent)
  and to each `deploy_root`. No root required.
- **State lives in `state/`** and none of it is required for correctness — see
  [SPEC.md §11](SPEC.md#11--persistent-state).

## Testing

Pure-bash end-to-end suite, no external dependency:

```sh
bash tests/run-e2e.sh
```

It builds isolated sandboxes, runs the real script against them, and asserts on
the filesystem, the logs and the exit codes. A non-zero exit means a test
failed. The suite deliberately leads with the no-loss properties: an unwritable
or unmounted destination, an unreadable file, a dry run and a mid-copy rewrite
must all leave the source intact.

## License

MIT — see [LICENSE](LICENSE).
