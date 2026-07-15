"""Unit tests for find_missing_context_files in implement_with_deepseek."""

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
# Test case
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
    # 3. Directory (isfile returns False)
    # ------------------------------------------------------------------
    @mock.patch("implement_with_deepseek.os.path.normcase")
    @mock.patch("implement_with_deepseek.os.path.realpath")
    @mock.patch("implement_with_deepseek.os.path.isfile")
    @mock.patch("implement_with_deepseek.os.path.abspath")
    def test_directory_not_flagged(
        self, mock_abspath, mock_isfile, mock_realpath, mock_normcase
    ):
        # isfile returns False even though the path exists as a directory.
        _configure_all_mocks(
            mock_abspath, mock_isfile, mock_realpath, mock_normcase,
            existing=set(),
        )
        result = find_missing_context_files("mydir", [])
        self.assertEqual(result, [])

    # ------------------------------------------------------------------
    # 4. Existing file, already attached
    # ------------------------------------------------------------------
    @mock.patch("implement_with_deepseek.os.path.normcase")
    @mock.patch("implement_with_deepseek.os.path.realpath")
    @mock.patch("implement_with_deepseek.os.path.isfile")
    @mock.patch("implement_with_deepseek.os.path.abspath")
    def test_existing_but_attached(
        self, mock_abspath, mock_isfile, mock_realpath, mock_normcase
    ):
        _configure_all_mocks(
            mock_abspath, mock_isfile, mock_realpath, mock_normcase,
            existing={"/fake/cwd/src/main.py"},
        )
        # Attached file matches the same real path.
        result = find_missing_context_files(
            "src/main.py", attached_files=["src/main.py"]
        )
        self.assertEqual(result, [])

    # ------------------------------------------------------------------
    # 5. Existing file, NOT attached
    # ------------------------------------------------------------------
    @mock.patch("implement_with_deepseek.os.path.normcase")
    @mock.patch("implement_with_deepseek.os.path.realpath")
    @mock.patch("implement_with_deepseek.os.path.isfile")
    @mock.patch("implement_with_deepseek.os.path.abspath")
    def test_existing_unattached(
        self, mock_abspath, mock_isfile, mock_realpath, mock_normcase
    ):
        _configure_all_mocks(
            mock_abspath, mock_isfile, mock_realpath, mock_normcase,
            existing={"/fake/cwd/src/main.py"},
        )
        result = find_missing_context_files("src/main.py", [])
        self.assertEqual(result, ["/fake/cwd/src/main.py"])

    # ------------------------------------------------------------------
    # 6. Multiple tokens, mixed existence
    # ------------------------------------------------------------------
    @mock.patch("implement_with_deepseek.os.path.normcase")
    @mock.patch("implement_with_deepseek.os.path.realpath")
    @mock.patch("implement_with_deepseek.os.path.isfile")
    @mock.patch("implement_with_deepseek.os.path.abspath")
    def test_multiple_tokens_mixed(
        self, mock_abspath, mock_isfile, mock_realpath, mock_normcase
    ):
        _configure_all_mocks(
            mock_abspath, mock_isfile, mock_realpath, mock_normcase,
            existing={"/fake/cwd/existing.doc"},
        )
        result = find_missing_context_files(
            "file1.py missing.txt existing.doc", []
        )
        self.assertEqual(result, ["/fake/cwd/existing.doc"])

    # ------------------------------------------------------------------
    # 7. Path with surrounding quotes / punctuation
    # ------------------------------------------------------------------
    @mock.patch("implement_with_deepseek.os.path.normcase")
    @mock.patch("implement_with_deepseek.os.path.realpath")
    @mock.patch("implement_with_deepseek.os.path.isfile")
    @mock.patch("implement_with_deepseek.os.path.abspath")
    def test_surrounding_punctuation(
        self, mock_abspath, mock_isfile, mock_realpath, mock_normcase
    ):
        _configure_all_mocks(
            mock_abspath, mock_isfile, mock_realpath, mock_normcase,
            existing={"/fake/cwd/src/main.py"},
        )
        # Token is `"src/main.py",` – quotes and comma should be stripped.
        result = find_missing_context_files('"src/main.py",', [])
        self.assertEqual(result, ["/fake/cwd/src/main.py"])

    # ------------------------------------------------------------------
    # 8. URL ignored
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
        result = find_missing_context_files("http://foo.com/file.py", [])
        self.assertEqual(result, [])

    # ------------------------------------------------------------------
    # 9. Module name like os.path when no such file exists
    # ------------------------------------------------------------------
    @mock.patch("implement_with_deepseek.os.path.normcase")
    @mock.patch("implement_with_deepseek.os.path.realpath")
    @mock.patch("implement_with_deepseek.os.path.isfile")
    @mock.patch("implement_with_deepseek.os.path.abspath")
    def test_module_name_not_a_file(
        self, mock_abspath, mock_isfile, mock_realpath, mock_normcase
    ):
        _configure_all_mocks(
            mock_abspath, mock_isfile, mock_realpath, mock_normcase,
            existing=set(),
        )
        result = find_missing_context_files("import os.path", [])
        self.assertEqual(result, [])

    # ------------------------------------------------------------------
    # 10. --no-context-check skips entirely
    # ------------------------------------------------------------------
    @mock.patch("implement_with_deepseek.os.path.normcase")
    @mock.patch("implement_with_deepseek.os.path.realpath")
    @mock.patch("implement_with_deepseek.os.path.isfile")
    @mock.patch("implement_with_deepseek.os.path.abspath")
    def test_no_check_flag_skips(
        self, mock_abspath, mock_isfile, mock_realpath, mock_normcase
    ):
        """When no_check=True, return [] immediately without touching fs."""
        # Don't configure mocks – they should never be called.
        result = find_missing_context_files(
            "src/main.py", attached_files=[], no_check=True
        )
        self.assertEqual(result, [])
        mock_isfile.assert_not_called()
        mock_realpath.assert_not_called()
        mock_normcase.assert_not_called()
        mock_abspath.assert_not_called()

    # ------------------------------------------------------------------
    # 11. Absolute path in spec
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


if __name__ == "__main__":
    unittest.main()
