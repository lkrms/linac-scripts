#!/bin/bash
# shellcheck disable=SC2119

set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
if command -v realpath >/dev/null 2>&1; then SCRIPT_PATH="$(realpath "$SCRIPT_PATH")"; fi
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd -P)"

# shellcheck source=common
. "$SCRIPT_DIR/common"

# shellcheck source=common-dev
. "$SCRIPT_DIR/common-dev"

assert_not_root

dev_install_packages

dev_apply_system_config
