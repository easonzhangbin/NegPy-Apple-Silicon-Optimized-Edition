from negpy.kernel.system.i18n import tr
from dataclasses import replace

from PyQt6.QtWidgets import QHBoxLayout
from negpy.desktop.view.widgets.step_combo import StepCombo
from negpy.services.assets import lens_ca
from negpy.features.stitch.models import stitch_active
from negpy.features.hdr.models import hdr_active
from negpy.features.rgbscan.models import is_rgb_triplet

from negpy.desktop.view.sidebar.base import BaseSidebar
from negpy.desktop.view.styles.templates import field_label, hint_label, wrap_tooltip
from negpy.desktop.view.widgets.sliders import CompactSlider
from negpy.features.lens.models import LensMetadata
from negpy.infrastructure.loaders.lens_metadata import read_lens_metadata
from negpy.services.rendering.lens import metadata_lens_corrections


class LensSidebar(BaseSidebar):
    """
    Roll-wide correction of the scanning lens: radial distortion by hand, or the
    distortion and lateral CA the source file carries.
    """

    def _init_ui(self) -> None:
        conf = self.state.config.geometry

        self.distortion_slider = CompactSlider(
            tr("Distortion Correction"), -0.10, 0.10, conf.distortion_k1, step=0.001, precision=1000, has_neutral=True
        )
        # Nothing derives the readout's decimals from `precision`, so a 0.001 step needs both.
        self.distortion_slider.spin.setDecimals(3)
        self.distortion_slider.setToolTip(
            wrap_tooltip(
                tr("Radial lens distortion. Positive corrects barrel, negative pincushion. Use the film rebate as a straight reference.")
            )
        )

        self.metadata_distortion_btn = self._labeled_toggle(
            "fa5s.camera",
            tr(" Distortion"),
            conf.lens_distortion_from_metadata,
            tr("Apply embedded scanning-lens distortion correction. Replaces manual distortion."),
        )
        self.metadata_ca_btn = self._labeled_toggle(
            "fa5s.camera",
            tr(" CA"),
            conf.lens_ca_from_metadata,
            tr("Apply embedded lateral chromatic aberration correction. Can be used with manual distortion."),
        )
        # The file's own profile first: its distortion replaces the manual slider below.
        btn_row = QHBoxLayout()
        btn_row.addWidget(field_label(tr("Embedded")))
        btn_row.addWidget(self.metadata_distortion_btn, 1)
        btn_row.addWidget(self.metadata_ca_btn, 1)
        self.layout.addLayout(btn_row)

        self.lens_hint = hint_label("")
        self.lens_hint.setWordWrap(True)
        self.lens_hint.setVisible(False)
        self.layout.addWidget(self.lens_hint)
        self.layout.addWidget(self.distortion_slider)
        self.custom_ca_btn = self._labeled_toggle(
            "fa5s.crosshairs",
            tr("Measured Lens CA"),
            conf.lens_ca_custom,
            tr(
                "Apply measured radial channel geometry. Replaces embedded CA, not color saturation. Reuse only with matching lens settings."
            ),
        )
        self.calibrate_btn = self._labeled_action(
            "fa5s.ruler-combined",
            tr("Calibrate Lens CA…"),
            tr("Measure a neutral reference target and validate the optical channel model."),
        )
        self.profile_combo = StepCombo()
        self.profile_combo.setToolTip(tr("Saved measured lens profiles; coefficients are also stored with each edit."))
        self.layout.addWidget(self.custom_ca_btn)
        self.layout.addWidget(self.calibrate_btn)
        self.layout.addWidget(self.profile_combo)
        self.custom_hint = hint_label("")
        self.layout.addWidget(self.custom_hint)

    def _connect_signals(self) -> None:
        self.metadata_distortion_btn.toggled.connect(lambda enabled: self._set_metadata_lens("lens_distortion_from_metadata", enabled))
        self.metadata_ca_btn.toggled.connect(lambda enabled: self._set_metadata_lens("lens_ca_from_metadata", enabled))
        self.distortion_slider.valueChanged.connect(lambda _v: self.controller.show_rotation_guide())
        self.distortion_slider.valueChanged.connect(
            lambda v: self.controller.set_roll_default("lens", persist=False, readback_metrics=False, distortion_k1=v)
        )
        self.distortion_slider.valueCommitted.connect(lambda v: self.controller.set_roll_default("lens", distortion_k1=v))

        self.custom_ca_btn.toggled.connect(lambda enabled: self.controller.set_roll_default("lens", lens_ca_custom=enabled))
        self.calibrate_btn.clicked.connect(self.calibrate)
        self.profile_combo.currentIndexChanged.connect(self._profile_selected)

    def calibrate(self):
        from negpy.desktop.view.widgets.optical_diagnostics import LensCACalibrationDialog

        dialog = LensCACalibrationDialog(self, repo=self.controller.session.repo)
        dialog.profile_saved.connect(lambda values: self.controller.set_roll_default("lens", **values))
        dialog.exec()
        self.sync_ui()

    def _profile_selected(self, index):
        values = self.profile_combo.itemData(index)
        if values:
            self.controller.set_roll_default("lens", **dict(values, lens_ca_custom=True, lens_ca_from_metadata=False))

    def _set_metadata_lens(self, field: str, enabled: bool) -> None:
        button = self.metadata_distortion_btn if field == "lens_distortion_from_metadata" else self.metadata_ca_btn
        if enabled and not button.isEnabled():
            return
        values = {field: enabled}
        if field == "lens_ca_from_metadata" and enabled:
            values["lens_ca_custom"] = False
        self.controller.set_roll_default("lens", **values)

    def _sync_metadata_lens(self) -> None:
        config = self.state.config
        lens = read_lens_metadata(self.state.current_file_path)
        if self.state.preview_lens_path == self.state.current_file_path and self.state.preview_lens is not None:
            lens = self.state.preview_lens
        requested = replace(
            config, geometry=replace(config.geometry, lens_ca_custom=False, lens_distortion_from_metadata=True, lens_ca_from_metadata=True)
        )
        if not metadata_lens_corrections(requested):
            lens = LensMetadata(reason=tr("Embedded lens correction is unavailable for composites."))
        if self.state.has_ir:
            lens = LensMetadata(reason=tr("Embedded lens correction is unavailable for RGB+IR sources."))
        for button, enabled, available in (
            (self.metadata_distortion_btn, config.geometry.lens_distortion_from_metadata, lens.distortion),
            (self.metadata_ca_btn, config.geometry.lens_ca_from_metadata, lens.ca),
        ):
            button.setChecked(enabled)
            button.setEnabled(available or enabled)
            button.edited_dot.set_active(enabled)
        text = lens.description if lens.available else tr("Unavailable: {reason}", reason=lens.reason)
        self.lens_hint.setText(text)
        self.lens_hint.setVisible(bool(text))
        self.distortion_slider.setEnabled(not config.geometry.lens_distortion_from_metadata)

    def sync_ui(self) -> None:
        self.block_signals(True)
        try:
            self.distortion_slider.setValue(self.state.config.geometry.distortion_k1)
            self._sync_metadata_lens()
            geometry = self.state.config.geometry
            allowed = not (
                stitch_active(self.state.config.stitch)
                or hdr_active(self.state.config.hdr)
                or is_rgb_triplet(self.state.config.rgbscan)
                or self.state.has_ir
            )
            self.custom_ca_btn.setChecked(geometry.lens_ca_custom)
            self.custom_ca_btn.setEnabled(
                allowed and bool(geometry.lens_ca_name or any(geometry.lens_ca_red) or any(geometry.lens_ca_blue))
            )
            self.calibrate_btn.setEnabled(allowed)
            self.profile_combo.setEnabled(allowed)
            self.profile_combo.clear()
            self.profile_combo.addItem(geometry.lens_ca_name or tr("Current Settings"), None)
            for profile_id, values in lens_ca.profiles():
                self.profile_combo.addItem(values["lens_ca_name"], values)
            message = (
                tr("Measured CA is available for single-frame RGB sources, not composites or RGB+IR. Saved profiles are retained.")
                if not allowed
                else tr(
                    "Reference calibration is specific to lens, aperture, focus distance and magnification. Aspect mismatches are skipped; inspect corner crops before reuse."
                )
            )
            self.custom_hint.setText(message)
        finally:
            self.block_signals(False)

    def block_signals(self, blocked: bool) -> None:
        for w in (self.distortion_slider, self.metadata_distortion_btn, self.metadata_ca_btn, self.custom_ca_btn, self.profile_combo):
            w.blockSignals(blocked)
