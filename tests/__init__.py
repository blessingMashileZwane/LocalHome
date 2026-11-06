"""Shared test bootstrap.

Adds the module directories to `sys.path` so tests can import the local
protocol clients without installing this repository as a package.
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
for name in ("web", "scripts"):
    path = str(ROOT / name)
    if path not in sys.path:
        sys.path.insert(0, path)
