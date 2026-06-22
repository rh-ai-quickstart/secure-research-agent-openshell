"""Shared test fixtures."""

import importlib.util
import sys
from pathlib import Path
from unittest.mock import patch


def load_tcp_proxy():
    """Load tcp-proxy.py as a module with clean sys.argv."""
    proxy_path = Path(__file__).resolve().parent.parent / "scripts" / "tcp-proxy.py"
    with patch.object(sys, "argv", ["tcp-proxy.py"]):
        spec = importlib.util.spec_from_file_location("tcp_proxy", str(proxy_path))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
    return mod
