"""Bound overlapping decodes and coalesce identical in-flight preview requests."""

from __future__ import annotations

from concurrent.futures import Future
from contextlib import contextmanager
from contextvars import ContextVar, copy_context
from functools import wraps
import inspect
import os
import threading
import time

from negpy.kernel.system.apple_silicon import is_apple_silicon

_BACKGROUND = ContextVar("background_decode", default=False)


def decode_workers() -> int:
    return min(2, max(1, (os.cpu_count() or 1) // 2))


def configure_decode_threads(environ=None) -> dict[str, str]:
    if not is_apple_silicon():
        return {}
    environ = os.environ if environ is None else environ
    defaults = {
        "OMP_NUM_THREADS": str(max(1, ((os.cpu_count() or 1) - 2) // decode_workers())),
        "OMP_MAX_ACTIVE_LEVELS": "1",
    }
    changed = {key: value for key, value in defaults.items() if key not in environ}
    environ.update(changed)
    return changed


class DecodeBudget:
    def __init__(self, workers: int = 2) -> None:
        self.workers = max(1, workers)
        self._condition = threading.Condition()
        self._active = 0
        self._background = 0
        self._foreground_waiters = 0

    @contextmanager
    def acquire(self, *, background=False, should_cancel=None):
        with self._condition:
            if not background:
                self._foreground_waiters += 1
            try:
                while self._active >= self.workers or (background and (self._background or self._foreground_waiters)):
                    if should_cancel is not None and should_cancel():
                        raise InterruptedError("preview load cancelled")
                    self._condition.wait(0.05)
                if should_cancel is not None and should_cancel():
                    raise InterruptedError("preview load cancelled")
                self._active += 1
                self._background += int(background)
            finally:
                if not background:
                    self._foreground_waiters -= 1
                self._condition.notify_all()
        try:
            yield
        finally:
            with self._condition:
                self._active -= 1
                self._background -= int(background)
                self._condition.notify_all()


class DecodeFlights:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._pending: dict[tuple, Future] = {}
        self._completed = 0
        self._shared = 0
        self._failed = 0
        self._elapsed = 0.0

    def run(self, key, operation, *, should_cancel=None):
        while True:
            if should_cancel is not None and should_cancel():
                raise InterruptedError("preview load cancelled")
            with self._lock:
                future = self._pending.get(key)
                owner = future is None
                if owner:
                    future = Future()
                    self._pending[key] = future
                else:
                    self._shared += 1
            if owner:
                started = time.perf_counter()
                try:
                    result = operation()
                except BaseException as error:
                    future.set_exception(error)
                    with self._lock:
                        self._failed += 1
                    raise
                else:
                    future.set_result(result)
                    return result
                finally:
                    with self._lock:
                        self._pending.pop(key, None)
                        self._completed += 1
                        self._elapsed += time.perf_counter() - started
            while not future.done():
                if should_cancel is not None and should_cancel():
                    raise InterruptedError("preview load cancelled")
                threading.Event().wait(0.02)
            if should_cancel is not None and should_cancel():
                raise InterruptedError("preview load cancelled")
            try:
                return future.result()
            except InterruptedError:
                continue

    def snapshot(self) -> dict:
        with self._lock:
            return {
                "in_flight": len(self._pending),
                "completed": self._completed,
                "shared_requests": self._shared,
                "failed": self._failed,
                "total_seconds": self._elapsed,
            }


DECODE_BUDGET = DecodeBudget(decode_workers())
DECODE_FLIGHTS = DecodeFlights()


def background_decode(function):
    @wraps(function)
    def run(*args, **kwargs):
        token = _BACKGROUND.set(True)
        try:
            return function(*args, **kwargs)
        finally:
            _BACKGROUND.reset(token)

    return run


def submit_decode(pool, function, *args, **kwargs):
    return pool.submit(copy_context().run, function, *args, **kwargs)


def bounded_decode(function):
    @wraps(function)
    def run(*args, **kwargs):
        if not is_apple_silicon():
            return function(*args, **kwargs)
        with DECODE_BUDGET.acquire(background=_BACKGROUND.get(), should_cancel=kwargs.get("should_cancel")):
            return function(*args, **kwargs)

    return run


def coordinated_decode(function):
    signature = inspect.signature(function)
    excluded = {"self", "raw", "metadata", "should_cancel", "log_timings", "cache_protected_file_hashes", "cache_preserve_full_resolution"}

    @wraps(function)
    def run(*args, **kwargs):
        bound = signature.bind(*args, **kwargs)
        bound.apply_defaults()
        values = bound.arguments
        try:
            stat = os.stat(values["file_path"])
            revision = (stat.st_size, stat.st_mtime_ns)
        except OSError:
            revision = None
        key = (id(values["self"]), revision, tuple((name, repr(value)) for name, value in values.items() if name not in excluded))
        should_cancel = values.get("should_cancel")

        def decode():
            if not is_apple_silicon():
                return function(*args, **kwargs)
            with DECODE_BUDGET.acquire(background=_BACKGROUND.get(), should_cancel=should_cancel):
                return function(*args, **kwargs)

        return DECODE_FLIGHTS.run(key, decode, should_cancel=should_cancel)

    return run
