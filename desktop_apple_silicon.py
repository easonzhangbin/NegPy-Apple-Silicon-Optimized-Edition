import os
from pathlib import Path
import runpy

if __name__ == "__main__":
    os.environ.setdefault("NEGPY_USER_DIR", str(Path.home() / "Library/Application Support/NegPy-AppleSilicon-067"))
    os.environ["NEGPY_CUSTOM_EDITION"] = "1"
    import desktop

    runpy.run_module(desktop.__name__, run_name="__main__")
