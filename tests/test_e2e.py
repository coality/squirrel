#!/usr/bin/env python3
"""End-to-end tests for file-deploy.

Each test builds an isolated sandbox, writes a configuration, drops files in the
pickup directories, runs the real entry point (./file-deploy.sh) as a subprocess,
and asserts on the final state: where the files ended up, what the logs say, and
the exit code.

The suite deliberately leads with the no-loss properties. This tool deletes from
the source, so the tests that matter most are the ones proving it does not: an
unwritable or unmounted destination, an unreadable file, a rehearsal and a file
rewritten mid-copy must all leave the source exactly as it was.
"""

import hashlib
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
LAUNCHER = os.path.join(ROOT, "file-deploy.sh")
sys.path.insert(0, ROOT)

EX_OK, EX_CONFIG, EX_NOSOURCE, EX_LOCKED, EX_DEPLOY, EX_SOURCE = 0, 1, 2, 3, 4, 5


def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        h.update(fh.read())
    return h.hexdigest()


class Base(unittest.TestCase):
    def setUp(self):
        self.sb = tempfile.mkdtemp(prefix="fd-e2e-")
        self.src = os.path.join(self.sb, "src")
        self.dep = os.path.join(self.sb, "dep")
        self.conf = os.path.join(self.sb, "compta.conf")
        os.makedirs(os.path.join(self.src, "input"))
        os.makedirs(self.dep)

    def tearDown(self):
        for root, dirs, _ in os.walk(self.sb):
            for d in dirs:
                try:
                    os.chmod(os.path.join(root, d), 0o755)
                except OSError:
                    pass
        shutil.rmtree(self.sb, ignore_errors=True)

    # ----------------------------------------------------------- fixtures
    def write_conf(self, path=None, source=None, deploy=None, **extra):
        path = path or self.conf
        inst = extra.pop("INSTANCE_ID", None) or os.path.basename(path)[:-5]
        lines = [
            "INSTANCE_ID = %s" % inst,
            'SOURCE_DIR = "%s"' % (source or self.src),
            'DEPLOY_DIR = "%s"' % (deploy or self.dep),
            "MIN_STABLE_AGE = 0",
            "RUN_DURATION = 0",
            "SCAN_INTERVAL = 1",
            "LOG_LEVEL = DEBUG",
            "LOG_CONSOLE = never",
            'STATE_DIR = "%s"' % os.path.join(self.sb, "state", inst),
            'LOG_DIR = "%s"' % os.path.join(self.sb, "logs", inst),
            'LOCK_FILE = "%s"' % os.path.join(self.sb, "run-%s.lock" % inst),
        ]
        for k, v in extra.items():
            lines.append("%s = %s" % (k, v))
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("\n".join(lines) + "\n")
        return path

    def run_fd(self, *args, conf=None):
        cmd = [LAUNCHER, "--config", conf or self.conf] + list(args)
        return subprocess.run(cmd, capture_output=True, text=True)

    def drop(self, relpath, content="payload\n", under=None):
        p = os.path.join(under or self.src, relpath)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w", encoding="utf-8") as fh:
            fh.write(content)
        return p

    # ------------------------------------------------------------ helpers
    def log(self, inst="compta"):
        p = os.path.join(self.sb, "logs", inst, "file-deploy.log")
        try:
            with open(p, encoding="utf-8") as fh:
                return fh.read()
        except OSError:
            return ""

    def audit(self, inst="compta"):
        p = os.path.join(self.sb, "logs", inst, "audit.log")
        try:
            with open(p, encoding="utf-8") as fh:
                return fh.read()
        except OSError:
            return ""

    def tree(self, root, skip_archive=False):
        """Every regular file under root, relative, excluding the sentinel."""
        out = []
        for dirpath, dirnames, files in os.walk(root):
            if skip_archive and os.path.basename(dirpath) == "archive":
                dirnames[:] = []
                continue
            for f in files:
                if f == ".file-deploy-root":
                    continue
                out.append(os.path.relpath(os.path.join(dirpath, f), root))
        return sorted(out)

    def pending(self):
        """Files still waiting in the source (everything but the archives)."""
        return self.tree(self.src, skip_archive=True)

    def archived(self):
        out = []
        for dirpath, _dirs, files in os.walk(self.src):
            if os.path.basename(dirpath) == "archive":
                for f in files:
                    out.append(os.path.relpath(os.path.join(dirpath, f), self.src))
        return sorted(out)

    def contents(self, root):
        """Digest of every file's CONTENT, ignoring where it lives."""
        out = []
        for dirpath, _dirs, files in os.walk(root):
            for f in files:
                out.append(digest(os.path.join(dirpath, f)))
        return sorted(out)


# ==========================================================================
class TestNoLoss(Base):
    """The properties that justify the whole design."""

    def test_nominal_move(self):
        self.drop("input/facture.xml", "<f/>\n")
        self.drop("input/sub/bl.txt", "bl\n")
        self.write_conf()
        r = self.run_fd()
        self.assertEqual(r.returncode, EX_OK, r.stderr)
        self.assertEqual(self.tree(self.dep),
                         ["input/facture.xml", "input/sub/bl.txt"])
        # Drained, and archived next to where each file came from.
        self.assertEqual(self.pending(), [])
        self.assertEqual(self.archived(),
                         ["input/archive/facture.xml", "input/sub/archive/bl.txt"])
        self.assertIn("event=DEPLOYED", self.log())
        self.assertIn("action=DEPLOYED", self.audit())
        self.assertIn('archive="input/archive/facture.xml"', self.audit())

    def test_bytes_survive_the_move(self):
        before = self.contents(self.src)
        self.drop("input/a.txt", "one\n")
        self.drop("input/b.txt", "two\n")
        before = self.contents(self.src)
        self.write_conf()
        self.run_fd()
        self.assertEqual(self.contents(self.src), before,
                         "every byte is still in the source tree, elsewhere")

    def test_local_archive_is_never_redeployed(self):
        # The regression the whole pruning rule exists for.
        self.drop("input/a.txt")
        self.drop("input/sub/b.txt")
        self.write_conf()
        self.run_fd()
        snapshot = self.archived()
        self.run_fd()
        self.run_fd()
        self.assertEqual(self.archived(), snapshot, "the archive stopped changing")
        self.assertEqual(self.tree(self.dep), ["input/a.txt", "input/sub/b.txt"])
        self.assertNotIn("archive", " ".join(self.tree(self.dep)))
        self.assertIn("LOCAL_ARCHIVE_SKIPPED", self.log())

    def test_unwritable_deploy_root_keeps_the_source(self):
        self.drop("input/a.txt")
        self.write_conf()
        os.chmod(self.dep, 0o555)
        try:
            r = self.run_fd()
        finally:
            os.chmod(self.dep, 0o755)
        self.assertEqual(r.returncode, EX_DEPLOY)
        self.assertIn("DEPLOY_UNAVAILABLE", self.log())
        self.assertEqual(self.pending(), ["input/a.txt"], "source untouched")
        self.assertEqual(self.archived(), [], "nothing archived either")

    def test_failure_midtree_keeps_only_that_file(self):
        self.drop("input/a.txt")
        self.write_conf()
        self.run_fd()                       # creates dep/input
        self.drop("input/b.txt")
        os.chmod(os.path.join(self.dep, "input"), 0o555)
        try:
            r = self.run_fd()
        finally:
            os.chmod(os.path.join(self.dep, "input"), 0o755)
        self.assertEqual(r.returncode, EX_DEPLOY)
        self.assertIn("DEPLOY_FAILED", self.log())
        self.assertEqual(self.pending(), ["input/b.txt"])
        self.assertNotIn("input/archive/b.txt", self.archived())

    def test_unmounted_destination_keeps_the_source_and_recovers(self):
        self.drop("input/a.txt")
        self.write_conf()
        self.run_fd()
        # The share goes away; the bare mount point stays behind, empty.
        shutil.rmtree(self.dep)
        os.makedirs(self.dep)
        self.drop("input/b.txt")
        r = self.run_fd()
        self.assertEqual(r.returncode, EX_DEPLOY)
        self.assertIn("DEPLOY_UNAVAILABLE", self.log())
        self.assertEqual(self.pending(), ["input/b.txt"], "source survives the outage")
        self.assertEqual(self.tree(self.dep), [], "nothing written to the mount point")
        # Once it is back, the refused file is delivered for real.
        open(os.path.join(self.dep, ".file-deploy-root"), "a").close()
        self.run_fd()
        self.assertEqual(self.tree(self.dep), ["input/b.txt"])
        self.assertEqual(self.pending(), [])

    def test_unreadable_file_is_never_consumed(self):
        self.drop("input/good.txt")
        bad = self.drop("input/bad.txt", "secret\n")
        os.chmod(bad, 0o000)
        self.write_conf()
        try:
            r = self.run_fd()
        finally:
            os.chmod(bad, 0o644)
        self.assertEqual(r.returncode, EX_OK)
        self.assertIn("HASH_FAILED", self.log())
        self.assertEqual(self.pending(), ["input/bad.txt"])
        self.assertEqual(self.tree(self.dep), ["input/good.txt"])

    def test_unstable_file_is_left_alone(self):
        self.drop("input/growing.csv", "start\n")
        self.write_conf(MIN_STABLE_AGE=3600)
        r = self.run_fd()
        self.assertEqual(r.returncode, EX_OK)
        self.assertIn("SKIP_UNSTABLE", self.log())
        self.assertEqual(self.pending(), ["input/growing.csv"], "not consumed")
        self.assertEqual(self.archived(), [], "nor archived")
        # Once it settles it goes.
        self.write_conf(MIN_STABLE_AGE=0)
        self.run_fd()
        self.assertEqual(self.pending(), [])

    def test_undrainable_pickup_dir_deploys_nothing(self):
        # Deploying out of a directory we cannot then clean would re-deploy the
        # same files on every cycle, forever.
        self.drop("input/a.txt")
        self.write_conf()
        os.chmod(os.path.join(self.src, "input"), 0o555)
        try:
            r = self.run_fd()
        finally:
            os.chmod(os.path.join(self.src, "input"), 0o755)
        self.assertEqual(r.returncode, EX_SOURCE)
        self.assertIn("SOURCE_NOT_WRITABLE", self.log())
        self.assertEqual(self.tree(self.dep), [])
        self.assertEqual(self.pending(), ["input/a.txt"])

    def test_stuck_source_exits_5_and_retries_without_duplicating(self):
        self.drop("input/a.txt", "a\n")
        self.write_conf()
        self.run_fd()
        # The pickup dir stays writable (so the guard passes) but its archive does not.
        adir = os.path.join(self.src, "input", "archive")
        self.drop("input/b.txt", "b\n")
        os.chmod(adir, 0o555)
        try:
            r = self.run_fd()
        finally:
            os.chmod(adir, 0o755)
        self.assertEqual(r.returncode, EX_SOURCE)
        self.assertIn("SOURCE_STUCK", self.log())
        self.assertEqual(self.pending(), ["input/b.txt"], "kept, not lost")
        self.assertIn("input/b.txt", self.tree(self.dep), "but it IS deployed")
        self.assertEqual(len(self.archived()), 1, "no half-written archive entry")
        # The retry converges, with no duplicate anywhere.
        self.run_fd()
        self.assertEqual(self.pending(), [])
        self.assertEqual(len(self.archived()), 2)
        self.assertEqual(len(self.tree(self.dep)), 2)


# ==========================================================================
class TestSourceChangedDuringCopy(unittest.TestCase):
    """The mid-copy race, reached directly because a subprocess cannot be timed.

    A writer that appends between the copy and the commit must leave the file in
    the pickup directory: what was deployed is a snapshot of a half-written file.
    """

    def setUp(self):
        self.sb = tempfile.mkdtemp(prefix="fd-race-")
        os.makedirs(os.path.join(self.sb, "src", "input"))
        os.makedirs(os.path.join(self.sb, "dep"))
        os.makedirs(os.path.join(self.sb, "state"))
        os.makedirs(os.path.join(self.sb, "logs"))

    def tearDown(self):
        shutil.rmtree(self.sb, ignore_errors=True)

    def test_writer_racing_the_copy(self):
        import deploy, engine
        cfg = engine.Config()
        cfg.values.update({
            "INSTANCE_ID": "race",
            "SOURCE_DIR": os.path.join(self.sb, "src"),
            "DEPLOY_DIR": os.path.join(self.sb, "dep"),
            "STATE_DIR": os.path.join(self.sb, "state"),
            "LOG_DIR": os.path.join(self.sb, "logs"),
            "MIN_STABLE_AGE": 0,
        })
        src = os.path.join(self.sb, "src", "input", "w.txt")
        with open(src, "w") as fh:
            fh.write("start\n")

        log = deploy.Log(cfg, "test", False)
        runner = deploy.Runner(cfg, log, dry_run=False)
        real_copy = runner.atomic_copy

        def racing_copy(s, d, dg):
            out = real_copy(s, d, dg)
            with open(s, "a") as fh:      # the producer appends right after
                fh.write("more\n")
            return out

        runner.atomic_copy = racing_copy
        runner.deploy_checked = True
        unsettled = runner.process_file(src, os.path.dirname(src))

        self.assertTrue(unsettled, "the directory must be retried")
        self.assertTrue(os.path.exists(src), "NOT consumed: it was still being written")
        self.assertFalse(os.path.exists(os.path.join(self.sb, "src", "input",
                                                     "archive", "w.txt")))
        with open(log.path, encoding="utf-8") as fh:
            self.assertIn("SOURCE_CHANGED_DURING_COPY", fh.read())


# ==========================================================================
class TestDryRun(Base):
    def test_rehearsal_is_inert(self):
        self.drop("input/a.txt")
        self.write_conf()
        before = self.contents(self.src)
        r = self.run_fd("--dry-run")
        self.assertEqual(r.returncode, EX_OK)
        self.assertEqual(self.tree(self.dep), [], "nothing deployed")
        self.assertEqual(self.contents(self.src), before, "source byte-identical")
        self.assertEqual(self.archived(), [], "no archive directory created")
        self.assertIn("WOULD_MOVE", self.log())
        self.assertIn("DRY_RUN_ACTIVE", self.log())

    def test_rehearsal_does_not_stop_the_real_run(self):
        # A rehearsal used to settle the directory, so the real run right after
        # skipped it on an unchanged mtime and delivered nothing.
        self.drop("input/a.txt")
        self.write_conf()
        self.run_fd("--dry-run")
        state = os.path.join(self.sb, "state", "compta")
        self.assertFalse(os.path.exists(os.path.join(state, "leaves.tsv")),
                         "settled no directory")
        self.assertFalse(os.path.exists(os.path.join(state, "deepscan")),
                         "did not consume the deep pass")
        r = self.run_fd()
        self.assertEqual(r.returncode, EX_OK)
        self.assertEqual(self.tree(self.dep), ["input/a.txt"])
        self.assertEqual(self.pending(), [])

    def test_flag_beats_the_config(self):
        self.drop("input/a.txt")
        self.write_conf(DRY_RUN="no")
        self.run_fd("--dry-run")
        self.assertEqual(self.tree(self.dep), [])
        self.assertIn('source="--dry-run"', self.log())

    def test_config_dry_run_is_announced(self):
        self.drop("input/a.txt")
        self.write_conf(DRY_RUN="yes")
        self.run_fd()
        self.assertEqual(self.tree(self.dep), [])
        self.assertIn('source="config"', self.log())


# ==========================================================================
class TestConflictPolicy(Base):
    def _collision(self, policy):
        self.drop("input/f.txt", "incoming\n")
        os.makedirs(os.path.join(self.dep, "input"), exist_ok=True)
        with open(os.path.join(self.dep, "input", "f.txt"), "w") as fh:
            fh.write("already-deployed\n")
        open(os.path.join(self.dep, ".file-deploy-root"), "a").close()
        self.write_conf(ON_CONFLICT=policy)

    def _deployed(self):
        with open(os.path.join(self.dep, "input", "f.txt")) as fh:
            return fh.read().strip()

    def test_overwrite(self):
        self._collision("overwrite")
        r = self.run_fd()
        self.assertEqual(r.returncode, EX_OK)
        self.assertEqual(self._deployed(), "incoming")
        self.assertEqual(self.tree(self.dep), ["input/f.txt"], "nothing added")
        self.assertEqual(self.pending(), [])
        self.assertIn("DEPLOYED_OVERWRITE", self.log())
        self.assertIn("prev_hash=", self.audit(), "the replaced digest is recorded")

    def test_version_keeps_both_and_is_idempotent(self):
        self._collision("version")
        r = self.run_fd()
        self.assertEqual(r.returncode, EX_OK)
        self.assertEqual(self._deployed(), "already-deployed", "existing kept")
        self.assertEqual(len(self.tree(self.dep)), 2, "both versions present")
        self.assertIn("DEPLOYED_VERSION", self.log())
        # Re-dropping the same content must land on the same name, not a third.
        self.drop("input/f.txt", "incoming\n")
        self.run_fd()
        self.assertEqual(len(self.tree(self.dep)), 2, "a repeat is idempotent")

    def test_skip_leaves_the_destination_but_drains(self):
        self._collision("skip")
        r = self.run_fd()
        self.assertEqual(r.returncode, EX_OK, "not an error")
        self.assertEqual(self._deployed(), "already-deployed")
        self.assertEqual(self.tree(self.dep), ["input/f.txt"])
        # Nothing lost, nothing piling up: it is archived and drained.
        self.assertEqual(self.pending(), [])
        self.assertEqual(self.archived(), ["input/archive/f.txt"])
        self.assertIn("DEPLOY_SKIPPED", self.log())

    def test_retry_keeps_both_and_clears_by_itself(self):
        self._collision("retry")
        r = self.run_fd()
        self.assertEqual(r.returncode, EX_OK, "a pending collision is not a failure")
        self.assertEqual(self._deployed(), "already-deployed")
        self.assertEqual(self.pending(), ["input/f.txt"], "kept for the next attempt")
        self.assertEqual(self.archived(), [], "and not archived yet")
        self.assertIn("DEPLOY_RETRY", self.log())
        # It resolves on its own once the deployed file goes away.
        os.remove(os.path.join(self.dep, "input", "f.txt"))
        self.run_fd()
        self.assertEqual(self._deployed(), "incoming")
        self.assertEqual(self.pending(), [])

    def test_fail_keeps_the_source_and_exits_4(self):
        self._collision("fail")
        r = self.run_fd()
        self.assertEqual(r.returncode, EX_DEPLOY)
        self.assertEqual(self._deployed(), "already-deployed")
        self.assertEqual(self.pending(), ["input/f.txt"], "kept for a human")
        self.assertEqual(self.archived(), [], "and not archived either")
        self.assertIn("DEPLOY_CONFLICT", self.log())

    def test_identical_is_never_a_conflict(self):
        for policy in ("overwrite", "version", "skip", "retry", "fail"):
            with self.subTest(policy=policy):
                self.tearDown(); self.setUp()
                self.drop("input/f.txt", "same\n")
                os.makedirs(os.path.join(self.dep, "input"), exist_ok=True)
                with open(os.path.join(self.dep, "input", "f.txt"), "w") as fh:
                    fh.write("same\n")
                open(os.path.join(self.dep, ".file-deploy-root"), "a").close()
                self.write_conf(ON_CONFLICT=policy)
                r = self.run_fd()
                self.assertEqual(r.returncode, EX_OK)
                self.assertEqual(self.tree(self.dep), ["input/f.txt"])
                self.assertEqual(self.pending(), [], "drained anyway")

    def test_dry_run_reports_the_policy_verdict(self):
        for policy, verdict in (("overwrite", "DEPLOYED_OVERWRITE"),
                                ("version", "DEPLOYED_VERSION"),
                                ("skip", "DEPLOY_SKIPPED"),
                                ("retry", "DEPLOY_RETRY"),
                                ("fail", "DEPLOY_CONFLICT")):
            with self.subTest(policy=policy):
                self.tearDown(); self.setUp()
                self._collision(policy)
                self.run_fd("--dry-run")
                self.assertIn('deploy="%s"' % verdict, self.log())
                self.assertEqual(self._deployed(), "already-deployed")
                self.assertEqual(self.pending(), ["input/f.txt"])

    def test_archive_stacks_versions_the_deployment_tree_does_not(self):
        self.write_conf()
        for i, content in enumerate(("v1\n", "v2\n", "v3\n"), start=1):
            self.drop("input/f.txt", content)
            os.utime(os.path.join(self.src, "input", "f.txt"),
                     (1600000000 + i * 86400, 1600000000 + i * 86400))
            self.run_fd()
        self.assertEqual(self.tree(self.dep), ["input/f.txt"], "only the latest")
        with open(os.path.join(self.dep, "input", "f.txt")) as fh:
            self.assertEqual(fh.read(), "v3\n")
        self.assertEqual(len(self.archived()), 3, "all three kept in the archive")


# ==========================================================================
class TestSelection(Base):
    def test_depth_is_input_plus_one_level(self):
        self.drop("input/a.txt")
        self.drop("input/sub/b.txt")
        self.drop("input/sub/deeper/c.txt")
        self.write_conf()
        self.run_fd()
        self.assertEqual(self.tree(self.dep), ["input/a.txt", "input/sub/b.txt"])
        self.assertEqual(self.pending(), ["input/sub/deeper/c.txt"], "never scanned")

    def test_several_names_including_one_with_spaces(self):
        os.makedirs(os.path.join(self.src, "b", "Input"))
        os.makedirs(os.path.join(self.src, "c", "Input Files"))
        os.makedirs(os.path.join(self.src, "d", "output"))
        self.drop("b/Input/x.txt")
        self.drop("c/Input Files/y.txt")
        self.drop("d/output/z.txt")
        self.write_conf(INPUT_DIR_NAME='"input,Input,Input Files"')
        self.run_fd()
        self.assertEqual(self.tree(self.dep),
                         ["b/Input/x.txt", "c/Input Files/y.txt"])
        self.assertEqual(self.pending(), ["d/output/z.txt"], "unlisted name ignored")

    def test_names_are_literal_not_globs(self):
        os.makedirs(os.path.join(self.src, "a", "input_old"))
        self.drop("a/input_old/x.txt")
        self.write_conf(INPUT_DIR_NAME='"input*"')
        self.run_fd()
        self.assertEqual(self.tree(self.dep), [], "'input*' does not glob-match")

    def test_exclude_dir_patterns(self):
        self.drop("input/ok/a.txt")
        self.drop("input/~tmp/b.txt")
        self.write_conf(EXCLUDE_DIR_PATTERNS='"~*"')
        self.run_fd()
        self.assertEqual(self.tree(self.dep), ["input/ok/a.txt"])
        self.assertIn("input/~tmp/b.txt", self.pending())

    def test_archive_name_is_matched_exactly(self):
        # 'archived' is not 'archive', so it stays deployable content.
        self.drop("input/archived/a.txt")
        self.write_conf()
        self.run_fd()
        self.assertIn("input/archived/a.txt", self.tree(self.dep))

    def test_local_archive_dir_is_configurable(self):
        self.drop("input/x.txt")
        self.drop("input/archive/y.txt")     # now ordinary content
        self.write_conf(LOCAL_ARCHIVE_DIR='"_bak"')
        self.run_fd()
        self.assertTrue(os.path.exists(os.path.join(self.src, "input", "_bak", "x.txt")))
        self.assertIn("input/archive/y.txt", self.tree(self.dep))

    def test_new_subdir_is_picked_up_next_cycle(self):
        self.drop("input/a.txt")
        self.write_conf(DISCOVERY_INTERVAL=99999)
        self.run_fd()
        self.drop("input/fresh/b.txt")
        self.run_fd()
        self.assertIn("input/fresh/b.txt", self.tree(self.dep))

    def test_rediscover_finds_a_new_input_dir(self):
        self.drop("input/a.txt")
        self.write_conf(DISCOVERY_INTERVAL=99999)
        self.run_fd()
        os.makedirs(os.path.join(self.src, "later", "input"))
        self.drop("later/input/b.txt")
        self.run_fd()
        self.assertNotIn("later/input/b.txt", self.tree(self.dep), "not yet discovered")
        r = self.run_fd("--rediscover")
        self.assertEqual(r.returncode, EX_OK)
        self.run_fd()
        self.assertIn("later/input/b.txt", self.tree(self.dep))

    def test_changing_the_names_invalidates_the_cache_at_once(self):
        os.makedirs(os.path.join(self.src, "b", "Input"))
        self.drop("input/x.txt")
        self.drop("b/Input/y.txt")
        self.write_conf(DISCOVERY_INTERVAL=99999, INPUT_DIR_NAME='"input"')
        self.run_fd()
        self.assertEqual(len(self.tree(self.dep)), 1)
        self.write_conf(DISCOVERY_INTERVAL=99999, INPUT_DIR_NAME='"input,Input"')
        self.run_fd()
        self.assertIn("config-changed", self.log())
        self.assertEqual(len(self.tree(self.dep)), 2)

    def test_deep_pass_recovers_a_stale_directory_mtime(self):
        self.drop("input/a.txt")
        self.write_conf(DEEP_SCAN_INTERVAL=3600)
        pinned = 1600000000
        os.utime(os.path.join(self.src, "input"), (pinned, pinned))
        self.run_fd()
        # A share that fails to bump the directory mtime when a file appears.
        self.drop("input/b.txt")
        os.utime(os.path.join(self.src, "input"), (pinned, pinned))
        self.run_fd()
        self.assertEqual(self.pending(), ["input/b.txt"], "hidden by the mtime skip")
        # Make the deep pass due.
        deep = os.path.join(self.sb, "state", "compta", "deepscan")
        os.utime(deep, (time.time() - 7200, time.time() - 7200))
        os.utime(os.path.join(self.src, "input"), (pinned, pinned))
        self.write_conf(DEEP_SCAN_INTERVAL=60)
        self.run_fd()
        self.assertEqual(self.pending(), [], "the deep pass finds it")

    def test_weird_names_survive(self):
        self.drop("input/a b é.txt", "utf8\n")
        self.drop("input/with,comma.txt", "comma\n")
        self.write_conf()
        self.run_fd()
        self.assertEqual(self.tree(self.dep),
                         ["input/a b é.txt", "input/with,comma.txt"])
        self.assertEqual(self.pending(), [])


# ==========================================================================
class TestInstances(Base):
    def test_two_configurations_share_nothing(self):
        srcB = os.path.join(self.sb, "srcB")
        depB = os.path.join(self.sb, "depB")
        os.makedirs(os.path.join(srcB, "input"))
        os.makedirs(depB)
        self.drop("input/a.txt")
        self.drop("input/b.txt", under=srcB)
        confB = os.path.join(self.sb, "rh.conf")
        self.write_conf()
        self.write_conf(path=confB, source=srcB, deploy=depB)
        self.assertEqual(self.run_fd().returncode, EX_OK)
        self.assertEqual(self.run_fd(conf=confB).returncode, EX_OK)
        self.assertEqual(self.tree(self.dep), ["input/a.txt"])
        self.assertEqual(self.tree(depB), ["input/b.txt"])
        # Separate state, logs and locks.
        self.assertTrue(os.path.exists(os.path.join(self.sb, "state", "compta", "deployed")))
        self.assertTrue(os.path.exists(os.path.join(self.sb, "state", "rh", "deployed")))
        self.assertNotIn("b.txt", self.log("compta"))
        self.assertNotIn("a.txt", self.log("rh"))

    def test_shared_state_dir_is_refused(self):
        srcB = os.path.join(self.sb, "srcB")
        os.makedirs(os.path.join(srcB, "input"))
        shared = os.path.join(self.sb, "shared")
        self.drop("input/a.txt")
        self.drop("input/b.txt", under=srcB)
        confB = os.path.join(self.sb, "rh.conf")
        self.write_conf(STATE_DIR='"%s"' % shared)
        self.write_conf(path=confB, source=srcB, STATE_DIR='"%s"' % shared)
        self.run_fd()
        r = self.run_fd(conf=confB)
        self.assertEqual(r.returncode, EX_CONFIG)
        self.assertIn("STATE_DIR_CONFLICT", self.log("rh"))
        # Refused before anything moved.
        self.assertTrue(os.path.exists(os.path.join(srcB, "input", "b.txt")))

    def test_instance_id_defaults_to_the_config_name(self):
        self.drop("input/a.txt")
        conf = os.path.join(self.sb, "facturation.conf")
        with open(conf, "w", encoding="utf-8") as fh:
            fh.write('SOURCE_DIR = "%s"\nDEPLOY_DIR = "%s"\n'
                     "MIN_STABLE_AGE = 0\nRUN_DURATION = 0\n"
                     'STATE_DIR = "%s"\nLOG_DIR = "%s"\nLOCK_FILE = "%s"\n'
                     % (self.src, self.dep,
                        os.path.join(self.sb, "state", "facturation"),
                        os.path.join(self.sb, "logs", "facturation"),
                        os.path.join(self.sb, "run.lock")))
        r = self.run_fd(conf=conf)
        self.assertEqual(r.returncode, EX_OK)
        self.assertIn("instance=facturation", self.log("facturation"))

    def test_lock_is_per_instance(self):
        import fcntl
        self.drop("input/a.txt")
        self.write_conf()
        lock = os.path.join(self.sb, "run-compta.lock")
        holder = open(lock, "a+")
        fcntl.flock(holder, fcntl.LOCK_EX)
        try:
            r = self.run_fd()
        finally:
            holder.close()
        self.assertEqual(r.returncode, EX_LOCKED)
        self.assertIn("LOCK_BUSY", self.log())


# ==========================================================================
class TestConfigAndCli(Base):
    def test_check_reports_the_resolved_paths(self):
        self.write_conf()
        r = self.run_fd("--check")
        self.assertEqual(r.returncode, EX_OK)
        self.assertIn("configuration OK", r.stdout)
        self.assertIn("instance   compta", r.stdout)
        self.assertEqual(self.tree(self.dep), [], "--check scans nothing")

    def test_check_lists_every_problem_at_once(self):
        with open(self.conf, "w", encoding="utf-8") as fh:
            fh.write('SOURCE_DIR = "%s"\nNOPE = 1\nON_CONFLICT = zzz\n' % self.src)
        r = self.run_fd("--check")
        self.assertEqual(r.returncode, EX_CONFIG)
        self.assertIn("DEPLOY_DIR is required", r.stderr)
        self.assertIn("unknown setting 'NOPE'", r.stderr)
        self.assertIn("ON_CONFLICT", r.stderr)

    def test_missing_source_is_exit_2(self):
        self.write_conf(source=os.path.join(self.sb, "nope"))
        r = self.run_fd()
        self.assertEqual(r.returncode, EX_NOSOURCE)
        self.assertIn("MOUNT_MISSING", self.log())
        self.assertIn("deepest_existing", self.log())

    def test_unwritable_source_is_refused(self):
        # Moving files out needs write access, not just read.
        self.write_conf()
        os.chmod(self.src, 0o555)
        try:
            r = self.run_fd()
        finally:
            os.chmod(self.src, 0o755)
        self.assertEqual(r.returncode, EX_NOSOURCE)
        self.assertIn("not writable", self.log())

    def test_invalid_instance_id(self):
        self.write_conf(INSTANCE_ID="../escape")
        r = self.run_fd()
        self.assertEqual(r.returncode, EX_CONFIG)
        self.assertIn("INSTANCE_ID", r.stderr)

    def test_json_logging(self):
        import json
        self.drop("input/a.txt")
        self.write_conf(LOG_FORMAT="json")
        self.run_fd()
        lines = [l for l in self.log().splitlines() if l.strip()]
        self.assertTrue(lines)
        for line in lines:
            json.loads(line)          # every line is valid JSON
        self.assertTrue(any(json.loads(l).get("event") == "DEPLOYED" for l in lines))

    def test_log_rotation(self):
        for i in range(40):
            self.drop("input/f%02d.txt" % i, "content-%d\n" % i)
        self.write_conf(LOG_MAX_BYTES=2000, LOG_KEEP=3)
        self.run_fd()
        self.assertTrue(os.path.exists(self.log_path() + ".1"), "rotated")
        self.assertLess(os.path.getsize(self.log_path()), 8000)

    def log_path(self):
        return os.path.join(self.sb, "logs", "compta", "file-deploy.log")

    def test_clean_stderr_on_a_fresh_run(self):
        self.drop("input/a.txt")
        self.write_conf()
        r = self.run_fd()
        self.assertEqual(r.stderr, "", "nothing leaks to cron mail")


# ==========================================================================
class TestReport(Base):
    def csv(self):
        rd = os.path.join(self.sb, "reports")
        files = [os.path.join(rd, f) for f in os.listdir(rd)] if os.path.isdir(rd) else []
        return files[0] if files else None

    def test_one_row_per_file_with_quoting(self):
        self.drop("input/a.txt", "one\n")
        self.drop('input/sub/b,"x".txt', "two\n")
        self.write_conf(REPORT_DIR='"%s"' % os.path.join(self.sb, "reports"))
        self.run_fd()
        path = self.csv()
        self.assertIsNotNone(path)
        with open(path, encoding="utf-8") as fh:
            body = fh.read()
        self.assertIn("run_id,deployed_at,instance,outcome", body)
        self.assertEqual(len(body.strip().splitlines()), 3, "header + one row per file")
        self.assertIn('"a.txt"', body)
        self.assertIn("/input/archive/a.txt", body, "archive path recorded")
        self.assertIn('"b,""x"".txt"', body, "delimiter and quote escaped")

    def test_rows_append_to_the_same_day(self):
        self.drop("input/a.txt")
        self.write_conf(REPORT_DIR='"%s"' % os.path.join(self.sb, "reports"))
        self.run_fd()
        self.drop("input/b.txt")
        self.run_fd()
        with open(self.csv(), encoding="utf-8") as fh:
            body = fh.read()
        self.assertEqual(len(body.strip().splitlines()), 3, "header not repeated")

    def test_custom_delimiter(self):
        self.drop("input/a.txt")
        self.write_conf(REPORT_DIR='"%s"' % os.path.join(self.sb, "reports"),
                        REPORT_DELIMITER='";"')
        self.run_fd()
        with open(self.csv(), encoding="utf-8") as fh:
            body = fh.read()
        self.assertIn("run_id;deployed_at;instance;outcome", body)

    def test_prev_hash_chains_to_the_previous_row(self):
        self.write_conf(REPORT_DIR='"%s"' % os.path.join(self.sb, "reports"))
        self.drop("input/f.txt", "v1\n")
        self.run_fd()
        self.drop("input/f.txt", "v2\n")
        self.run_fd()
        with open(self.csv(), encoding="utf-8") as fh:
            rows = [r for r in fh.read().splitlines()[1:] if r]
        first = rows[0].split(",")
        second = rows[1].split(",")
        idx_hash = list(__import__("engine").REPORT_COLUMNS).index("hash")
        idx_prev = list(__import__("engine").REPORT_COLUMNS).index("prev_hash")
        self.assertEqual(second[idx_prev], first[idx_hash],
                         "prev_hash chains, so a self-join rebuilds the history")

    def test_rehearsal_writes_no_report(self):
        self.drop("input/a.txt")
        self.write_conf(REPORT_DIR='"%s"' % os.path.join(self.sb, "reports"))
        self.run_fd("--dry-run")
        self.assertIsNone(self.csv())


if __name__ == "__main__":
    unittest.main(verbosity=2)
