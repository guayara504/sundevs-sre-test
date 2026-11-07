"""Pruebas del orquestador de DR (sin AWS ni GitHub reales)."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent


@pytest.fixture
def orch(monkeypatch):
    monkeypatch.setenv("AWS_DEFAULT_REGION", "us-east-2")
    monkeypatch.setenv("STATUS_PARAMETER", "/p/status")
    monkeypatch.setenv("TOKEN_SECRET_ID", "secret")
    monkeypatch.setenv("NOTIFY_TOPIC_ARN", "arn:topic")
    monkeypatch.setenv("GITHUB_REPOSITORY", "owner/repo")
    monkeypatch.setenv("AUTO_FAILOVER", "true")
    monkeypatch.setenv("PRIMARY_HEALTH_URL", "https://primary/health")

    spec = importlib.util.spec_from_file_location("dr_orchestrator_app", ROOT / "src/dr_orchestrator/app.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    state = {"status": "STANDBY", "notifications": [], "dispatched": 0, "token": "tok", "healthy": False}

    class SSM:
        def get_parameter(self, Name):
            return {"Parameter": {"Value": state["status"]}}

        def put_parameter(self, Name, Value, Type, Overwrite):
            state["status"] = Value

    module.ssm = SSM()
    module._notify = lambda subject, message: state["notifications"].append(subject)
    module._get_token = lambda: state["token"]
    module._primary_is_healthy = lambda: state["healthy"]

    def dispatch(token, reason):
        state["dispatched"] += 1
        return 204

    module._dispatch = dispatch
    return module, state


def _alarm(state_value="ALARM"):
    message = {"AlarmName": "primary-down", "NewStateValue": state_value, "NewStateReason": "3/3 en 0"}
    return {"Records": [{"Sns": {"Message": json.dumps(message)}}]}


def test_dispatches_failover_and_marks_status(orch):
    module, state = orch
    result = module.handler(_alarm(), None)
    assert result["action"] == "dispatched"
    assert state["dispatched"] == 1
    assert state["status"].startswith("FAILOVER_TRIGGERED")


def test_is_idempotent(orch):
    module, state = orch
    module.handler(_alarm(), None)
    second = module.handler(_alarm(), None)
    assert second["action"] == "skipped"
    assert state["dispatched"] == 1


def test_false_alarm_when_primary_still_healthy(orch):
    module, state = orch
    state["healthy"] = True
    result = module.handler(_alarm(), None)
    assert result["action"] == "false-alarm"
    assert state["dispatched"] == 0
    assert state["status"] == "STANDBY"


def test_missing_token_requires_manual_action(orch):
    module, state = orch
    state["token"] = None
    result = module.handler(_alarm(), None)
    assert result["action"] == "manual-required"
    assert state["dispatched"] == 0


def test_ok_state_is_ignored(orch):
    module, state = orch
    assert module.handler(_alarm("OK"), None)["action"] == "ignored"
    assert state["dispatched"] == 0


def test_dry_run_does_not_dispatch(orch):
    module, state = orch
    result = module.handler({"dry_run": True}, None)
    assert result["action"] == "dry-run"
    assert state["dispatched"] == 0
