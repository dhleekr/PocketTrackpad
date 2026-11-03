#!/bin/bash
set -euo pipefail
TASK_DRIVER=${1:?Path to the signed driver is required}
TASK_OUTPUT=${2:?Output package path is required}
TASK_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/pocket-mic-pkg.XXXXXX")
trap 'rm -rf "$TASK_ROOT"' EXIT
mkdir -p "$TASK_ROOT/root/Library/Audio/Plug-Ins/HAL"
/usr/bin/ditto --norsrc --noextattr "$TASK_DRIVER" "$TASK_ROOT/root/Library/Audio/Plug-Ins/HAL/PocketTrackpadMicrophone.driver"
find "$TASK_ROOT/root" -name '._*' -delete
set --
if [[ -n "${POCKET_MAC_INSTALLER_IDENTITY:-}" ]]; then
  set -- --sign "$POCKET_MAC_INSTALLER_IDENTITY" --timestamp
else
  printf 'LOCAL REVIEW ONLY: package needs Developer ID Installer signing before distribution.\n'
fi
/usr/bin/pkgbuild --root "$TASK_ROOT/root" --install-location / --ownership recommended --identifier local.doohyun.pockettrackpad.microphone --version 1.4.4 --scripts "$(dirname "$0")/installer-scripts" "$@" "$TASK_OUTPUT"
