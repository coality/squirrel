#!/usr/bin/env python3
"""Unit tests for the file-deploy engine (the pure core).

Everything here is decided without touching a tree, which is exactly why it can
be tested this way: the naming rule, the conflict policy, the encoders and the
configuration parser.
"""

import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, ROOT)

import engine  # noqa: E402


class TestEncoders(unittest.TestCase):
    def test_enc_escapes_the_field_separators(self):
        self.assertEqual(engine.enc("a\tb\nc\rd"), "a%09b%0Ac%0Dd")

    def test_enc_is_reversible_even_for_a_literal_escape(self):
        # A path containing the literal text "%09" must not decode to a tab.
        for original in ("plain", "a\tb", "100%", "%09", "%25", "a%0Ab\nc"):
            self.assertEqual(engine.dec(engine.enc(original)), original)

    def test_esc_glob_makes_a_name_literal(self):
        import fnmatch
        # "input*" must match only a directory really called "input*".
        pat = engine.esc_glob("input*")
        self.assertTrue(fnmatch.fnmatch("input*", pat))
        self.assertFalse(fnmatch.fnmatch("input_old", pat))
        # ...and a bracket name must be findable at all.
        pat = engine.esc_glob("input[1]")
        self.assertTrue(fnmatch.fnmatch("input[1]", pat))

    def test_split_list_only_splits_on_commas(self):
        # Names may contain spaces; splitting on whitespace would break them.
        self.assertEqual(engine.split_list("Input Files, input"),
                         ["Input Files", "input"])
        self.assertEqual(engine.split_list(" a ,, b ,"), ["a", "b"])
        self.assertEqual(engine.split_list(""), [])


class TestNaming(unittest.TestCase):
    def test_candidate_order_and_shape(self):
        names = engine.candidate_names("report.xml", "20260101_090000", "deadbeefcafe")
        self.assertEqual(names, ["report.xml",
                                 "report_20260101_090000.xml",
                                 "report_20260101_090000_deadbeef.xml"])

    def test_extensionless_and_dotfiles(self):
        self.assertEqual(engine.candidate_names("README", "S", "abc")[1], "README_S")
        # A dotfile has no stem to split on, so the whole name is the stem.
        self.assertEqual(engine.candidate_names(".env", "S", "abc")[1], ".env_S")

    def test_name_is_a_pure_function_of_its_inputs(self):
        # This is what makes a retry land on the same path instead of piling up
        # duplicates: nothing here reads the clock.
        a = engine.candidate_names("f.txt", engine.stamp_from_epoch(1000000), "aaaa1111")
        b = engine.candidate_names("f.txt", engine.stamp_from_epoch(1000000), "aaaa1111")
        self.assertEqual(a, b)

    def test_stamp_survives_a_nonsense_mtime(self):
        self.assertEqual(len(engine.stamp_from_epoch("not-a-number")), 15)


class TestConflictVerdict(unittest.TestCase):
    def test_nothing_there(self):
        for policy in engine.CONFLICT_POLICIES:
            self.assertEqual(engine.conflict_verdict(None, "a", policy),
                             engine.DEPLOYED)

    def test_identical_is_never_a_conflict(self):
        # Whatever the policy: the destination is already right, and the source
        # file still has to be archived and drained.
        for policy in engine.CONFLICT_POLICIES:
            self.assertEqual(engine.conflict_verdict("a", "a", policy),
                             engine.DEPLOYED_IDENTICAL)

    def test_each_policy_has_its_own_outcome(self):
        got = [engine.conflict_verdict("a", "b", p) for p in engine.CONFLICT_POLICIES]
        self.assertEqual(got, [engine.DEPLOYED_OVERWRITE, engine.DEPLOYED_VERSION,
                               engine.DEPLOY_SKIPPED, engine.DEPLOY_RETRY,
                               engine.DEPLOY_CONFLICT])


class TestCsv(unittest.TestCase):
    def _row(self, **over):
        row = dict((c, "") for c in engine.REPORT_COLUMNS)
        row.update(over)
        return row

    def test_header_matches_the_columns(self):
        self.assertEqual(engine.csv_header(",").split(","),
                         list(engine.REPORT_COLUMNS))

    def test_quoting_survives_a_delimiter_and_a_quote(self):
        line = engine.csv_row(self._row(file_name='b,"x".txt'), ",")
        self.assertIn('"b,""x"".txt"', line)

    def test_numbers_and_dates_are_left_bare_for_typing(self):
        line = engine.csv_row(self._row(size_bytes=42, age_at_pickup_s=7,
                                        deployed_at="2026-01-01T00:00:00+0000"), ",")
        self.assertIn(",42,", line)
        self.assertIn(",2026-01-01T00:00:00+0000,", line)

    def test_custom_delimiter(self):
        line = engine.csv_row(self._row(outcome="DEPLOYED"), ";")
        self.assertIn('"DEPLOYED"', line)
        self.assertEqual(line.count(";"), len(engine.REPORT_COLUMNS) - 1)


class TestConfig(unittest.TestCase):
    def _write(self, text, name="compta.conf"):
        d = tempfile.mkdtemp(prefix="fd-cfg-")
        p = os.path.join(d, name)
        with open(p, "w", encoding="utf-8") as fh:
            fh.write(text)
        return p

    def _cfg(self, text, name="compta.conf"):
        p = self._write(text, name)
        c = engine.Config().parse(p)
        c.validate(config_path=p, script_dir=os.path.dirname(p))
        return c

    BASE = 'SOURCE_DIR = "/src"\nDEPLOY_DIR = "/dep"\n'

    def test_minimal_config_is_valid(self):
        c = self._cfg(self.BASE)
        self.assertEqual(c.errors, [])
        self.assertEqual(c.SOURCE_DIR, "/src")
        self.assertEqual(c.DEPLOY_DIR, "/dep")

    def test_instance_id_defaults_to_the_file_name(self):
        c = self._cfg(self.BASE, name="facturation.conf")
        self.assertEqual(c.INSTANCE_ID, "facturation")

    def test_paths_are_derived_from_the_instance(self):
        # This is the isolation mechanism, not a convenience.
        c = self._cfg(self.BASE + 'INSTANCE_ID = rh-homol\n')
        self.assertTrue(c.STATE_DIR.endswith(os.path.join("state", "rh-homol")))
        self.assertTrue(c.LOG_DIR.endswith(os.path.join("logs", "rh-homol")))
        self.assertTrue(c.LOCK_FILE.endswith("run-rh-homol.lock"))

    def test_explicit_paths_win(self):
        c = self._cfg(self.BASE + 'STATE_DIR = "/var/lib/fd"\n')
        self.assertEqual(c.STATE_DIR, "/var/lib/fd")

    def test_both_directories_are_required(self):
        c = self._cfg('SOURCE_DIR = "/src"\n')
        self.assertTrue(any("DEPLOY_DIR is required" in e for e in c.errors))

    def test_relative_directories_are_refused(self):
        c = self._cfg('SOURCE_DIR = "src"\nDEPLOY_DIR = "/dep"\n')
        self.assertTrue(any("absolute" in e for e in c.errors))

    def test_source_and_deploy_must_differ(self):
        c = self._cfg('SOURCE_DIR = "/same"\nDEPLOY_DIR = "/same"\n')
        self.assertTrue(any("must differ" in e for e in c.errors))

    def test_unusable_instance_id_is_refused(self):
        c = self._cfg(self.BASE + 'INSTANCE_ID = "../escape"\n')
        self.assertTrue(any("INSTANCE_ID" in e for e in c.errors))

    def test_unknown_setting_is_named(self):
        c = self._cfg(self.BASE + 'TYPO_DIR = "/x"\n')
        self.assertTrue(any("unknown setting 'TYPO_DIR'" in e for e in c.errors))

    def test_bad_enum_lists_the_choices(self):
        c = self._cfg(self.BASE + 'ON_CONFLICT = ovrewrite\n')
        self.assertTrue(any("ON_CONFLICT" in e and "overwrite" in e for e in c.errors))

    def test_bad_number_and_bad_boolean(self):
        c = self._cfg(self.BASE + 'SCAN_INTERVAL = soon\nAUDIT_LOG = maybe\n')
        self.assertEqual(len(c.errors), 2)

    def test_negative_where_it_makes_no_sense(self):
        c = self._cfg(self.BASE + 'MIN_STABLE_AGE = -1\n')
        self.assertTrue(any("must be >=" in e for e in c.errors))

    def test_every_problem_is_collected_not_just_the_first(self):
        # One --check should report the lot.
        c = self._cfg('SOURCE_DIR = "/src"\nDEPLOY_DIR = "/dep"\n'
                      'NOPE = 1\nSCAN_INTERVAL = x\nON_CONFLICT = zzz\n')
        self.assertEqual(len(c.errors), 3)

    def test_comments_and_quotes(self):
        c = self._cfg('SOURCE_DIR = "/src"   # where files land\n'
                      'DEPLOY_DIR = /dep\n'
                      'INPUT_DIR_NAME = "Input Files, input"  # two names\n')
        self.assertEqual(c.errors, [])
        self.assertEqual(c.input_names(), ["Input Files", "input"])

    def test_booleans_accept_the_usual_spellings(self):
        for text in ("yes", "true", "on", "1"):
            self.assertIs(self._cfg(self.BASE + "AUDIT_LOG = %s\n" % text).AUDIT_LOG, True)
        for text in ("no", "false", "off", "0"):
            self.assertIs(self._cfg(self.BASE + "AUDIT_LOG = %s\n" % text).AUDIT_LOG, False)

    def test_dangerous_settings_warn_without_failing(self):
        c = self._cfg(self.BASE + 'MIN_STABLE_AGE = 0\nLOCAL_ARCHIVE_DIR = ""\n')
        self.assertEqual(c.errors, [])
        self.assertEqual(len(c.warnings), 2)

    def test_missing_file_is_not_an_error_by_itself(self):
        c = engine.Config().parse("/nonexistent/nope.conf")
        self.assertFalse(c.found)
        self.assertEqual(c.errors, [])   # the missing pair is what fails validate


if __name__ == "__main__":
    unittest.main(verbosity=2)
