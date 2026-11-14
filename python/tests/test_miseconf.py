from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from pmsec.util.miseconf import MiseEnvError, read_env, write_pmsec_env  # noqa: E402

# Every error expectation spells the reason out literally: these strings are the
# cross-port contract, so renaming a constant must break a test, not silently
# travel with it. Everything here is pure text in, text out — no filesystem.

QUOTED_KEY = "quoted env key is unsupported"
DUPLICATE = "duplicate top-level env assignment"
NOT_ARRAY = "env must be an array"
ELEMENT = "env array elements must be single-line quoted strings"
ESCAPE = "escape sequences are unsupported"
MULTILINE = "multiline strings are unsupported"
UNTERMINATED = "unterminated env assignment"
MALFORMED = "malformed env assignment"
SEPARATOR = "malformed env array separator"
AFTER_ARRAY = "unexpected content after env array"
UNTERMINATED_FILE_STRING = "unterminated string in file"
ENV_TABLE = "env table conflicts with the env array"
UNREPRESENTABLE = "env name cannot be represented without escapes"


# --- read: accepted shapes -------------------------------------------------


def test_absent_top_level_env_reads_as_not_defined():
    assert read_env("") is None
    assert read_env('name = "x"\n[tools]\nnode = "22"\n') is None
    # An [env] table and env.* dotted keys define the key another way; the
    # narrow reader only owns the array form, so it reports "not defined".
    assert read_env('[env]\nFOO = "1"\n') is None
    assert read_env("env.foo = 1\n") is None


def test_unrelated_key_prefixes_are_not_the_env_key():
    assert read_env('envelope = true\nenvs = ["a"]\n') is None


def test_empty_array():
    assert read_env("env = []\n") == []
    assert read_env("env = [ ]\n") == []
    assert read_env("env = [\n]\n") == []
    assert read_env("env = [\n  # nothing yet\n]\n") == []


def test_inline_arrays():
    assert read_env('env = ["a"]\n') == ["a"]
    assert read_env('env = ["a", "b", "c"]\n') == ["a", "b", "c"]


def test_trailing_comma_allowed_but_not_required():
    assert read_env('env = ["a", "b",]\n') == ["a", "b"]
    assert read_env('env = [\n  "a",\n]\n') == ["a"]
    assert read_env('env = [\n  "a"\n]\n') == ["a"]


def test_multiline_array_with_comments_between_tokens():
    text = 'env = [\n  # toolchains\n  "node",\n  "python" # trailing\n]\n'
    assert read_env(text) == ["node", "python"]


def test_whitespace_tabs_newlines_and_comments_between_any_tokens():
    assert read_env('env\t=\t[\t"a"\t,\t"b"\t]\n') == ["a", "b"]
    # Newline (and a comment) after the separator, before the value.
    assert read_env('env =\n ["a"]\n') == ["a"]
    assert read_env('env = [ # open\n  "a" # first\n  , # separator\n  "b"\n]\n') == ["a", "b"]


def test_single_quoted_backslash_is_literal():
    # No escape processing in literal strings: the backslash stays a backslash.
    assert read_env(r"env = ['say\hi']") == ["say\\hi"]
    assert read_env(r"env = ['say\hi']")[0] == "say" + "\\" + "hi"


def test_quoted_names_are_opaque():
    text = 'env = ["a#b", "c[d]", "e,f", "g h", "p=q"]\n'
    assert read_env(text) == ["a#b", "c[d]", "e,f", "g h", "p=q"]


def test_unicode_and_pmsec_names_read_back_verbatim():
    assert read_env('env = ["ノード", "λ"]\n') == ["ノード", "λ"]
    # `env_sets` names are opaque: a name that happens to be pmsec is just a name.
    assert read_env("env = ['pmsec']\n") == ["pmsec"]


def test_duplicate_names_within_one_array_are_kept():
    assert read_env('env = ["a", "a", "b"]\n') == ["a", "a", "b"]


def test_leading_indentation_before_the_key():
    assert read_env('\t env = ["a"]\n') == ["a"]
    assert read_env('a = 1\n  env = ["a"]\n') == ["a"]


def test_env_between_unrelated_root_keys_and_a_table():
    assert read_env('a = 1\nenv = ["x"]\n[t]\nb = 2\n') == ["x"]


def test_env_like_text_inside_multiline_strings_is_ignored():
    text = 'note = """\nenv = ["fake"]\n[not-a-table]\n"""\nenv = ["real"]\n'
    assert read_env(text) == ["real"]


def test_table_header_after_a_multiline_string_still_ends_the_root_region():
    text = 'note = """\n[not-a-table]\n"""\n[real]\nenv = ["inside"]\n'
    assert read_env(text) is None


def test_env_like_text_inside_comments_is_ignored():
    assert read_env('# env = ["fake"]\n# [env]\nname = "x"\n') is None


def test_one_line_strings_elsewhere_do_not_hide_the_key():
    assert read_env("a = \"x\" # env = [\"fake\"]\nb = 'y'\nenv = [\"real\"]\n") == ["real"]


def test_a_trailing_backslash_ends_the_one_line_string_at_the_newline():
    # The subset does not validate general TOML, so a backslash that lands on the
    # line end does not let the string cross the newline: the line still ends it.
    assert read_env('x = "abc\\\nenv = ["work"]\n') == ["work"]
    assert read_env('x = "abc\\\ny = "def\\\nenv = ["work"]\n') == ["work"]


def test_a_trailing_backslash_in_a_literal_string_also_ends_the_line():
    assert read_env("x = 'abc\\\nenv = [\"work\"]\n") == ["work"]


def test_an_escaped_quote_does_not_close_the_string_but_the_newline_does():
    assert read_env('x = "a\\"b\nenv = ["work"]\n') == ["work"]


def test_an_env_assignment_before_a_trailing_backslash_opener_is_found():
    assert read_env('env = ["work"]\nx = "abc\\\n') == ["work"]


def test_no_final_newline_is_fine():
    assert read_env('env = ["a"]') == ["a"]


# --- read: rejected shapes -------------------------------------------------

REJECTS = [
    ('"env" = ["a"]\n', QUOTED_KEY),
    ("'env' = ['a']\n", QUOTED_KEY),
    ('env = ["a"]\nenv = ["b"]\n', DUPLICATE),
    ('env = ["a"]\n\n# note\nenv = []\n', DUPLICATE),
    ('env = "work"\n', NOT_ARRAY),
    ("env = 3\n", NOT_ARRAY),
    ("env = true\n", NOT_ARRAY),
    ("env = {a = 1}\n", NOT_ARRAY),
    # A value offset at EOF is a truncated assignment, not a wrong-shaped one:
    # `env =` and `env = # nothing` both report the cut, as the other ports do.
    ("env =", UNTERMINATED),
    ("env = # nothing\n", UNTERMINATED),
    # A scalar is still scanned first, so an unsupported or broken string
    # reports its own cause instead of the shape error.
    ('env = """a"""', MULTILINE),
    ("env = '''a'''", MULTILINE),
    ('env = "a\\tb"\n', ESCAPE),
    ('env = ["a', UNTERMINATED),
    ('env = "work\n', UNTERMINATED),
    ("env = [work]\n", ELEMENT),
    ("env = [1]\n", ELEMENT),
    ("env = [true]\n", ELEMENT),
    ('env = [["a"]]\n', ELEMENT),
    ('env = [{name = "a"}]\n', ELEMENT),
    ('env = ["a\\tb"]\n', ESCAPE),
    ('env = ["a\\"b"]\n', ESCAPE),
    ('env = ["""a"""]\n', MULTILINE),
    ("env = ['''a''']\n", MULTILINE),
    ('env = ["a",\n', UNTERMINATED),
    ('env = [\n  "a",\n', UNTERMINATED),
    ('env = [\n  "a"\n  "b"\n]\n', SEPARATOR),
    ('env = ["a" "b"]\n', SEPARATOR),
    ('env = [, "a"]\n', SEPARATOR),
    ('env = ["a",, "b"]\n', SEPARATOR),
    ('env = ["a"] junk\n', AFTER_ARRAY),
    ('env = ["a"] [1]\n', AFTER_ARRAY),
    ('env ["a"]\n', MALFORMED),
    ("env\n", MALFORMED),
    ("env name\n", MALFORMED),
    ('a = """\nno close\n', UNTERMINATED_FILE_STRING),
    ("a = '''\nno close\n", UNTERMINATED_FILE_STRING),
]


@pytest.mark.parametrize("text,reason", REJECTS)
def test_read_rejects_unsupported_forms(text: str, reason: str):
    with pytest.raises(MiseEnvError) as excinfo:
        read_env(text)
    assert excinfo.value.reason == reason
    assert str(excinfo.value) == f"invalid env in <memory>: {reason}"


def test_duplicate_detection_continues_past_the_first_valid_assignment():
    # The scanner must not stop at the first array and report success.
    text = 'env = ["ok"]\n\n# later\n   env = ["also"]  # noqa\n'
    with pytest.raises(MiseEnvError) as excinfo:
        read_env(text)
    assert excinfo.value.reason == DUPLICATE


def test_error_carries_the_structured_envelope():
    with pytest.raises(MiseEnvError) as excinfo:
        read_env('env = "work"\n', "miserc.local.toml")
    error = excinfo.value
    # OSError is deliberate: cli enable/disable already catches it.
    assert isinstance(error, OSError)
    assert error.code == "INVALID_MISE_ENV"
    assert error.path == "miserc.local.toml"
    assert error.reason == NOT_ARRAY
    assert str(error) == "invalid env in miserc.local.toml: env must be an array"


# --- write: target list ----------------------------------------------------


def test_write_from_empty_input_is_exactly_one_array_line():
    assert write_pmsec_env("", []) == 'env = ["pmsec"]\n'
    assert write_pmsec_env("", ["pmsec"]) == 'env = ["pmsec"]\n'


def test_write_appends_inherited_names_before_pmsec():
    assert write_pmsec_env("", ["work"]) == 'env = ["work", "pmsec"]\n'


def test_write_removes_every_exact_pmsec_and_appends_one_last():
    assert write_pmsec_env('env = ["pmsec", "work"]\n', ["work"]) == 'env = ["work", "pmsec"]\n'
    assert write_pmsec_env('env = ["work", "pmsec", "a"]\n', ["work", "a"]) == 'env = ["work", "a", "pmsec"]\n'
    assert write_pmsec_env('env = ["pmsec", "pmsec"]\n', []) == 'env = ["pmsec"]\n'
    assert write_pmsec_env("", ["pmsec", "work", "pmsec"]) == 'env = ["work", "pmsec"]\n'


# --- write: shape of the rewrite ------------------------------------------


def test_write_collapses_a_multiline_array_without_residue():
    assert write_pmsec_env('env = [\n  "a",\n  "b",\n]\n', ["a", "b"]) == 'env = ["a", "b", "pmsec"]\n'
    assert write_pmsec_env('env = [\n  # tools\n  "a", # x\n]\n', ["a"]) == 'env = ["a", "pmsec"]\n'


def test_write_preserves_every_unrelated_byte():
    assert write_pmsec_env('\ufeffenv = ["a"]\n', ["a"]) == '\ufeffenv = ["a", "pmsec"]\n'
    assert write_pmsec_env('env = ["a"]\r\nx = 1\r\n', ["a"]) == 'env = ["a", "pmsec"]\r\nx = 1\r\n'
    assert write_pmsec_env('env = ["a"]', ["a"]) == 'env = ["a", "pmsec"]'
    assert write_pmsec_env('env = ["a"]  # keep\n', ["a"]) == 'env = ["a", "pmsec"]  # keep\n'
    assert write_pmsec_env('  env = ["a"]\n', ["a"]) == '  env = ["a", "pmsec"]\n'
    assert (
        write_pmsec_env('env = ["a"]\n\n[tools]\nnode = "22"\n', ["a"])
        == 'env = ["a", "pmsec"]\n\n[tools]\nnode = "22"\n'
    )
    # Env-like text inside an unrelated multiline string is not the assignment.
    assert (
        write_pmsec_env('note = """\nenv = ["fake"]\n"""\nenv = ["a"]\n', ["a"])
        == 'note = """\nenv = ["fake"]\n"""\nenv = ["a", "pmsec"]\n'
    )


def test_write_inserts_before_the_first_table_header():
    assert (
        write_pmsec_env('name = "x"\n\n[tools]\nnode = "22"\n', [])
        == 'name = "x"\n\nenv = ["pmsec"]\n[tools]\nnode = "22"\n'
    )
    # A header on the very first line still gets the array above it.
    assert write_pmsec_env('[tools]\nnode = "22"\n', []) == 'env = ["pmsec"]\n[tools]\nnode = "22"\n'


def test_write_appends_a_newline_when_the_input_lacks_one():
    assert write_pmsec_env('name = "x"', []) == 'name = "x"\nenv = ["pmsec"]\n'
    assert write_pmsec_env('name = "x"', ["work"]) == 'name = "x"\nenv = ["work", "pmsec"]\n'


def test_write_ignores_an_env_array_inside_a_table():
    # Table-scoped env is another key entirely: insert at the root, leave it be.
    assert write_pmsec_env('[tools]\nenv = ["a"]\n', []) == 'env = ["pmsec"]\n[tools]\nenv = ["a"]\n'


# --- write: quoting --------------------------------------------------------


def test_write_reuses_the_local_token_verbatim():
    assert write_pmsec_env("env = ['work']\n", ["work"]) == "env = ['work', \"pmsec\"]\n"
    # Both names already exist with single quotes: the rewrite is a no-op.
    assert write_pmsec_env("env = ['work', 'pmsec']\n", ["work"]) == "env = ['work', 'pmsec']\n"


def test_write_reuses_the_leftmost_token_when_a_name_repeats():
    assert write_pmsec_env("env = [\"work\", 'work']\n", ["work"]) == 'env = ["work", "pmsec"]\n'


def test_write_serializes_names_that_come_from_elsewhere_canonically():
    assert write_pmsec_env('env = ["a"]\n', ["work"]) == 'env = ["work", "pmsec"]\n'
    assert write_pmsec_env("", ["work"]) == 'env = ["work", "pmsec"]\n'


def test_write_uses_single_quotes_when_the_value_contains_a_double_quote():
    assert write_pmsec_env("", ['a"b']) == 'env = [\'a"b\', "pmsec"]\n'


def test_write_uses_single_quotes_when_the_value_contains_a_backslash():
    assert write_pmsec_env("", ["a\\b"]) == "env = ['a\\b', \"pmsec\"]\n"


@pytest.mark.parametrize("name", ['a"\'b', "a\nb", "a\x01b", "a\x7fb", "\t"])
def test_write_fails_closed_on_names_that_need_escapes(name: str):
    with pytest.raises(MiseEnvError) as excinfo:
        write_pmsec_env("", [name])
    assert excinfo.value.reason == UNREPRESENTABLE
    assert excinfo.value.code == "INVALID_MISE_ENV"


# --- write: collisions -----------------------------------------------------


@pytest.mark.parametrize("text", ["[env]\nFOO = \"1\"\n", '[[env]]\nFOO = "1"\n', '["env"]\nFOO = "1"\n'])
def test_write_rejects_an_env_table(text: str):
    with pytest.raises(MiseEnvError) as excinfo:
        write_pmsec_env(text, [])
    assert excinfo.value.reason == ENV_TABLE


def test_write_rejects_an_env_table_next_to_an_existing_array():
    with pytest.raises(MiseEnvError) as excinfo:
        write_pmsec_env('env = ["a"]\n[env]\nFOO = "1"\n', [])
    assert excinfo.value.reason == ENV_TABLE


@pytest.mark.parametrize("text", ["env.foo = 1\n", "env . foo = 1\n", "x = 1\n[tools]\nenv.foo = 1\n"])
def test_write_rejects_env_dotted_keys(text: str):
    with pytest.raises(MiseEnvError) as excinfo:
        write_pmsec_env(text, [])
    assert excinfo.value.reason == ENV_TABLE


def test_write_allows_tables_that_merely_start_with_env():
    # `[environment]` is a different table: it must neither error nor move.
    assert (
        write_pmsec_env('x = 1\n[environment]\nFOO = "1"\n', [])
        == 'x = 1\nenv = ["pmsec"]\n[environment]\nFOO = "1"\n'
    )


# --- write: idempotence and fail-closed -----------------------------------


def test_write_is_idempotent():
    once = write_pmsec_env('env = ["a"]\n', ["b"])
    assert write_pmsec_env(once, ["b"]) == once
    inserted = write_pmsec_env("", ["a"])
    assert write_pmsec_env(inserted, ["a"]) == inserted
    multiline = write_pmsec_env('env = [\n  "a",\n]\n', ["a"])
    assert write_pmsec_env(multiline, ["a"]) == multiline


@pytest.mark.parametrize(
    "text,reason",
    [
        ("env = [work]\n", ELEMENT),
        ('env = "work"\n', NOT_ARRAY),
        ('env = ["a"]\nenv = ["b"]\n', DUPLICATE),
        ('"env" = ["a"]\n', QUOTED_KEY),
        ('a = """\nno close\n', UNTERMINATED_FILE_STRING),
    ],
)
def test_write_parses_before_producing_output(text: str, reason: str):
    # If any text were produced it would land in `produced`, so an empty list
    # afterwards proves the writer failed closed instead of half-rewriting.
    produced: list[str] = []
    with pytest.raises(MiseEnvError) as excinfo:
        produced.append(write_pmsec_env(text, []))
    assert excinfo.value.reason == reason
    assert produced == []


def test_write_labels_the_error_with_its_source():
    with pytest.raises(MiseEnvError) as excinfo:
        write_pmsec_env("[env]\n", [], "miserc.local.toml")
    assert excinfo.value.path == "miserc.local.toml"
    assert str(excinfo.value) == f"invalid env in miserc.local.toml: {ENV_TABLE}"
