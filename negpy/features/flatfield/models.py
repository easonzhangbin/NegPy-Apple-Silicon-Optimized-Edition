from dataclasses import dataclass
import math


@dataclass(frozen=True)
class FlatFieldConfig:
    """Flat-field (illumination falloff) correction."""

    # Per-image toggle. Named 'apply', not 'enabled', to stay unique in the flat config dict
    # (WorkspaceConfig.to_dict), where RgbScanConfig.enabled also lives.
    apply: bool = False
    # Opaque id of the active reference profile, a baked gain map stored in
    # APP_CONFIG.flatfield_dir (services/assets/flatfield.py). Stable across renames and
    # machines: the render path resolves the gain by this id, so the original reference image
    # can be moved or deleted without breaking the correction.
    profile_id: str = ""
    flatfield_strength: float = 1.0
    flatfield_luminance: float = 1.0
    flatfield_color: float = 1.0

    def __post_init__(self) -> None:
        for name in ("flatfield_strength", "flatfield_luminance", "flatfield_color"):
            strength = float(getattr(self, name))
            strength = max(0.0, min(2.0, strength)) if math.isfinite(strength) else 1.0
            object.__setattr__(self, name, strength)
