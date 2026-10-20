"""Flat-reference diagnostics and comparable brightness/chromaticity maps."""

from typing import NamedTuple

import cv2
import numpy as np

from negpy.features.flatfield.logic import _lit_mask, work_copy


class ReferenceQuality(NamedTuple):
    clipped_fraction: float
    high_frequency: float
    gain_maximum: float
    gain_limited_fraction: float


def reference_quality(reference: np.ndarray, gain: np.ndarray) -> ReferenceQuality:
    sample = work_copy(reference, 1600)
    mask = _lit_mask(sample).astype(bool)
    median = np.maximum(np.median(sample[mask], axis=0), 1e-6)
    residual = (sample - cv2.GaussianBlur(sample, (0, 0), 0.8)) / median
    variation = float(np.median(np.abs(residual[mask])) * 1.4826)
    return ReferenceQuality(
        float((sample[mask] >= 0.98).any(axis=1).mean()),
        variation,
        float(np.max(gain)),
        float(((gain <= 0.2501) | (gain >= 3.999)).mean()),
    )


def distribution_maps(image: np.ndarray, reference: np.ndarray) -> tuple[np.ndarray, np.ndarray, float, float]:
    sample = np.maximum(image.astype(np.float32), 1e-8)
    mask = _lit_mask(reference).astype(bool)
    baseline = np.maximum(np.median(reference[mask], axis=0), 1e-8)
    logarithm = np.log2(sample / baseline)
    brightness = logarithm.mean(axis=2)
    color = logarithm - brightness[..., None]
    brightness_view = np.repeat(np.clip(0.5 + brightness[..., None] / 2, 0, 1), 3, axis=2)
    color_view = np.clip(0.5 + color / 0.5, 0, 1)
    brightness_view[~mask] = 0
    color_view[~mask] = 0
    return (
        brightness_view.astype(np.float32),
        color_view.astype(np.float32),
        float(np.percentile(np.abs(brightness[mask]), 95)),
        float(np.percentile(np.abs(color[mask]), 95)),
    )
