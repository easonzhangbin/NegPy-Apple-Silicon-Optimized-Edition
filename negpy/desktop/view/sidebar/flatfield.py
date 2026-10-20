from negpy.kernel.system.i18n import mark, tr
import os
from typing import cast

from PyQt6.QtCore import Qt
from PyQt6.QtWidgets import (
    QApplication,
    QFileDialog,
    QHBoxLayout,
    QInputDialog,
    QVBoxLayout,
)

from negpy.desktop.view.confirm import confirm_delete_named
from negpy.desktop.view.sidebar.base import BaseSidebar
from negpy.desktop.view.styles.templates import ICON_BUTTON_WIDTH, field_label, hint_label
from negpy.desktop.view.widgets.file_dialogs import last_open_folder, pick_start_dir
from negpy.desktop.view.widgets.step_combo import StepCombo
from negpy.desktop.view.widgets.sliders import CompactSlider
from negpy.infrastructure.loaders.helpers import get_supported_raw_wildcards

STRENGTH_TOOLTIP = mark(
    "Flat-field correction strength: 0% bypasses correction; 100% uses the reference as measured; "
    "200% doubles the exposure compensation. Double-click to reset to 100%. "
    "Higher values can amplify noise and color shading."
)
_NONE_LABEL = tr("— None —")
_FILE_FILTER = f"Reference images ({get_supported_raw_wildcards()});;All files (*)"


class FlatFieldSidebar(BaseSidebar):
    """
    Flat-field / falloff correction. Manages named reference profiles (the bare
    light-source scan); the profile and the toggle are roll-wide, since one roll is
    scanned under one light.
    """

    def _init_ui(self) -> None:
        layout = cast(QVBoxLayout, self.layout)
        row = QHBoxLayout()
        row.addWidget(field_label(tr("Profile")))
        self.profile_combo = StepCombo()
        self.profile_combo.setToolTip(tr("Saved flat-field reference profiles (scan of the bare light source)"))
        row.addWidget(self.profile_combo, 1)

        self.enable_btn = self._small_toggle(
            "fa5s.lightbulb",
            "",
            False,
            tr("Apply Flat Field — apply the selected flat-field reference to this roll"),
        )
        self.enable_btn.setFixedWidth(ICON_BUTTON_WIDTH)
        row.addWidget(self.enable_btn)

        self.check_btn = self._small_toggle(
            "fa5s.eye",
            "",
            False,
            tr(
                "Check Flat Field: show how well the selected profile corrects its own reference, "
                "from any frame. A good profile shows an even gray; a band or patch shows where it is off."
            ),
        )
        self.check_btn.setFixedWidth(ICON_BUTTON_WIDTH)
        row.addWidget(self.check_btn)

        self.add_btn = self._icon_action("fa5s.plus", tr("Pick a reference image and save it as a named profile"))
        self.delete_btn = self._icon_action("fa5s.trash", tr("Remove the selected profile"))
        # add_btn and delete_btn go on the card's FLAT FIELD CORRECTION header (ControlsPanel).
        layout.addLayout(row)

        self.strength_slider = CompactSlider(tr("Flat Field Strength"), 0, 200, 100, step=1, precision=1, unit="%", has_neutral=True)
        self.strength_slider.setToolTip(tr(STRENGTH_TOOLTIP))
        layout.addWidget(self.strength_slider)

        self.component_sliders = {}
        for field, label in (("flatfield_luminance", tr("Flat Field Brightness")), ("flatfield_color", tr("Flat Field Color"))):
            slider = CompactSlider(label, 0, 200, 100, step=1, precision=1, unit="%", has_neutral=True)
            slider.setToolTip(
                tr(
                    "Multiplies total strength for this component. Brightness uses common log-gain; color uses channel-relative log-gain. 0% disables this component."
                )
            )
            self.component_sliders[field] = slider
            layout.addWidget(slider)
        self.luminance_slider = self.component_sliders["flatfield_luminance"]
        self.color_slider = self.component_sliders["flatfield_color"]
        self.analysis_btn = self._labeled_action(
            "fa5s.chart-area", tr("Analyze Flat Field…"), tr("Compare brightness and color maps and inspect reference warnings.")
        )
        layout.addWidget(self.analysis_btn)
        self.hint = hint_label(tr("Add a scan of the bare light source to enable."))
        layout.addWidget(self.hint)
        self._refresh_profiles()

    def _connect_signals(self) -> None:
        self.enable_btn.toggled.connect(self.controller.set_flatfield_enabled)
        self.check_btn.toggled.connect(lambda checked: self.controller.toggle_flatfield_peek(force=checked))
        self.controller.flatfield_peek_changed.connect(self._on_peek_changed)
        self.profile_combo.currentIndexChanged.connect(self._on_profile_selected)
        self.add_btn.clicked.connect(self._on_add)
        self.delete_btn.clicked.connect(self._on_delete)
        self.strength_slider.valueChanged.connect(
            lambda value: self.controller.set_roll_default("flatfield", persist=False, flatfield_strength=value / 100.0)
        )
        self.strength_slider.valueCommitted.connect(
            lambda value: self.controller.set_roll_default("flatfield", flatfield_strength=value / 100.0)
        )
        for field, slider in self.component_sliders.items():
            slider.valueChanged.connect(
                lambda value, name=field: self.controller.set_roll_default("flatfield", persist=False, **{name: value / 100.0})
            )
            slider.valueCommitted.connect(lambda value, name=field: self.controller.set_roll_default("flatfield", **{name: value / 100.0}))
        self.analysis_btn.clicked.connect(self.show_analysis)
        self.sync_ui()

    def show_analysis(self):
        from negpy.services.assets.flatfield import FlatFieldProfiles
        from negpy.desktop.view.widgets.optical_diagnostics import FlatFieldAnalysisDialog

        stored = FlatFieldProfiles.load_check(self.state.config.flatfield.profile_id)
        if stored is not None:
            FlatFieldAnalysisDialog(stored, self.state.config.flatfield, self, repo=self.controller.session.repo).exec()

    def _refresh_profiles(self) -> None:
        # Preserve the caller's block state: unblocking here would let sync_ui's setCurrentIndex
        # re-fire _on_profile_selected and loop into update_config.
        from negpy.services.assets.flatfield import FlatFieldProfiles

        prev = self.profile_combo.signalsBlocked()
        self.profile_combo.blockSignals(True)
        self.profile_combo.clear()
        self.profile_combo.addItem(_NONE_LABEL, "")
        for profile_id, name in FlatFieldProfiles.list_profiles():
            self.profile_combo.addItem(name, profile_id)
        self.profile_combo.blockSignals(prev)

    def _on_profile_selected(self, _idx: int) -> None:
        profile_id = self.profile_combo.currentData() or ""
        if profile_id == self.state.config.flatfield.profile_id:
            return
        self.controller.set_active_flatfield_profile(profile_id)
        self.sync_ui()

    def _on_add(self) -> None:
        start = pick_start_dir(last_open_folder(self.controller.session.repo))
        path, _ = QFileDialog.getOpenFileName(self, tr("Select Flat Field Reference"), start, _FILE_FILTER)
        if not path:
            return
        default_name = os.path.splitext(os.path.basename(path))[0]
        name, ok = QInputDialog.getText(self, tr("Save Flat Field Profile"), tr("Profile name:"), text=default_name)
        if ok and name:
            # save_flatfield_profile decodes the reference RAW to bake the gain, a brief blocking beat
            # on the GUI thread, so show a wait cursor.
            QApplication.setOverrideCursor(Qt.CursorShape.WaitCursor)
            try:
                self.controller.save_flatfield_profile(name, path)
            finally:
                QApplication.restoreOverrideCursor()
            self._refresh_profiles()
            self.sync_ui()

    def _on_delete(self) -> None:
        profile_id = self.profile_combo.currentData()
        if profile_id and confirm_delete_named(
            self,
            tr("Flat Field Profile"),
            self.profile_combo.currentText(),
            informative=tr("Every frame using it loses its correction; the baked gain map cannot be recovered."),
        ):
            self.controller.delete_flatfield_profile(profile_id)
            self._refresh_profiles()
            self.sync_ui()

    def sync_ui(self) -> None:
        conf = self.state.config.flatfield

        self.block_signals(True)
        try:
            self._refresh_profiles()
            idx = self.profile_combo.findData(conf.profile_id)
            self.profile_combo.setCurrentIndex(idx if idx >= 0 else 0)

            self.enable_btn.setChecked(conf.apply)
            self.enable_btn.setEnabled(bool(conf.profile_id))
            self.strength_slider.setValue(conf.flatfield_strength * 100.0)
            self.strength_slider.setEnabled(conf.apply and bool(conf.profile_id))
            for field, slider in self.component_sliders.items():
                slider.setValue(getattr(conf, field) * 100)
                slider.setEnabled(conf.apply and bool(conf.profile_id))
            self.analysis_btn.setEnabled(bool(conf.profile_id))
            self.hint.setVisible(not conf.profile_id)
        finally:
            self.block_signals(False)

    def _on_peek_changed(self, active: bool) -> None:
        self.check_btn.blockSignals(True)
        self.check_btn.setChecked(active)
        self.check_btn.blockSignals(False)

    def block_signals(self, blocked: bool) -> None:
        for w in (
            self.enable_btn,
            self.check_btn,
            self.profile_combo,
            self.add_btn,
            self.delete_btn,
            self.strength_slider,
            *self.component_sliders.values(),
        ):
            w.blockSignals(blocked)
