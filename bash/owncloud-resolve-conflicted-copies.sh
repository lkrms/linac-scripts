#!/bin/bash

set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
if command -v realpath >/dev/null 2>&1; then SCRIPT_PATH="$(realpath "$SCRIPT_PATH")"; fi
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd -P)"

# shellcheck source=../bash/common
. "$SCRIPT_DIR/../bash/common"

RESOLVED=0

while IFS= read -rd $'\0' FILE; do

	ORIG_FILE="$(echo "$FILE" | sed -E 's/ \(conflicted copy [-0-9 ]+\)//')"

	[ "$ORIG_FILE" != "$FILE" ] || continue

	echo "Conflicted copy: $FILE" >&2
	echo "Original file: $ORIG_FILE" >&2

	[ -f "$ORIG_FILE" ] || {
		echo -e "Original file doesn't exist; skipping\n" >&2
		continue
	}

	if [ "$FILE" -nt "$ORIG_FILE" ]; then

		echo -e "Conflicted copy is newer; keeping it\n" >&2
		KEEP="$FILE"
		TRASH="$ORIG_FILE"

	else

		echo -e "Original file is newer; keeping it\n" >&2
		KEEP="$ORIG_FILE"
		TRASH="$FILE"

	fi

	if command_exists trash-put; then

		trash-put "$TRASH"

	else

		TRASH_TO="$(mktemp "/tmp/$(basename "$TRASH").XXXXXXXX")"
		echo -e "Preserving $TRASH temporarily at $TRASH_TO\n" >&2
		mv -f "$TRASH" "$TRASH_TO"

	fi

	[ "$KEEP" = "$ORIG_FILE" ] || mv "$FILE" "$ORIG_FILE"

	((++RESOLVED))

done < <(find . -iname '*conflicted copy*' -print0 | sort -z)

echo "$RESOLVED conflicted $(single_or_plural "$RESOLVED" copy copies) resolved"
