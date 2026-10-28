#!/usr/bin/env bash
# lint.sh — Verilator -Wall lint of the whole SoC, with the waivers (and their
# reasons) in scripts/lint_waivers.vlt. Exits non-zero on any other warning.
set -euo pipefail
cd "$(dirname "$0")/.."
verilator --lint-only -Wall -Irtl/pkg -Irtl/core --top-module brv32p_soc \
  scripts/lint_waivers.vlt \
  rtl/core/*.v rtl/cache/*.v rtl/bus/*.v rtl/periph/*.v rtl/brv32p_soc.v
echo "lint clean"
