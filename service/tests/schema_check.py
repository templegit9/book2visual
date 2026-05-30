"""Tiny JSON-Schema (draft 2020-12 subset) validator for tests.

Avoids adding the `jsonschema` dependency just for tests. Supports exactly the
features used by the contract schemas: type (incl. ["int","null"] unions),
required, additionalProperties:false, enum, minimum, maxLength, minItems,
properties, items. Raises AssertionError with a path on the first violation.
"""
from __future__ import annotations

from typing import Any

_TYPE_MAP = {
    "object": dict,
    "array": list,
    "string": str,
    "integer": int,
    "number": (int, float),
    "boolean": bool,
    "null": type(None),
}


def _check_type(value: Any, types, path: str) -> None:
    if isinstance(types, str):
        types = [types]
    py = tuple(_TYPE_MAP[t] for t in types)
    # bool is a subclass of int — guard so a bool isn't accepted as integer.
    if "boolean" not in types and isinstance(value, bool):
        raise AssertionError(f"{path}: bool not allowed for {types}")
    if not isinstance(value, py):
        raise AssertionError(f"{path}: {value!r} is not of type {types}")


def validate(value: Any, schema: dict, path: str = "$") -> None:
    if "type" in schema:
        _check_type(value, schema["type"], path)

    if "enum" in schema:
        assert value in schema["enum"], f"{path}: {value!r} not in enum {schema['enum']}"

    if isinstance(value, str):
        if "maxLength" in schema:
            assert len(value) <= schema["maxLength"], f"{path}: longer than maxLength"
        if "minLength" in schema:
            assert len(value) >= schema["minLength"], f"{path}: shorter than minLength"

    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in schema:
            assert value >= schema["minimum"], f"{path}: below minimum"

    if isinstance(value, dict):
        props = schema.get("properties", {})
        for req in schema.get("required", []):
            assert req in value, f"{path}: missing required key {req!r}"
        if schema.get("additionalProperties") is False:
            extra = set(value) - set(props)
            assert not extra, f"{path}: additional properties not allowed: {extra}"
        for key, sub in value.items():
            if key in props:
                validate(sub, props[key], f"{path}.{key}")

    if isinstance(value, list):
        if "minItems" in schema:
            assert len(value) >= schema["minItems"], f"{path}: fewer than minItems"
        item_schema = schema.get("items")
        if item_schema:
            for i, item in enumerate(value):
                validate(item, item_schema, f"{path}[{i}]")
