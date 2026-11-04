#!/usr/bin/env python3
"""Run a Slither printer through the SafeCast scope-fix shim, redirecting any
file a printer writes (.dot graphs) into this directory instead of next to the
target under src/. Usage (from valari-contracts):
  python audit/2026-10-05-v3/trailofbits/printers/run_printer.py src/ValariRouterV3.sol <slither args>
"""
import os
import runpy
import sys

from slither.slither import Slither

OUT_PREFIX = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ValariRouterV3")


def run_printers(self):
    return [p.output(OUT_PREFIX).data for p in self._printers]


Slither.run_printers = run_printers
shim = os.path.join("audit", "2026-10-05", "slither", "run_with_scope_fix.py")
sys.argv[0] = shim
runpy.run_path(shim, run_name="__main__")
