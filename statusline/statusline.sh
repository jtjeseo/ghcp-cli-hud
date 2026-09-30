#!/usr/bin/env bash
script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)" || exit 1
export COPILOT_HOME="${COPILOT_HOME:-$(dirname -- "$script_dir")}"
exec pwsh -NoLogo -NoProfile -NonInteractive -File "$script_dir/statusline.ps1"
