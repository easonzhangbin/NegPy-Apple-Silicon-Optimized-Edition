__version__ = "Unknown-dev"

from pathlib import Path

# Read version from VERSION file if it exists
_version_file = Path(__file__).parent / "VERSION"
if _version_file.exists():
    __version__ = _version_file.read_text().strip()

# Apple Silicon: OpenMP lock choice for the multi-core LibRaw, before anything decodes.
from negpy.kernel.system.apple_silicon import configure_openmp_runtime as _configure_openmp_runtime  # noqa: E402

_configure_openmp_runtime()

from negpy.kernel.system.work_budget import configure_decode_threads as _configure_decode_threads  # noqa: E402

_configure_decode_threads()
