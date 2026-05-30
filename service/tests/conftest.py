"""Shared pytest fixtures. Forces STUB mode and an isolated data/log dir."""
from __future__ import annotations

import json
import os
import sys
import tempfile
from pathlib import Path

import pytest

# Ensure stub mode + isolated dirs BEFORE app modules import config.
os.environ["BOOK2VISUAL_STUB"] = "1"
_TMP = Path(tempfile.mkdtemp(prefix="b2v_test_"))
os.environ.setdefault("BOOK2VISUAL_DATA_DIR", str(_TMP / "jobs"))
os.environ.setdefault("BOOK2VISUAL_LOG_DIR", str(_TMP / "logs"))

# Make `app` and `pipeline` importable (service/ is the project root for tests).
SERVICE_ROOT = Path(__file__).resolve().parent.parent
if str(SERVICE_ROOT) not in sys.path:
    sys.path.insert(0, str(SERVICE_ROOT))

CONTRACT_DIR = SERVICE_ROOT.parent / "contract" / "schemas"


@pytest.fixture(scope="session")
def progress_event_schema() -> dict:
    return json.loads((CONTRACT_DIR / "progress_event.schema.json").read_text())


@pytest.fixture(scope="session")
def scene_list_schema() -> dict:
    return json.loads((CONTRACT_DIR / "scene_list.schema.json").read_text())


@pytest.fixture()
def client():
    from fastapi.testclient import TestClient

    from app.main import app

    return TestClient(app)


@pytest.fixture()
def sample_request() -> dict:
    return {
        "text": "Once upon a time " * 200,
        "characters": [
            {"name": "Gregor Samsa", "race_hint": "human"},
            {"name": "Grete"},
        ],
    }
