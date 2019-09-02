#!/bin/bash
# shellcheck disable=SC2016

# shellcheck disable=SC1091
. /dev/stdin <<<"$(
    set -euo pipefail

    SCRIPT_PATH="${BASH_SOURCE[0]}"
    if command -v realpath >/dev/null 2>&1; then SCRIPT_PATH="$(realpath "$SCRIPT_PATH")"; fi
    SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd -P)"

    # shellcheck source=bash/common
    . "$SCRIPT_DIR/bash/common"

    variable_exists "ADD_TO_PATH" || ADD_TO_PATH=()

    ADD_TO_PATH+=("$ROOT_DIR" "$ROOT_DIR/bash" "$ROOT_DIR/synergy")

    [ "$IS_MACOS" -eq "1" ] && ADD_TO_PATH+=("$ROOT_DIR/macos")
    [ "$IS_LINUX" -eq "1" ] && ADD_TO_PATH+=("$ROOT_DIR/linux")
    [ "$IS_UBUNTU" -eq "1" ] && ADD_TO_PATH+=("$ROOT_DIR/ubuntu")

    ADD_TO_PATH+=("$HOME/.local/bin")
    ADD_TO_PATH+=("$HOME/.composer/vendor/bin")
    ADD_TO_PATH+=("$HOME/.config/composer/vendor/bin")

    for KEY in "${!ADD_TO_PATH[@]}"; do

        if [[ ":$PATH:" == *":${ADD_TO_PATH[$KEY]}:"* ]] || [ ! -d "${ADD_TO_PATH[$KEY]}" ]; then

            unset "ADD_TO_PATH[$KEY]"

        fi

    done

    # shellcheck disable=SC2016
    if [ "${#ADD_TO_PATH[@]}" -gt "0" ]; then

        echo 'export PATH="$PATH:'"$(array_join_by ":" "${ADD_TO_PATH[@]}")"'"'

    fi

    echo "export LINAC_ROOT_DIR=\"$ROOT_DIR\""

    if is_macos; then

        if [ "${TERM_PROGRAM:-}" = "iTerm.app" ]; then

            if [ -f "$HOME/.iterm2_shell_integration.bash" ]; then

                echo '. "$HOME/.iterm2_shell_integration.bash"'

            elif ! is_root; then

                echo 'curl -L "https://iterm2.com/shell_integration/install_shell_integration.sh" | bash && . "$HOME/.iterm2_shell_integration.bash"'

            fi

        fi

        echo 'alias audio-reset="sudo launchctl unload /System/Library/LaunchDaemons/com.apple.audio.coreaudiod.plist && sudo launchctl load /System/Library/LaunchDaemons/com.apple.audio.coreaudiod.plist"'
        echo 'alias duh="du -h -d 1 | sort -h"'
        echo 'alias prefs-flush="killall -u \"\$USER\" cfprefsd"'
        echo 'alias top="top -o cpu"'

        if [ -e "$HOME/Library/LaunchAgents/com.linacreative.Synergy.plist" ]; then

            echo "alias synergy-start='launchctl load \"$HOME/Library/LaunchAgents/com.linacreative.Synergy.plist\"'"
            echo "alias synergy-stop='launchctl unload \"$HOME/Library/LaunchAgents/com.linacreative.Synergy.plist\"'"
            echo "alias synergy-restart='synergy-stop; synergy-start'"

        fi

        PHP_PATHS=(/usr/local/opt/php*)

        [ "${#PHP_PATHS[@]}" -lt "2" ] ||
            echo -e "WARNING: multiple PHP installations detected and added to PATH:\n$(printf -- '- %s\n' "${PHP_PATHS[@]}")" >&2

        for PHP_PATH in "${!PHP_PATHS[@]}"; do

            echo "export PATH=\"${PHP_PATHS[$PHP_PATH]}/sbin:${PHP_PATHS[$PHP_PATH]}/bin:\$PATH\""
            echo "export LDFLAGS=\"\${LDFLAGS:+\$LDFLAGS }-L${PHP_PATHS[$PHP_PATH]}/lib\""
            echo "export CPPFLAGS=\"\${CPPFLAGS:+\$CPPFLAGS }-I${PHP_PATHS[$PHP_PATH]}/include\""

        done

        if [ -z "${JAVA_HOME:-}" ] && [ -x "/usr/libexec/java_home" ]; then

            JAVA_HOME="$(/usr/libexec/java_home)" &&
                echo "export JAVA_HOME=\"$JAVA_HOME\""

        fi

    else

        echo 'alias duh="du -h --max-depth 1 | sort -h"'

        command_exists gtk-launch && echo 'alias gtk-debug="GTK_DEBUG=interactive "'
        command_exists xdg-open && echo 'alias open=xdg-open'

        if [ -e "/lib/systemd/system/synergy.service" ]; then

            echo 'alias synergy-start="sudo systemctl start synergy.service"'
            echo 'alias synergy-stop="sudo systemctl stop synergy.service"'
            echo 'alias synergy-restart="sudo systemctl restart synergy.service"'

        fi

    fi

    command_exists youtube-dl && echo 'alias youtube-dl-audio="youtube-dl -x --audio-format mp3 --audio-quality 0"'

)"

function _latest() {

    local TYPE="${1:-}" COMMAND

    [ "${#TYPE}" -eq "1" ] && shift || TYPE="f"

    is_macos && COMMAND=(find . -x \() || COMMAND=(find . -xdev \()

    [ "$#" -eq "0" ] || COMMAND+=(\( "$@" -prune \) -o)

    COMMAND+=(\( -type "$TYPE" -print0 \) \))

    if is_macos; then

        "${COMMAND[@]}" | xargs -0 stat -f '%m :%Sm %N' | sort -nr | cut -d: -f2- | less

    else

        "${COMMAND[@]}" | xargs -0 stat --format '%Y :%y %n' | sort -nr | cut -d: -f2- | less

    fi

}

# files after excluding .git directories
function latest() {
    _latest f -type d -name .git
}

# directories after excluding .git directories
function latest-dir() {
    _latest d -type d -name .git
}

# all files
function latest-all() {
    _latest f
}

if command -v owncloudcmd >/dev/null 2>&1; then

    function _owncloud_sync() {

        local SOURCE_DIR="$1" SERVER_URL="$2"

        [ -d "$SOURCE_DIR" ] || {
            echo "Source directory not found: $SOURCE_DIR" >&2
            return 1
        }

        [ -n "$SERVER_URL" ] || {
            echo "Server URL required" >&2
            return 1
        }

        shift 2

        if [ -f "$HOME/.config/ownCloud/sync-exclude.lst" ]; then

            owncloudcmd "$@" --exclude "$HOME/.config/ownCloud/sync-exclude.lst" "$SOURCE_DIR" "$SERVER_URL"

        else

            owncloudcmd "$@" "$SOURCE_DIR" "$SERVER_URL"

        fi

    }

fi

function _owncloud_check() {

    local SOURCE_DIR="$1" CONFLICTS=0

    [ -d "$SOURCE_DIR" ] || {
        echo "Source directory not found: $SOURCE_DIR" >&2
        return 1
    }

    echo -e "Looking for conflicts in: $SOURCE_DIR\n" >&2

    while IFS= read -d $'\0' -r LINE; do

        echo "$LINE"
        ((++CONFLICTS))

    done < <(find "$SOURCE_DIR" -iname "*conflicted copy*" -print0)

    [ "$CONFLICTS" -gt "0" ] || echo "No conflicts found" >&2
    echo >&2

}
