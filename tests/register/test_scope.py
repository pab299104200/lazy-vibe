import pytest

from lazy_vibe.register.model import RegisterError
from lazy_vibe.register.scope import load_scope, matches
from tests.register.helpers import with_history
from tests.register.test_model import make_finding

SCOPE_YAML = """\
product: meridian
default_in_scope: false
surfaces:
  - slug: evidence-collection
    paths: ["backend/routers/evidence", "backend/core/evidence"]
    routes: ["/api/evidence"]
  - slug: cloud-connectors
    paths: ["backend/connectors/"]
    routes: []
severity_bar:
  P0: zero_open
  P1: zero_open_or_risk_accepted
  P2: triaged
gates:
  - id: backend-tests
    type: command
    command: "true"
  - id: sast-critical
    type: artifact_json
    path: artifacts/sast-summary.json
    key: critical_count
    op: eq
    value: 0
    max_age_days: 14
"""


@pytest.fixture
def scope(tmp_path):
    p = tmp_path / "launch-scope.yaml"
    p.write_text(SCOPE_YAML)
    return load_scope(p)


def test_load_scope_parses(scope):
    assert scope.product == "meridian"
    assert scope.default_in_scope is False
    assert [s.slug for s in scope.surfaces] == ["evidence-collection",
                                                "cloud-connectors"]
    assert scope.severity_bar["P1"] == "zero_open_or_risk_accepted"
    assert scope.gates[1].params["max_age_days"] == 14


def test_match_by_path_prefix(scope):
    f = make_finding()  # path backend/routers/evidence.py
    assert matches(f, scope) is True


def test_match_by_route_in_title(scope):
    f = make_finding(
        fingerprint_inputs={"category": "product_gap", "theme": "t",
                            "path": "docs/functional/evidence.md",
                            "symbol": "-"},
        title="GET /api/evidence returns rows for all accounts")
    assert matches(f, scope) is True


def test_no_match_uses_default(scope):
    f = make_finding(
        fingerprint_inputs={"category": "product_gap", "theme": "t",
                            "path": "backend/internal/billing.py",
                            "symbol": "-"},
        title="internal billing rounding")
    assert matches(f, scope) is False


def test_default_in_scope_true(tmp_path):
    p = tmp_path / "launch-scope.yaml"
    p.write_text(SCOPE_YAML.replace("default_in_scope: false",
                                    "default_in_scope: true"))
    scope = load_scope(p)
    f = make_finding(
        fingerprint_inputs={"category": "product_gap", "theme": "t",
                            "path": "backend/internal/billing.py",
                            "symbol": "-"},
        title="internal billing rounding")
    assert matches(f, scope) is True


def test_missing_scope_file_is_hard_error(tmp_path):
    with pytest.raises(RegisterError, match="launch-scope"):
        load_scope(tmp_path / "launch-scope.yaml")


def test_malformed_scope_is_hard_error(tmp_path):
    p = tmp_path / "launch-scope.yaml"
    p.write_text("just a string")
    with pytest.raises(RegisterError, match="mapping"):
        load_scope(p)


def test_bad_severity_bar_rejected(tmp_path):
    p = tmp_path / "launch-scope.yaml"
    p.write_text(SCOPE_YAML.replace("zero_open\n", "whatever\n", 1))
    with pytest.raises(RegisterError, match="severity_bar"):
        load_scope(p)


def test_bad_gate_type_rejected(tmp_path):
    p = tmp_path / "launch-scope.yaml"
    p.write_text(SCOPE_YAML.replace("type: command", "type: magic"))
    with pytest.raises(RegisterError, match="gate"):
        load_scope(p)
