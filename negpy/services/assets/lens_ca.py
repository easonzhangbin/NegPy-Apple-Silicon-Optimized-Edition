"""Portable measured lens-CA profiles; edits also retain their own coefficients."""

import json
import math
import os
from pathlib import Path
import tempfile
import uuid

from negpy.features.geometry.models import GeometryConfig
from negpy.kernel.system.config import APP_CONFIG

FIELDS = ("lens_ca_red", "lens_ca_blue", "lens_ca_aspect", "lens_ca_name")


def validate(values: dict) -> GeometryConfig:
    for field in ("lens_ca_red", "lens_ca_blue"):
        coefficients = tuple(float(value) for value in values[field])
        if len(coefficients) != 2 or any(not math.isfinite(value) or abs(value) > 0.02 for value in coefficients):
            raise ValueError("invalid lens coefficients")
    aspect = float(values["lens_ca_aspect"])
    if not math.isfinite(aspect) or aspect <= 0 or not isinstance(values["lens_ca_name"], str) or not values["lens_ca_name"].strip():
        raise ValueError("invalid lens profile")
    return GeometryConfig(**{key: values[key] for key in FIELDS})


def directory() -> Path:
    return Path(APP_CONFIG.flatfield_dir).parent / "lens_ca"


def save_profile(values: dict) -> str:
    normalized = validate(values)
    data = {key: getattr(normalized, key) for key in FIELDS}
    data["schema"] = 1
    target = directory()
    target.mkdir(parents=True, exist_ok=True)
    profile_id = uuid.uuid4().hex
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=target, delete=False) as handle:
            temporary = handle.name
            json.dump(data, handle, ensure_ascii=False, indent=2, allow_nan=False)
        os.replace(temporary, target / f"{profile_id}.json")
    finally:
        if temporary and os.path.exists(temporary):
            os.unlink(temporary)
    return profile_id


def profiles() -> list[tuple[str, dict]]:
    result = []
    if directory().is_dir():
        for path in directory().glob("*.json"):
            try:
                data = json.loads(path.read_text(encoding="utf-8"))
                if not isinstance(data, dict) or data.get("schema") != 1:
                    continue
                normalized = validate(data)
                result.append((path.stem, {key: getattr(normalized, key) for key in FIELDS}))
            except (ValueError, TypeError, KeyError, OSError):
                continue
    return sorted(result, key=lambda item: item[1]["lens_ca_name"].casefold())
