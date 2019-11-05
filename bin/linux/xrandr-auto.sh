#!/bin/bash
# shellcheck disable=SC1090

set -euo pipefail
SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}" 2>/dev/null)" || SCRIPT_PATH="$(python -c 'import os,sys;print os.path.realpath(sys.argv[1])' "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

. "$SCRIPT_DIR/../../bash/common"

# shellcheck disable=SC2034
MUST_DIE_HAPPY=Y

assert_command_exists xrandr
assert_command_exists bc

if has_argument "-h" || has_argument "--help"; then

    die "Usage: $(basename "$0") [--autostart] [--suggest] [--get-qt-exports] [--set-dpi-only] [--skip-lightdm]"

fi

! is_autostart || sleep 2

# if the primary output's actual DPI is above this, enable "Retina" mode
HIDPI_THRESHOLD=144

# get current state with trailing whitespace removed
XRANDR_OUTPUT="$(xrandr --verbose | sed -E 's/[[:space:]]+$//')" || die "Unable to retrieve current RandR state"

# convert to single line for upcoming greps
XRANDR_OUTPUT="\\n${XRANDR_OUTPUT//$'\n'/\\n}\\n"

# extract connected output names
OUTPUTS=($(echo "$XRANDR_OUTPUT" | gnu_grep -Po '(?<=\\n)([^[:space:]]+)(?= connected)')) || die "No connected outputs"

# and all output names (i.e. connected and disconnected)
ALL_OUTPUTS=($(echo "$XRANDR_OUTPUT" | gnu_grep -Po '(?<=\\n)([^[:space:]]+)(?= (connected|disconnected))'))

# each EDID is stored at the same index as its output name in OUTPUTS
EDIDS=()

# physical dimensions are stored here at the same index (e.g. "435 239 103965 19.5", or "<width> <height> <area> <diagonal inches>")
SIZES=()

# native resolutions are stored here at the same index (e.g. "1920 1080")
RESOLUTIONS=()

# verbose xrandr output is stored here at the same index
OUTPUTS_INFO=()

# by default, the largest output (by physical area) will be set as primary
PRIMARY_INDEX=0

# the largest output is also used to determine DPI and scaling factor
ACTUAL_DPI=96
SCALING_FACTOR=1
DPI=96
DPI_MULTIPLIER=1

# general xrandr options should be added to this array
# output-specific options belong in OPTIONS_xxx, where xxx is the output name's index in OUTPUTS
OPTIONS=()

LARGEST_AREA=0

for i in "${!OUTPUTS[@]}"; do

    # extract everything related to this output
    OUTPUT_INFO="$(echo "$XRANDR_OUTPUT" | gnu_grep -Po '(?<=\\n)'"${OUTPUTS[$i]}"' connected.*?(?=\\n[^[:space:]])')"

    OUTPUT_INFO_LINES="${OUTPUT_INFO//\\n/$'\n'}"

    # save it for later
    OUTPUTS_INFO+=("$OUTPUT_INFO_LINES")

    # extract EDID
    EDID="$(echo "$OUTPUT_INFO" | gnu_grep -Po '(?<=EDID:\\n)(\t{2}[0-9a-fA-F]+\\n)+')"
    EDID="${EDID//[^0-9a-fA-F]/}"
    EDIDS+=("$EDID")

    # extract dimensions
    DIMENSIONS=($(echo "$OUTPUT_INFO_LINES" | head -n1 | gnu_grep -Po '\b[0-9]+(?=mm\b)')) || DIMENSIONS=()

    if [ "${#DIMENSIONS[@]}" -eq 2 ]; then

        ((AREA = DIMENSIONS[0] * DIMENSIONS[1]))
        DIMENSIONS+=("$AREA")
        DIMENSIONS+=("$(echo "scale = 10; size = sqrt(${DIMENSIONS[0]} ^ 2 + ${DIMENSIONS[1]} ^ 2) / 10 / 2.54; scale = 1; size / 1" | bc)")
        SIZES+=("${DIMENSIONS[*]}")

        if [ "$AREA" -gt "$LARGEST_AREA" ]; then

            LARGEST_AREA="$AREA"
            PRIMARY_INDEX="$i"

        fi

    else

        SIZES+=("0 0 0 0")

    fi

    # extract preferred (native) resolution
    PIXELS=($(echo "$OUTPUT_INFO_LINES" | grep '[[:space:]]+preferred$' | gnu_grep -Po '(?<=[[:space:]]|x)[0-9]+(?=[[:space:]]|x)')) || PIXELS=()

    if [ "${#PIXELS[@]}" -eq 2 ]; then

        RESOLUTIONS+=("${PIXELS[*]}")

        if [ "$PRIMARY_INDEX" -eq "$i" ] && [ "${#DIMENSIONS[@]}" -eq "4" ] && [ "${DIMENSIONS[0]}" -gt "0" ]; then

            ACTUAL_DPI="$(echo "scale = 10; dpi = ${PIXELS[0]} / ( ${DIMENSIONS[0]} / 10 / 2.54 ); scale = 0; dpi / 1" | bc)"
            PRIMARY_SIZE="${DIMENSIONS[3]}"

        fi

    else

        RESOLUTIONS+=("0 0")

    fi

    # create an output-specific options array
    eval "OPTIONS_$i=()"

done

echo "Actual DPI of largest screen${PRIMARY_SIZE:+ ($PRIMARY_SIZE\")}: $ACTUAL_DPI" >&2

if [ "$ACTUAL_DPI" -ge "$HIDPI_THRESHOLD" ]; then

    SCALING_FACTOR=2
    DPI=192

fi

# Usage: get_edid_index "00ffffffffffff00410c03c1...5311000a20202020202000af"
# Outputs nothing and exits non-zero if the value isn't found.
function get_edid_index() {

    array_search "$1" EDIDS

}

if [ ! -e "$CONFIG_DIR/xrandr" ] || has_argument "--suggest"; then

    {

        echo '#!/bin/bash'
        echo
        echo '# This file has been automatically generated. Rename it to "xrandr" before making changes.'
        echo

        for i in "${!OUTPUTS[@]}"; do

            DIMENSIONS=(${SIZES[$i]})
            RESOLUTION=(${RESOLUTIONS[$i]})

            {
                echo "# ${DIMENSIONS[3]}\", ${RESOLUTION[0]}x${RESOLUTION[1]}"
                echo "EDID_DISPLAY_${i}=\"${EDIDS[$i]}\""
                echo "EDID_DISPLAY_${i}_OPTIONS=()"
                echo
            }

        done

        cat <<EOF
for i in \$(seq 0 $i); do
    eval "EDID_DISPLAY_\${i}_ACTIVE=0"
    if eval "EDID_DISPLAY_\${i}_INDEX=\\"\\\$(get_edid_index \\"\\\$EDID_DISPLAY_\${i}\\")\\""; then
        eval "EDID_DISPLAY_\${i}_ACTIVE=1"
    fi
done

# Here's an example to use as a starting point.
# In addition to output-specific options, you can also modify: OPTIONS, PRIMARY_INDEX, SCALING_FACTOR, DPI, DPI_MULTIPLIER
#
# # 4K connected?
# if [ "\$EDID_DISPLAY_0_ACTIVE" -eq "1" ]; then
#
#     # "looks like 2560x1440"
#     EDID_DISPLAY_0_OPTIONS+=(--mode 3840x2160 --scale-from 5120x2880)
#
#     # 1080p also connected?
#     if [ "\$EDID_DISPLAY_1_ACTIVE" -eq "1" ]; then
#
#         # "looks like 1536x864" - i.e. use all of i915's (software-limited) 8192x8192 framebuffer
#         EDID_DISPLAY_1_OPTIONS+=(--mode 1920x1080 --scale-from 3072x1728 --pos 0x576)
#         EDID_DISPLAY_0_OPTIONS+=(--pos 3072x0)
#
#     fi
#
# fi

for i in \$(seq 0 $i); do
    eval "EDID_DISPLAY_ACTIVE=\\"\\\$EDID_DISPLAY_\${i}_ACTIVE\\""
    if [ "\$EDID_DISPLAY_ACTIVE" -eq "1" ]; then
        eval "EDID_DISPLAY_INDEX=\\"\\\$EDID_DISPLAY_\${i}_INDEX\\""
        eval "OPTIONS_\${EDID_DISPLAY_INDEX}+=(\\"\\\${EDID_DISPLAY_\${i}_OPTIONS[@]}\\")"
    fi
done
EOF

    } >"$CONFIG_DIR/xrandr-suggested"

    ! has_argument "--suggest" || exit 0

fi

# OPTIONS, OPTIONS_xxx, PRIMARY_INDEX, SCALING_FACTOR, DPI and DPI_MULTIPLIER may be changed here
if [ -e "$CONFIG_DIR/xrandr" ]; then

    . "$CONFIG_DIR/xrandr" || die

fi

DPI="$(echo "scale = 10; dpi = $DPI * $DPI_MULTIPLIER; scale = 0; dpi / 1" | bc)"

echo "Scaling factor: $SCALING_FACTOR" >&2
echo "Effective DPI: $DPI" >&2

if has_argument "--get-qt-exports"; then

    ((QT_FONT_DPI = DPI / SCALING_FACTOR))

    echo "export QT_AUTO_SCREEN_SCALE_FACTOR=\"0\""
    echo "export QT_SCALE_FACTOR=\"$SCALING_FACTOR\""
    echo "export QT_FONT_DPI=\"$QT_FONT_DPI\""

fi

if has_argument "--set-dpi-only"; then

    echo_run xrandr --dpi "$DPI" >&2

fi

if has_argument "--get-qt-exports" || has_argument "--set-dpi-only"; then

    exit

fi

in_array "--dpi" OPTIONS || OPTIONS+=(--dpi "$DPI")

for i in "${!OUTPUTS[@]}"; do

    OPTIONS+=(--output "${OUTPUTS[$i]}")

    eval "OPTIONS_COUNT=(\"\${#OPTIONS_${i}[@]}\")"

    if [ "$OPTIONS_COUNT" -gt "0" ]; then

        eval "OUTPUT_OPTIONS=(\"\${OPTIONS_${i}[@]}\")"
        OPTIONS+=("${OUTPUT_OPTIONS[@]}")

    else

        OUTPUT_OPTIONS=()

    fi

    if ! in_array "--off" OUTPUT_OPTIONS; then

        in_array "--mode" OUTPUT_OPTIONS || OPTIONS+=(--preferred)

        in_array "--primary" OPTIONS || [ "$PRIMARY_INDEX" -ne "$i" ] || OPTIONS+=(--primary)

        in_array "Broadcast RGB" OUTPUT_OPTIONS || OPTIONS+=(--set "Broadcast RGB" "Full")

    fi

done

RESET_OPTIONS=()

for i in "${ALL_OUTPUTS[@]}"; do

    RESET_OPTIONS+=(--output "$i")

    if ! in_array "$i" OUTPUTS; then

        RESET_OPTIONS+=(--off)

    else

        RESET_OPTIONS+=(--auto --transform none --panning 0x0)

    fi

done

# check that our configuration is valid
xrandr --dryrun "${RESET_OPTIONS[@]}" >/dev/null || die
xrandr --dryrun "${OPTIONS[@]}" >/dev/null || die

# apply configuration
echo_run xrandr "${RESET_OPTIONS[@]}" || true
echo_run xrandr "${OPTIONS[@]}" || die

! has_argument "--lightdm" || die

if ! has_argument "--lightdm" && ! has_argument "--skip-lightdm" && [ -d "/etc/lightdm/lightdm.conf.d" ]; then

    sudo -n tee "/etc/lightdm/lightdm.conf.d/90-xrandr-auto.conf" >/dev/null 2>&1 <<EOF || echo -e "WARNING: unable to configure LightDM\n" >&2
[Seat:*]
display-setup-script='$SCRIPT_PATH' --lightdm
EOF

fi

# ok, xrandr is sorted -- look after everything else
case "${XDG_CURRENT_DESKTOP:-}" in

XFCE)

    # prevent Xfce from interfering with our display settings
    echo_run xfconf-query -c displays -p / -rR
    echo_run xfconf-query -c displays -p /Notify -n -t bool -s false

    "$SCRIPT_DIR/xfce-set-dpi.sh" "$DPI" "$@"
    ;;

*GNOME | Pantheon)

    if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then

        ((XFT_DPI = 1024 * DPI))

        if OVERRIDES="$(gsettings get org.gnome.settings-daemon.plugins.xsettings overrides)"; then

            OVERRIDES="$("$SCRIPT_DIR/glib-update-variant-dictionary.py" "$OVERRIDES" "Gdk/WindowScalingFactor" "$SCALING_FACTOR")"
            OVERRIDES="$("$SCRIPT_DIR/glib-update-variant-dictionary.py" "$OVERRIDES" "Xft/DPI" "$XFT_DPI")"

            echo_run gsettings set org.gnome.settings-daemon.plugins.xsettings overrides "$OVERRIDES" || true

        fi

        echo_run gsettings set org.gnome.desktop.interface scaling-factor "$SCALING_FACTOR" || true
        echo_run gsettings set org.gnome.desktop.interface text-scaling-factor "$DPI_MULTIPLIER" || true

    fi

    ;;

esac

if ! is_root; then

    if ! is_autostart; then

        ! command_exists displaycal-apply-profiles || displaycal-apply-profiles
        "$SCRIPT_DIR/x-release-modifiers.sh"

    fi

    "$SCRIPT_DIR/xkb-load.sh" "$@" --no-sleep
    "$SCRIPT_DIR/xinput-load.sh" "$@"

    if killall quicktile 2>/dev/null; then

        quicktile --daemonize >/dev/null 2>&1 &

    fi

    if killall plank 2>/dev/null; then

        plank >/dev/null 2>&1 &

    fi

fi