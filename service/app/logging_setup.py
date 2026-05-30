"""Rotating JSON file logging for the service.

Emits one JSON object per line to ``LOG_DIR/service.log`` with rotation at 10MB
and up to 3 backups (per the plan). Console logging is left to uvicorn.
"""
from __future__ import annotations

import json
import logging
from logging.handlers import RotatingFileHandler

from . import config

_CONFIGURED = False


class JsonFormatter(logging.Formatter):
    """Format each record as a compact single-line JSON object."""

    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "ts": self.formatTime(record, "%Y-%m-%dT%H:%M:%SZ"),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
        }
        # Attach structured extras attached via logger.info(..., extra={...}).
        for key in ("job_id", "event_type", "stage", "scene_index"):
            val = getattr(record, key, None)
            if val is not None:
                payload[key] = val
        if record.exc_info:
            payload["exc"] = self.formatException(record.exc_info)
        return json.dumps(payload, ensure_ascii=False)


def configure_logging() -> logging.Logger:
    """Idempotently configure rotating JSON file logging and return the root logger."""
    global _CONFIGURED
    logger = logging.getLogger("book2visual")
    if _CONFIGURED:
        return logger

    config.LOG_DIR.mkdir(parents=True, exist_ok=True)
    handler = RotatingFileHandler(
        config.LOG_DIR / "service.log",
        maxBytes=10 * 1024 * 1024,  # 10MB
        backupCount=3,  # max 3 backup files
        encoding="utf-8",
    )
    handler.setFormatter(JsonFormatter())
    logger.setLevel(logging.INFO)
    logger.addHandler(handler)
    logger.propagate = False
    _CONFIGURED = True
    return logger


def get_logger() -> logging.Logger:
    return configure_logging()
