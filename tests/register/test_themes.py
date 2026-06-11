import pytest

from lazy_vibe.register.model import RegisterError
from lazy_vibe.register.themes import load_vocabulary, map_theme

VOCAB_YAML = """\
themes:
  tenant_scope_missing:
    patterns: ["tenant scope", "account_id filter", "cross-tenant"]
  browser_evidence_missing:
    patterns: ["browser proof", "playwright evidence"]
  rls_ssot_stale:
    patterns: []
"""


@pytest.fixture
def vocab(tmp_path):
    path = tmp_path / "themes.yaml"
    path.write_text(VOCAB_YAML)
    return load_vocabulary(path)


def test_exact_slug_match(vocab):
    assert map_theme("tenant_scope_missing", vocab) == "tenant_scope_missing"
    assert map_theme("RLS_SSOT_STALE", vocab) == "rls_ssot_stale"


def test_pattern_match(vocab):
    assert map_theme("missing browser proof for journey", vocab) == \
        "browser_evidence_missing"
    assert map_theme("query lacks account_id filter", vocab) == \
        "tenant_scope_missing"


def test_unmapped_becomes_candidate(vocab):
    assert map_theme("Quantum Flux Capacitor!", vocab) == \
        "_candidate:quantum_flux_capacitor"


def test_missing_vocabulary_file_is_hard_error(tmp_path):
    with pytest.raises(RegisterError, match="themes.yaml"):
        load_vocabulary(tmp_path / "themes.yaml")


def test_malformed_vocabulary_is_hard_error(tmp_path):
    path = tmp_path / "themes.yaml"
    path.write_text("just a string")
    with pytest.raises(RegisterError, match="themes"):
        load_vocabulary(path)


def test_empty_pattern_rejected(tmp_path):
    path = tmp_path / "themes.yaml"
    path.write_text('themes:\n  foo:\n    patterns: [""]\n')
    with pytest.raises(RegisterError, match="foo"):
        load_vocabulary(path)


def test_non_string_pattern_rejected(tmp_path):
    path = tmp_path / "themes.yaml"
    path.write_text("themes:\n  foo:\n    patterns: [123]\n")
    with pytest.raises(RegisterError, match="foo"):
        load_vocabulary(path)


def test_patterns_must_be_list(tmp_path):
    path = tmp_path / "themes.yaml"
    path.write_text("themes:\n  foo:\n    patterns: tenant scope\n")
    with pytest.raises(RegisterError, match="foo"):
        load_vocabulary(path)


def test_theme_node_must_be_mapping(tmp_path):
    path = tmp_path / "themes.yaml"
    path.write_text("themes:\n  foo:\n    - a\n    - b\n")
    with pytest.raises(RegisterError, match="foo"):
        load_vocabulary(path)


def test_empty_slug_key_rejected(tmp_path):
    path = tmp_path / "themes.yaml"
    path.write_text('themes:\n  "!!!":\n    patterns: []\n')
    with pytest.raises(RegisterError, match="slug"):
        load_vocabulary(path)


def test_candidate_theme_is_idempotent(vocab):
    c = map_theme("Quantum Flux Capacitor!", vocab)
    assert map_theme(c, vocab) == c
