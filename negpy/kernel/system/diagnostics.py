"""Offline package diagnostics without opening databases or USB devices."""

import json
import importlib
import os
from pathlib import Path
import platform
import sys
from typing import Any

from negpy.kernel.system.apple_silicon import unified_memory_bytes
from negpy.kernel.system.paths import get_resource_path
from negpy.kernel.system.work_budget import DECODE_FLIGHTS, decode_workers


def report() -> dict:
    result = {
        "platform": platform.platform(),
        "machine": platform.machine(),
        "python": platform.python_version(),
        "cpu_count": os.cpu_count(),
        "unified_memory_bytes": unified_memory_bytes(),
        "decode_workers": decode_workers(),
        "openmp": {key: os.environ.get(key) for key in ("OMP_NUM_THREADS", "OMP_MAX_ACTIVE_LEVELS", "KMP_LOCK_KIND")},
        "decode_metrics": DECODE_FLIGHTS.snapshot(),
        "camera_devices_accessed": False,
        "user_database_opened": False,
    }
    marker = Path(get_resource_path("BUILD_VARIANT.json"))
    result["build"] = json.loads(marker.read_text()) if marker.exists() else None
    try:
        import rawpy

        result["rawpy"] = {"version": rawpy.__version__, "libraw": list(rawpy.libraw_version)}
    except Exception as error:
        result["rawpy"] = {"error": str(error)}
    try:
        camera: Any = importlib.import_module("gphoto2")
        abilities = camera.CameraAbilitiesList()
        abilities.load()
        names = {abilities[index].model for index in range(len(abilities))}
        result["camera"] = {
            "python_gphoto2": camera.__version__,
            "libgphoto2": camera.gp_library_version(camera.GP_VERSION_SHORT),
            "drivers_loaded": len(names),
            "named_profiles": {name: name in names for name in ("Sony ILCE-1 (Control)", "Leica M11", "Leica M11 Monochrom")},
        }
    except Exception as error:
        result["camera"] = {"error": str(error)}
    return result


def main(arguments=None) -> None:
    arguments = sys.argv[1:] if arguments is None else arguments
    text = json.dumps(report(), ensure_ascii=False, indent=2) + "\n"
    if arguments:
        Path(arguments[0]).write_text(text, encoding="utf-8")
    else:
        print(text)


if __name__ == "__main__":
    main()
