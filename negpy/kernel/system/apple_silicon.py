"""Apple Silicon resource policy.

An M-series Mac has one pool of unified memory shared by CPU and GPU, and its Metal device
reports real limits. NegPy's generic "integrated GPU" defaults are sized for the worst
integrated GPU it might meet (a tight, unqueryable shared-VRAM budget), which on a 32-128 GB
M-series machine caps the HQ preview below the scan's own resolution and keeps the preview
cache small. Here those defaults scale with the installed memory instead.

Everything here applies only on macOS/arm64 and only to defaults: override.toml and
Preferences still win, and no rendering math changes.
"""

from __future__ import annotations

import os
import platform
import subprocess
import sys
import threading
import time
from functools import lru_cache

GIB = 1024**3
_headroom_lock = threading.Lock()
_headroom_time = 0.0
_headroom_bytes: int | None = None


def retain_source_tiles(source_bytes: int) -> bool:
    if not ample_unified_memory():
        return False
    from negpy.kernel.system.memory import available_system_memory_bytes

    global _headroom_time, _headroom_bytes
    with _headroom_lock:
        now = time.monotonic()
        if now - _headroom_time >= 1.0:
            _headroom_bytes = available_system_memory_bytes()
            _headroom_time = now
        return _headroom_bytes is not None and _headroom_bytes >= max(2 * GIB, source_bytes * 4)


def is_apple_silicon(sys_platform: str | None = None, machine: str | None = None) -> bool:
    return (sys_platform or sys.platform) == "darwin" and (machine or platform.machine()) == "arm64"


@lru_cache(maxsize=1)
def unified_memory_bytes() -> int | None:
    """Installed memory (hw.memsize), or None when it cannot be read."""
    try:
        pages, page = os.sysconf("SC_PHYS_PAGES"), os.sysconf("SC_PAGE_SIZE")
        if pages > 0 and page > 0:
            return int(pages) * int(page)
    except (ValueError, OSError, AttributeError):
        pass
    try:
        out = subprocess.run(["sysctl", "-n", "hw.memsize"], capture_output=True, text=True, timeout=2)
        return int(out.stdout.strip())
    except Exception:
        return None


def configure_openmp_runtime(environ=None) -> dict[str, str]:
    """Choose OpenMP runtime settings before LibRaw first uses it. Returns what was set.

    The Apple Silicon build ships an OpenMP LibRaw (libomp). With several decodes running at
    once (neighbour prefetch, the foreground open, the three RGB-scan exposures), libomp's
    default queuing lock for `#pragma omp critical` deadlocks on Apple Silicon: every thread
    ends up waiting in __kmp_acquire_queuing_lock inside LibRaw::copy_bayer, the releasing
    thread waiting for a successor that never links in. Measured on an M1 Max: three
    concurrent decodes hang within a minute with the default lock and run clean with the
    test-and-set lock, at the same throughput. libomp reads KMP_LOCK_KIND when it
    initialises, on LibRaw's first OpenMP call, so this runs at package import. A value the
    user already set wins.
    """
    env = os.environ if environ is None else environ
    if not is_apple_silicon():
        return {}
    if "KMP_LOCK_KIND" in env:
        return {}
    env["KMP_LOCK_KIND"] = "tas"
    return {"KMP_LOCK_KIND": "tas"}


def hq_texture_cap(memory_bytes: int | None, device_limit: int | None) -> int | None:
    """Long-edge cap for a full-resolution (HQ) preview load on Apple Silicon.

    None means "no Apple-specific answer"; the caller keeps the generic integrated-GPU cap.
    A 60 MP scan (about 9500 px on the long edge) needs more than the generic 6144 to load
    at its own resolution; a pixel-shift 96 MP RAW (12000 px) holds a 1.1 GB float buffer
    before any texture. 32 GB carries both at full size; 16 GB gets 8192, a third more
    than the generic cap; 8 GB keeps the generic one.
    """
    if not memory_bytes:
        return None
    if memory_bytes >= 32 * GIB:
        cap = 16384
    elif memory_bytes >= 16 * GIB:
        cap = 8192
    else:
        return None
    if device_limit:
        cap = min(cap, int(device_limit))
    return cap


def ample_unified_memory(memory_bytes: int | None = None) -> bool:
    """Apple Silicon with 32 GB or more of unified memory."""
    if not is_apple_silicon():
        return False
    mem = memory_bytes if memory_bytes is not None else unified_memory_bytes()
    return bool(mem and mem >= 32 * GIB)


def full_resolution_prefetch(hq_preview: bool, memory_bytes: int | None = None) -> bool:
    """Warm the filmstrip neighbours at full resolution when HQ preview is on.

    NegPy prefetches neighbours at preview size, which an HQ session never reads: its
    load asks for the full-resolution cache entry, so every step through a roll pays the
    whole RAW decode in the foreground. With 32 GB+ of unified memory a neighbour's full
    buffer (about 0.3-0.7 GB) sits beside the current one with room to spare; the decode
    happens while the user looks at the current frame, and the step is a cache hit.
    The prefetch still passes the same RAM safety check as before.
    """
    return bool(hq_preview) and ample_unified_memory(memory_bytes)


def cache_budget(memory_bytes: int | None) -> dict[str, int]:
    """Preview-cache defaults scaled to unified memory. Empty below 16 GB (generic defaults stay)."""
    if not memory_bytes or memory_bytes < 16 * GIB:
        return {}
    # Sized for HQ neighbour prefetch: the frame on screen plus both neighbours at full
    # resolution (a 96 MP pixel-shift RAW is about 3 GB in the cache's own estimate). The
    # prefetch still checks free RAM before every warm, so a busy machine skips it.
    if memory_bytes >= 64 * GIB:
        return {
            "preview_cache_max_bytes": 12 * GIB,
            "preview_cache_max_entries": 16,
            "preview_cache_max_full_res_entries": 4,
            "render_memo_max_entries": 16,
        }
    if memory_bytes >= 32 * GIB:
        return {
            "preview_cache_max_bytes": 6 * GIB,
            "preview_cache_max_entries": 12,
            "preview_cache_max_full_res_entries": 3,
            "render_memo_max_entries": 12,
        }
    return {
        "preview_cache_max_bytes": 2 * GIB,
        "preview_cache_max_entries": 10,
        "preview_cache_max_full_res_entries": 2,
        "render_memo_max_entries": 10,
    }


def apply_cache_defaults(app_config, memory_bytes: int | None = None) -> dict[str, int]:
    """Raise the AppConfig cache defaults on Apple Silicon. Run before override.toml and the
    stored Preferences are applied, so either still wins. Returns what changed."""
    if not is_apple_silicon():
        return {}
    budget = cache_budget(memory_bytes if memory_bytes is not None else unified_memory_bytes())
    changed = {}
    for key, value in budget.items():
        if hasattr(app_config, key) and getattr(app_config, key) < value:
            setattr(app_config, key, value)
            changed[key] = value
    return changed
