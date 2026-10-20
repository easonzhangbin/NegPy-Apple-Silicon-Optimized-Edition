# Apple Silicon RAW build inputs

`rawpy-macos-arm64/` is the supplied optimization branch's CPython 3.13 runtime. Its LibRaw 0.22.1 is built from the LibRaw sources in `rawpy-0.27.0.tar.gz`, with OpenMP enabled and the shared LLVM 19.1.7 OpenMP runtime. It is not a wheel for other Python versions or platforms.

The matching upstream source archives are included here, together with the rawpy/LibRaw and LLVM licenses. LibRaw uses LGPL-2.1 / CDDL, rawpy uses MIT, and LLVM OpenMP uses Apache-2.0 with the LLVM exception. NegPy itself uses GPL-3.0; see the project LICENSE.

The vendor archives are unmodified. The input branch's `apple-silicon-build/mac/fix-omp.command` records the shared-runtime CMake configuration and library relocation commands. Do not execute that historical script against an installed application. The current `scripts/build_apple_silicon.py` uses an isolated staging directory, rejects static OpenMP and never installs the output.

Upstream source locations:

- https://pypi.org/project/rawpy/0.27.0/#files
- https://github.com/llvm/llvm-project/releases/tag/llvmorg-19.1.7
- https://github.com/LibRaw/LibRaw

The CMake build uses the codec interfaces from the stock rawpy runtime. The runtime's codec dynamic libraries are retained unchanged. See the included rawpy licensing material for its bundled components.

