"""Unit tests for find_missing_context_files in implement_with_deepseek."""

import os
import tempfile
import unittest
from unittest import mock

# Import the function under test.
from implement_with_deepseek import find_missing_context_files


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _configure_all_mocks(
    mock_abspath: mock.MagicMock,
    mock_isfile: mock.MagicMock,
    mock_realpath: mock.MagicMock,
    mock_normcase: mock.MagicMock,
    *,
    existing: set[str] | None = None,
) -> None:
    """Wire up all four os.path mocks consistently so they agree on path
    resolution without touching the real filesystem.

    *existing* – set of lowercased absolute paths that ``isfile`` returns
    True for (e.g. ``{"/fake/cwd/src/main.py"}``).
    """

    existing_set = existing or set()

    def _abspath(p: str) -> str:
        """Resolve a path to a fake absolute form."""
        # Normalise slashes first.
        p = p.replace("\\", "/")
        if p.startswith("/"):
            # Already absolute (POSIX-style).  Keep as-is.
            return p
        # On Windows absolute paths like C:/... – also keep as-is.
        if len(p) >= 2 and p[1] == ":":
            return p
        return "/fake/cwd/" + p

    def _realpath(p: str) -> str:
        # For tests, realpath = identity on the absolute path.
        return _abspath(p)

    def _isfile(p: str) -> bool:
        return _abspath(p).lower() in existing_set

    def _normcase(p: str) -> str:
        return p.lower()

    mock_abspath.side_effect = _abspath
    mock_isfile.side_effect = _isfile
    mock_realpath.side_effect = _realpath
    mock_normcase.side_effect = _normcase


# ---------------------------------------------------------------------------
# Test case (mocked)
# ---------------------------------------------------------------------------

class TestFindMissingContextFiles(unittest.TestCase):
    """All tests mock os.path.isfile, os.path.realpath, os.path.normcase,
    and os.path.abspath so they are pure-logic tests.
    """

    # ------------------------------------------------------------------
    # 1. No candidate tokens
    # ------------------------------------------------------------------
    @mock.patch("implement_with_deepseek.os.path.normcase")
    @mock.patch("implement_with_deepseek.os.path.realpath")
    @mock.patch("implement_with_deepseek.os.path.isfile")
    @mock.patch("implement_with_deepseek.os.path.abspath")
    def test_no_candidate_tokens(
        self, mock_abspath, mock_isfile, mock_realpath, mock_normcase
    ):
        """Spec consists only of prose with no path-like tokens."""
        _configure_all_mocks(
            mock_abspath, mock_isfile, mock_realpath, mock_normcase,
            existing=set(),
        )
        result = find_missing_context_files("Just some prose.", [])
        self.assertEqual(result, [])

    # ------------------------------------------------------------------
    # 2. Token looks like path but does not exist
    # ------------------------------------------------------------------
    @mock.patch("implement_with_deepseek.os.path.normcase")
    @mock.patch("implement_with_deepseek.os.path.realpath")
    @mock.patch("implement_with_deepseek.os.path.isfile")
    @mock.patch("implement_with_deepseek.os.path.abspath")
    def test_path_like_but_nonexistent(
        self, mock_abspath, mock_isfile, mock_realpath, mock_normcase
    ):
        _configure_all_mocks(
            mock_abspath, mock_isfile, mock_realpath, mock_normcase,
            existing=set(),
        )
        result = find_missing_context_files("foo.bar", [])
        self.assertEqual(result, [])

    # ------------------------------------------------------------------
    # 3. URL ignored
    # ------------------------------------------------------------------
    @mock.patch("implement_with_deepseek.os.path.normcase")
    @mock.patch("implement_with_deepseek.os.path.realpath")
    @mock.patch("implement_with_deepseek.os.path.isfile")
    @mock.patch("implement_with_deepseek.os.path.abspath")
    def test_url_ignored(
        self, mock_abspath, mock_isfile, mock_realpath, mock_normcase
    ):
        _configure_all_mocks(
            mock_abspath, mock_isfile, mock_realpath, mock_normcase,
            existing=set(),
        )
        result = find_missing_context_files("http://example.com/foo.py", [])
        self.assertEqual(result, [])

    # ------------------------------------------------------------------
    # 4. Existing file, not attached -> returned
    # ------------------------------------------------------------------
    @mock.patch("implement_with_deepseek.os.path.normcase")
    @mock.patch("implement_with_deepseek.os.path.realpath")
    @mock.patch("implement_with_deepseek.os.path.isfile")
    @mock.patch("implement_with_deepseek.os.path.abspath")
    def test_existing_file_not_attached(
        self, mock_abspath, mock_isfile, mock_realpath, mock_normcase
    ):
        _configure_all_mocks(
            mock_abspath, mock_isfile, mock_realpath, mock_normcase,
            existing={"/fake/cwd/src/main.py"},
        )
        result = find_missing_context_files("src/main.py", [])
        self.assertEqual(result, ["/fake/cwd/src/main.py"])

    # ------------------------------------------------------------------
    # 5. Existing file, attached via -c -> not returned
    # ------------------------------------------------------------------
    @mock.patch("implement_with_deepseek.os.path.normcase")
    @mock.patch("implement_with_deepseek.os.path.realpath")
    @mock.patch("implement_with_deepseek.os.path.isfile")
    @mock.patch("implement_with_deepseek.os.path.abspath")
    def test_existing_file_attached(
        self, mock_abspath, mock_isfile, mock_realpath, mock_normcase
    ):
        _configure_all_mocks(
            mock_abspath, mock_isfile, mock_realpath, mock_normcase,
            existing={"/fake/cwd/src/main.py"},
        )
        result = find_missing_context_files(
            "src/main.py",
            attached_files=["/fake/cwd/src/main.py"],
        )
        self.assertEqual(result, [])

    # ------------------------------------------------------------------
    # 6. Case-insensitive match (normcase)
    # ------------------------------------------------------------------
    @mock.patch("implement_with_deepseek.os.path.normcase")
    @mock.patch("implement_with_deepseek.os.path.realpath")
    @mock.patch("implement_with_deepseek.os.path.isfile")
    @mock.patch("implement_with_deepseek.os.path.abspath")
    def test_case_insensitive_match(
        self, mock_abspath, mock_isfile, mock_realpath, mock_normcase
    ):
        """Spec uses lowercase, filesystem has uppercase; normcase makes them match."""
        _configure_all_mocks(
            mock_abspath, mock_isfile, mock_realpath, mock_normcase,
            existing={"/fake/cwd/src/main.py"},
        )
        result = find_missing_context_files(
            "src/main.py",
            attached_files=["/fake/cwd/src/Main.py"],
        )
        self.assertEqual(result, [])

    # ------------------------------------------------------------------
    # 7. Directory not treated as file
    # ------------------------------------------------------------------
    @mock.patch("implement_with_deepseek.os.path.normcase")
    @mock.patch("implement_with_deepseek.os.path.realpath")
    @mock.patch("implement_with_deepseek.os.path.isfile")
    @mock.patch("implement_with_deepseek.os.path.abspath")
    def test_directory_not_returned(
        self, mock_abspath, mock_isfile, mock_realpath, mock_normcase
    ):
        _configure_all_mocks(
            mock_abspath, mock_isfile, mock_realpath, mock_normcase,
            existing=set(),
        )
        result = find_missing_context_files("adir", [])
        self.assertEqual(result, [])

    # ------------------------------------------------------------------
    # 8. Token with surrounding punctuation stripped
    # ------------------------------------------------------------------
    @mock.patch("implement_with_deepseek.os.path.normcase")
    @mock.patch("implement_with_deepseek.os.path.realpath")
    @mock.patch("implement_with_deepseek.os.path.isfile")
    @mock.patch("implement_with_deepseek.os.path.abspath")
    def test_punctuation_stripped(
        self, mock_abspath, mock_isfile, mock_realpath, mock_normcase
    ):
        _configure_all_mocks(
            mock_abspath, mock_isfile, mock_realpath, mock_normcase,
            existing={"/fake/cwd/src/main.py"},
        )
        result = find_missing_context_files('"src/main.py"', [])
        self.assertEqual(result, ["/fake/cwd/src/main.py"])

    # ------------------------------------------------------------------
    # 9. no_check=True short-circuits
    # ------------------------------------------------------------------
    @mock.patch("implement_with_deepseek.os.path.normcase")
    @mock.patch("implement_with_deepseek.os.path.realpath")
    @mock.patch("implement_with_deepseek.os.path.isfile")
    @mock.patch("implement_with_deepseek.os.path.abspath")
    def test_no_check_short_circuits(
        self, mock_abspath, mock_isfile, mock_realpath, mock_normcase
    ):
        _configure_all_mocks(
            mock_abspath, mock_isfile, mock_realpath, mock_normcase,
            existing={"/fake/cwd/src/main.py"},
        )
        result = find_missing_context_files(
            "src/main.py", [], no_check=True
        )
        self.assertEqual(result, [])

    # ------------------------------------------------------------------
    # 10. Multiple mentions; only one returned, sorted
    # ------------------------------------------------------------------
    @mock.patch("implement_with_deepseek.os.path.normcase")
    @mock.patch("implement_with_deepseek.os.path.realpath")
    @mock.patch("implement_with_deepseek.os.path.isfile")
    @mock.patch("implement_with_deepseek.os.path.abspath")
    def test_multiple_mentions_deduped_sorted(
        self, mock_abspath, mock_isfile, mock_realpath, mock_normcase
    ):
        _configure_all_mocks(
            mock_abspath, mock_isfile, mock_realpath, mock_normcase,
            existing={"/fake/cwd/a.py", "/fake/cwd/b.py"},
        )
        result = find_missing_context_files("b.py a.py b.py", [])
        self.assertEqual(result, ["/fake/cwd/a.py", "/fake/cwd/b.py"])

    # ------------------------------------------------------------------
    # 11. Absolute path in spec already
    # ------------------------------------------------------------------
    @mock.patch("implement_with_deepseek.os.path.normcase")
    @mock.patch("implement_with_deepseek.os.path.realpath")
    @mock.patch("implement_with_deepseek.os.path.isfile")
    @mock.patch("implement_with_deepseek.os.path.abspath")
    def test_absolute_path_in_spec(
        self, mock_abspath, mock_isfile, mock_realpath, mock_normcase
    ):
        _configure_all_mocks(
            mock_abspath, mock_isfile, mock_realpath, mock_normcase,
            existing={"/etc/hosts"},
        )
        result = find_missing_context_files("/etc/hosts", [])
        self.assertEqual(result, ["/etc/hosts"])

    # ------------------------------------------------------------------
    # 12. Duplicate mentions of same file
    # ------------------------------------------------------------------
    @mock.patch("implement_with_deepseek.os.path.normcase")
    @mock.patch("implement_with_deepseek.os.path.realpath")
    @mock.patch("implement_with_deepseek.os.path.isfile")
    @mock.patch("implement_with_deepseek.os.path.abspath")
    def test_duplicate_mentions(
        self, mock_abspath, mock_isfile, mock_realpath, mock_normcase
    ):
        _configure_all_mocks(
            mock_abspath, mock_isfile, mock_realpath, mock_normcase,
            existing={"/fake/cwd/a.py"},
        )
        result = find_missing_context_files("a.py a.py", [])
        self.assertEqual(result, ["/fake/cwd/a.py"])

    # ------------------------------------------------------------------
    # 13. Curly quotes (Unicode symmetric pairs)
    # ------------------------------------------------------------------
    @mock.patch("implement_with_deepseek.os.path.normcase")
    @mock.patch("implement_with_deepseek.os.path.realpath")
    @mock.patch("implement_with_deepseek.os.path.isfile")
    @mock.patch("implement_with_deepseek.os.path.abspath")
    def test_curly_quotes_stripped(
        self, mock_abspath, mock_isfile, mock_realpath, mock_normcase
    ):
        _configure_all_mocks(
            mock_abspath, mock_isfile, mock_realpath, mock_normcase,
            existing={"/fake/cwd/src/main.py"},
        )
        result = find_missing_context_files(
            "\u201csrc/main.py\u201d", []
        )
        self.assertEqual(result, ["/fake/cwd/src/main.py"])

    # ------------------------------------------------------------------
    # 14. Parentheses stripped
    # ------------------------------------------------------------------
    @mock.patch("implement_with_deepseek.os.path.normcase")
    @mock.patch("implement_with_deepseek.os.path.realpath")
    @mock.patch("implement_with_deepseek.os.path.isfile")
    @mock.patch("implement_with_deepseek.os.path.abspath")
    def test_parentheses_stripped(
        self, mock_abspath, mock_isfile, mock_realpath, mock_normcase
    ):
        _configure_all_mocks(
            mock_abspath, mock_isfile, mock_realpath, mock_normcase,
            existing={"/fake/cwd/src/main.py"},
        )
        result = find_missing_context_files("(src/main.py)", [])
        self.assertEqual(result, ["/fake/cwd/src/main.py"])

    # ------------------------------------------------------------------
    # 15. www. domain ignored
    # ------------------------------------------------------------------
    @mock.patch("implement_with_deepseek.os.path.normcase")
    @mock.patch("implement_with_deepseek.os.path.realpath")
    @mock.patch("implement_with_deepseek.os.path.isfile")
    @mock.patch("implement_with_deepseek.os.path.abspath")
    def test_www_domain_ignored(
        self, mock_abspath, mock_isfile, mock_realpath, mock_normcase
    ):
        _configure_all_mocks(
            mock_abspath, mock_isfile, mock_realpath, mock_normcase,
            existing=set(),
        )
        result = find_missing_context_files("www.example.com/file.py", [])
        self.assertEqual(result, [])

    # ------------------------------------------------------------------
    # 16. Attached via -c with different spelling (relative vs absolute)
    # ------------------------------------------------------------------
    @mock.patch("implement_with_deepseek.os.path.normcase")
    @mock.patch("implement_with_deepseek.os.path.realpath")
    @mock.patch("implement_with_deepseek.os.path.isfile")
    @mock.patch("implement_with_deepseek.os.path.abspath")
    def test_attached_different_spelling(
        self, mock_abspath, mock_isfile, mock_realpath, mock_normcase
    ):
        """Spec uses relative path but -c used absolute; should match."""
        _configure_all_mocks(
            mock_abspath, mock_isfile, mock_realpath, mock_normcase,
            existing={"/fake/cwd/src/main.py"},
        )
        result = find_missing_context_files(
            "src/main.py",
            attached_files=["/fake/cwd/src/main.py"],
        )
        self.assertEqual(result, [])

    # ------------------------------------------------------------------
    # 17. Backslash path separator (Windows-style) is recognised
    # ------------------------------------------------------------------
    @mock.patch("implement_with_deepseek.os.path.normcase")
    @mock.patch("implement_with_deepseek.os.path.realpath")
    @mock.patch("implement_with_deepseek.os.path.isfile")
    @mock.patch("implement_with_deepseek.os.path.abspath")
    def test_backslash_path_separator(
        self, mock_abspath, mock_isfile, mock_realpath, mock_normcase
    ):
        _configure_all_mocks(
            mock_abspath, mock_isfile, mock_realpath, mock_normcase,
            existing={"/fake/cwd/src/main.py"},
        )
        result = find_missing_context_files("src\\main.py", [])
        self.assertEqual(result, ["/fake/cwd/src/main.py"])

    # ------------------------------------------------------------------
    # 18. Empty spec
    # ------------------------------------------------------------------
    @mock.patch("implement_with_deepseek.os.path.normcase")
    @mock.patch("implement_with_deepseek.os.path.realpath")
    @mock.patch("implement_with_deepseek.os.path.isfile")
    @mock.patch("implement_with_deepseek.os.path.abspath")
    def test_empty_spec(
        self, mock_abspath, mock_isfile, mock_realpath, mock_normcase
    ):
        _configure_all_mocks(
            mock_abspath, mock_isfile, mock_realpath, mock_normcase,
            existing=set(),
        )
        result = find_missing_context_files("", [])
        self.assertEqual(result, [])


# ---------------------------------------------------------------------------
# Real-filesystem tests (no mocking)
# ---------------------------------------------------------------------------

class TestFindMissingContextFilesRealFS(unittest.TestCase):
    """Tests that exercise ``find_missing_context_files`` against real files
    on disk.  Nothing is mocked — these tests validate that the real
    ``os.path`` functions integrate correctly, especially ``normcase`` on
    case-insensitive filesystems.
    """

    def setUp(self):
        # Save the original working directory so we can restore it.
        self._original_cwd = os.getcwd()

        # Create a temporary directory and switch into it.
        self._tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self._cleanup_tempdir)
        os.chdir(self._tmpdir.name)

        # Build the fixture tree inside the temp directory.
        os.makedirs("src", exist_ok=True)
        os.makedirs("adir", exist_ok=True)

        # Real file with a capital letter (important for case tests).
        with open(os.path.join("src", "Main.py"), "w", encoding="utf-8") as f:
            f.write("# test fixture\n")

        # Another real file.
        with open("notes.md", "w", encoding="utf-8") as f:
            f.write("# notes\n")

        # Pre-compute canonical forms for the Main.py fixture.
        self.main_rel = os.path.join("src", "Main.py")
        self.main_abs = os.path.abspath(self.main_rel)
        self.main_real = os.path.realpath(self.main_abs)

    def _cleanup_tempdir(self):
        """Restore cwd first, then destroy the temp directory.

        The ordering matters on Windows: you cannot remove a directory
        that is the current working directory of the process.
        """
        os.chdir(self._original_cwd)
        self._tmpdir.cleanup()

    # ------------------------------------------------------------------
    # 1. Existing file named in spec, not attached -> returned
    # ------------------------------------------------------------------
    def test_existing_file_not_attached(self):
        result = find_missing_context_files("src/Main.py", [])
        self.assertEqual(len(result), 1)
        returned = result[0]
        # The returned path should be the real absolute path.
        self.assertEqual(os.path.realpath(returned), self.main_real)
        self.assertTrue(os.path.isfile(returned))
        self.assertEqual(os.path.basename(returned), "Main.py")

    # ------------------------------------------------------------------
    # 2. Attached by the same relative path -> not returned
    # ------------------------------------------------------------------
    def test_attached_same_relative_path(self):
        # Simulate how main() calls: it abs-path's the -c arguments first.
        attached = [os.path.abspath(self.main_rel)]
        result = find_missing_context_files("src/Main.py", attached)
        self.assertEqual(result, [])

    # ------------------------------------------------------------------
    # 3. Attached by absolute path while spec names it relatively -> not returned
    # ------------------------------------------------------------------
    def test_attached_absolute_path(self):
        # Pass the already-absolute real path as the attachment.
        result = find_missing_context_files("src/Main.py", [self.main_real])
        self.assertEqual(result, [])

    # ------------------------------------------------------------------
    # 4. Spec uses different letter case than on-disk file -> not returned
    #    (exercises normcase).  On a case-*sensitive* filesystem the
    #    lowercased path simply does not exist, so the result is also [].
    # ------------------------------------------------------------------
    def test_case_insensitive_normcase(self):
        lower_rel = os.path.join("src", "main.py")  # lowercase 'm'
        # Attach the real file so it is considered "attached".
        attached = [os.path.abspath(self.main_rel)]
        result = find_missing_context_files(lower_rel, attached)
        self.assertEqual(result, [])

    # ------------------------------------------------------------------
    # 5. A path that does not exist -> not returned
    # ------------------------------------------------------------------
    def test_nonexistent_file(self):
        result = find_missing_context_files("newfile.py", [])
        self.assertEqual(result, [])

    # ------------------------------------------------------------------
    # 6. A real directory -> not returned (isfile is False)
    # ------------------------------------------------------------------
    def test_directory_not_returned(self):
        result = find_missing_context_files("adir", [])
        self.assertEqual(result, [])

    # ------------------------------------------------------------------
    # 7. A URL -> not returned
    # ------------------------------------------------------------------
    def test_url_ignored(self):
        result = find_missing_context_files("http://x.com/a.py", [])
        self.assertEqual(result, [])

    # ------------------------------------------------------------------
    # 8. no_check=True with a real existing file -> returns []
    # ------------------------------------------------------------------
    def test_no_check_short_circuits_real(self):
        result = find_missing_context_files(
            "src/Main.py", [], no_check=True
        )
        self.assertEqual(result, [])

    # ------------------------------------------------------------------
    # 9. Windows-style backslash path naming the real file -> returned
    # ------------------------------------------------------------------
    def test_backslash_path_separator(self):
        result = find_missing_context_files("src\\Main.py", [])
        self.assertEqual(len(result), 1)
        returned = result[0]
        self.assertEqual(os.path.realpath(returned), self.main_real)
        self.assertTrue(os.path.isfile(returned))
        self.assertEqual(os.path.basename(returned), "Main.py")


if __name__ == "__main__":
    unittest.main()
