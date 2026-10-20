"""Reference-based radial lateral chromatic aberration calibration in sensor RGB."""

from dataclasses import dataclass
from typing import Callable

import cv2
import numpy as np

from negpy.kernel.image.logic import apply_exif_orientation


class CalibrationError(ValueError):
    pass


@dataclass(frozen=True)
class ChannelFit:
    coefficients: tuple[float, float]
    before_px: float
    after_px: float
    patches: int


@dataclass(frozen=True)
class ChromaticFit:
    red: ChannelFit
    blue: ChannelFit
    aspect: float
    analysis_scale: float


def _highpass(plane: np.ndarray) -> np.ndarray:
    smooth = cv2.GaussianBlur(plane, (0, 0), 1.2)
    return (plane - smooth).astype(np.float32)


def _fit_channel(reference: np.ndarray, moving: np.ndarray, cancelled: Callable[[], bool]) -> ChannelFit:
    height, width = reference.shape
    center = np.array([(width - 1) / 2, (height - 1) / 2])
    radius = np.linalg.norm(center)
    half = max(12, min(height // 14, width // 18))
    points, shifts = [], []
    template, source = _highpass(reference), _highpass(moving)
    for row in np.linspace(0.12 * height, 0.88 * height, 6).astype(int):
        for column in np.linspace(0.12 * width, 0.88 * width, 8).astype(int):
            if cancelled():
                raise InterruptedError("calibration cancelled")
            section = np.s_[row - half : row + half, column - half : column + half]
            first, second = template[section], source[section]
            if min(float(first.std()), float(second.std())) < 0.001:
                continue
            if max(float((reference[section] >= 0.98).mean()), float((moving[section] >= 0.98).mean())) > 0.02:
                continue
            first = np.ascontiguousarray(first / max(float(first.std()), 1e-6))
            second = np.ascontiguousarray(second / max(float(second.std()), 1e-6))
            warp = np.eye(2, 3, dtype=np.float32)
            shift, response = cv2.phaseCorrelate(first, second)
            if response > 0.2 and np.linalg.norm(shift) < half / 4:
                warp[:, 2] = shift
            try:
                correlation, warp = cv2.findTransformECC(
                    first,
                    second,
                    warp,
                    cv2.MOTION_TRANSLATION,
                    (cv2.TERM_CRITERIA_COUNT | cv2.TERM_CRITERIA_EPS, 50, 1e-5),
                    None,
                    3,
                )
            except cv2.error:
                continue
            if correlation < 0.8 or np.linalg.norm(warp[:, 2]) > min(12, half / 4):
                continue
            points.append((column, row))
            shifts.append(warp[:, 2].copy())
    if len(points) < 20:
        raise CalibrationError("low_texture")
    positions = np.asarray(points, np.float64) - center
    measured = np.asarray(shifts, np.float64)
    quadrants = (positions[:, 0] > 0).astype(int) + 2 * (positions[:, 1] > 0).astype(int)
    if any(np.count_nonzero(quadrants == quadrant) < 3 for quadrant in range(4)):
        raise CalibrationError("poor_coverage")
    radial = (positions**2).sum(axis=1) / radius**2
    if np.ptp(radial) < 0.25:
        raise CalibrationError("poor_coverage")
    basis = np.stack([positions, positions * radial[:, None]], axis=2)
    validation = np.arange(len(points)) % 5 == 0
    training = ~validation
    matrix = basis[training].reshape(-1, 2)
    target = measured[training].reshape(-1)
    weights = np.ones(len(target))
    for _iteration in range(6):
        coefficients = np.linalg.lstsq(matrix * weights[:, None], target * weights, rcond=None)[0]
        residual = matrix @ coefficients - target
        weights = np.sqrt(np.minimum(1.0, 0.15 / np.maximum(np.abs(residual), 1e-6)))
    predicted = basis @ coefficients
    errors = np.linalg.norm(predicted - measured, axis=1)
    before = float(np.sqrt(np.mean((measured[validation] ** 2).sum(axis=1))))
    after = float(np.sqrt(np.mean(errors[validation] ** 2)))
    if before < 0.075 and float(np.percentile(np.linalg.norm(measured, axis=1), 90)) < 0.15:
        return ChannelFit((0.0, 0.0), before, before, len(points))
    if not np.isfinite(coefficients).all() or np.max(np.abs(coefficients)) > 0.02:
        raise CalibrationError("unreliable_fit")
    if after > 0.35 or after > before * 0.75 or float((errors < 0.35).mean()) < 0.7:
        raise CalibrationError("unreliable_fit")
    return ChannelFit(tuple(float(value) for value in coefficients), before, after, len(points))


def calibrate_ca(image: np.ndarray, cancelled: Callable[[], bool] = lambda: False) -> ChromaticFit:
    if image.ndim != 3 or image.shape[2] != 3 or min(image.shape[:2]) < 256:
        raise CalibrationError("reference_size")
    if not np.isfinite(image).all() or float(image.max()) <= 0:
        raise CalibrationError("invalid_reference")
    scale = min(1.0, 2400 / max(image.shape[:2]))
    small = image.astype(np.float32)
    if scale < 1:
        small = cv2.resize(small, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
    red = _fit_channel(small[..., 1], small[..., 0], cancelled)
    blue = _fit_channel(small[..., 1], small[..., 2], cancelled)
    return ChromaticFit(red, blue, image.shape[1] / image.shape[0], scale)


def apply_calibrated_ca(image: np.ndarray, red: tuple, blue: tuple, orientation: int = 1, aspect: float = 0.0) -> np.ndarray:
    if not any(red) and not any(blue):
        return image
    sensor = apply_exif_orientation(image, {6: 8, 8: 6}.get(orientation, orientation))
    height, width = sensor.shape[:2]
    if min(height, width) < 2 or (aspect and abs(width / height / aspect - 1) > 0.015):
        return image
    if any(
        len(coefficients) != 2 or not np.isfinite(coefficients).all() or np.max(np.abs(coefficients)) > 0.02 for coefficients in (red, blue)
    ):
        return image
    center_x, center_y = (width - 1) / 2, (height - 1) / 2
    radius_squared = center_x**2 + center_y**2
    columns = np.arange(width, dtype=np.float32)[None, :] - center_x
    result = sensor.copy()
    for channel, coefficients in ((0, red), (2, blue)):
        if not any(coefficients):
            continue
        plane = np.ascontiguousarray(sensor[..., channel])
        for start in range(0, height, 256):
            stop = min(start + 256, height)
            rows = np.arange(start, stop, dtype=np.float32)[:, None] - center_y
            factor = 1 + coefficients[0] + coefficients[1] * (columns**2 + rows**2) / radius_squared
            mapping_x = (center_x + columns * factor).astype(np.float32)
            mapping_y = (center_y + rows * factor).astype(np.float32)
            result[start:stop, :, channel] = cv2.remap(plane, mapping_x, mapping_y, cv2.INTER_CUBIC, borderMode=cv2.BORDER_REPLICATE)
    result = np.maximum(result, 0)
    return np.ascontiguousarray(apply_exif_orientation(result, orientation))
