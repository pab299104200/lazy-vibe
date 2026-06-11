from lazy_vibe.register.fingerprint import (compute, jaccard, normalize_path,
                                            title_tokens)


def test_normalize_path_strips_line_suffix_and_dot_prefix():
    assert normalize_path("./backend/routers/evidence.py:118") == \
        "backend/routers/evidence.py"
    assert normalize_path("backend/routers/evidence.py") == \
        "backend/routers/evidence.py"
    assert normalize_path("  backend/x.py:12-40 ") == "backend/x.py"


def test_compute_is_stable_and_text_independent():
    a = compute("product_gap", "tenant_scope_missing",
                "./backend/routers/evidence.py:118", "-")
    b = compute("product_gap", "tenant_scope_missing",
                "backend/routers/evidence.py", "-")
    assert a == b
    assert a.startswith("sha256:")
    assert len(a) == len("sha256:") + 16


def test_compute_differs_on_any_input():
    base = compute("product_gap", "tenant_scope_missing", "backend/x.py", "-")
    assert compute("evidence_gap", "tenant_scope_missing", "backend/x.py", "-") != base
    assert compute("product_gap", "other_theme", "backend/x.py", "-") != base
    assert compute("product_gap", "tenant_scope_missing", "backend/y.py", "-") != base
    assert compute("product_gap", "tenant_scope_missing", "backend/x.py", "f") != base


def test_title_tokens_normalizes():
    assert title_tokens("Evidence list endpoint NOT tenant-scoped!") == \
        {"evidence", "list", "endpoint", "not", "tenant", "scoped"}


def test_jaccard():
    assert jaccard({"a", "b"}, {"a", "b"}) == 1.0
    assert jaccard({"a", "b"}, {"c", "d"}) == 0.0
    assert jaccard({"a", "b", "c"}, {"b", "c", "d"}) == 0.5
    assert jaccard(set(), set()) == 0.0
