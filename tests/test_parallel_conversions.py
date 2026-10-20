"""The multi-core conversion kernels must produce exactly what their serial variants produce.

They run on every texture upload/readback, decode and export, so a single flipped rounding
would show up as a changed pixel. Inputs include values sitting on the rounding boundary.
"""

import numpy as np
import pytest

from negpy.kernel.image import logic

H, W = 301, 517  # odd sizes, above SERIAL_MAX_ELEMENTS


def _floats(seed=0):
    rng = np.random.default_rng(seed)
    a = rng.random((H, W, 3), dtype=np.float32) * 1.2 - 0.1
    flat = a.reshape(-1)
    # Exact rounding boundaries for both quantisers, NaN, infinities and the clip edges.
    n = 4096
    k8 = rng.integers(0, 256, n)
    k16 = rng.integers(0, 65536, n)
    flat[:n] = ((k8 + 0.5) / 255.0).astype(np.float32)
    flat[n : 2 * n] = ((k16 + 0.5) / 65535.0).astype(np.float32)
    flat[2 * n : 3 * n] = np.nextafter(flat[:n], np.float32(1.0))
    flat[3 * n : 4 * n] = np.nextafter(flat[n : 2 * n], np.float32(0.0))
    flat[4 * n : 4 * n + 6] = [np.nan, np.inf, -np.inf, 0.0, 1.0, -0.0]
    return a


@pytest.mark.parametrize("name", ["_to_uint8_jit", "_to_uint16_jit"])
def test_quantisers_parallel_equals_serial(name):
    k = getattr(logic, name)
    a = _floats()
    np.testing.assert_array_equal(k.parallel(a), k.serial(a))


@pytest.mark.parametrize("name,dtype,top", [("uint8_to_float32", np.uint8, 256), ("uint16_to_float32", np.uint16, 65536)])
def test_int_to_float_parallel_equals_serial(name, dtype, top):
    k = getattr(logic, name)
    a = np.random.default_rng(1).integers(0, top, (H, W, 3)).astype(dtype)
    a.reshape(-1)[:2] = [0, top - 1]
    np.testing.assert_array_equal(k.parallel(a), k.serial(a))


def test_rgba_copies_parallel_equal_serial():
    src = _floats(2)
    d1 = np.full((H, W, 4), 7.0, np.float32)
    d2 = d1.copy()
    logic.rgb_to_rgba_into.parallel(src, d1)
    logic.rgb_to_rgba_into.serial(src, d2)
    np.testing.assert_array_equal(d1, d2)

    rgba = np.random.default_rng(3).random((H + 20, W + 30, 4), dtype=np.float32)
    o1 = np.zeros((H, W, 3), np.float32)
    o2 = np.zeros((H, W, 3), np.float32)
    logic.rgba_to_rgb_into.parallel(rgba, o1, 11, 17)
    logic.rgba_to_rgb_into.serial(rgba, o2, 11, 17)
    np.testing.assert_array_equal(o1, o2)
