"""Cancellable reference decoding and lens-CA measurement outside the GUI thread."""

from PyQt6.QtCore import QThread, pyqtSignal
import numpy as np

from negpy.features.flatfield.logic import to_sensor_layout
from negpy.features.lens.calibration import apply_calibrated_ca, calibrate_ca
from negpy.services.rendering.preview_manager import PreviewManager


class LensCalibrationWorker(QThread):
    measured = pyqtSignal(object, object, object)
    failed = pyqtSignal(str)

    def __init__(self, path: str, parent=None):
        super().__init__(parent)
        self.path = path

    def run(self):
        try:
            image, _, metadata = PreviewManager().load_linear_preview(
                self.path,
                use_camera_wb=False,
                full_resolution=True,
                demosaic="AHD",
                should_cancel=self.isInterruptionRequested,
            )
            if self.isInterruptionRequested():
                return
            image = to_sensor_layout(image, metadata.get("orientation", 1))
            fit = calibrate_ca(image, self.isInterruptionRequested)
            corrected = apply_calibrated_ca(image, fit.red.coefficients, fit.blue.coefficients, aspect=fit.aspect)
            size = min(160, min(image.shape[:2]) // 4)

            def corners(buffer):
                return np.concatenate(
                    (
                        np.concatenate((buffer[:size, :size], buffer[:size, -size:]), axis=1),
                        np.concatenate((buffer[-size:, :size], buffer[-size:, -size:]), axis=1),
                    ),
                    axis=0,
                )

            before, after = corners(image), corners(corrected)
            neutral = np.maximum(np.median(before.reshape(-1, 3), axis=0), 1e-6)
            before = np.clip(before / neutral * 0.4, 0, 1) ** (1 / 2.2)
            after = np.clip(after / neutral * 0.4, 0, 1) ** (1 / 2.2)
            if not self.isInterruptionRequested():
                self.measured.emit(fit, before, after)
        except InterruptedError:
            pass
        except Exception as error:
            if not self.isInterruptionRequested():
                self.failed.emit(str(error))
