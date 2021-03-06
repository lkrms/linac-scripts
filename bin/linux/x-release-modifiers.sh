#!/bin/bash
# shellcheck disable=SC1090

set -euo pipefail
SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}" 2>/dev/null)" || SCRIPT_PATH="$(python -c 'import os,sys;print os.path.realpath(sys.argv[1])' "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

. "$SCRIPT_DIR/../../bash/common"

assert_command_exists xmodmap
assert_command_exists xdotool

# give it a second for keys to be (physically) released
has_arg "--no-sleep" || sleep 1

for KEYCODE in $(xmodmap -pm | grep -Pio '(?<=\b0x)[0-9a-f]+\b'); do

    echo -e "xdotool keyup $((16#$KEYCODE))\n" >&2
    xdotool keyup $((16#$KEYCODE))

done
