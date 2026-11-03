#!/bin/bash
set -euo pipefail
TASK_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
TASK_DRIVER="$TASK_DIR/PocketTrackpadMicrophone.driver"
printf '\nPocketTrackpad Microphone setup\n\n'
printf 'Installs only PocketTrackpadMicrophone.driver. Other audio drivers are preserved.\n'
printf 'Mac audio will restart briefly. Finish calls or recordings before continuing.\n'
printf 'Your Mac login password is required; it is not saved.\n\n'
printf '계속하면 Mac 오디오가 잠시 중단됩니다. 통화·녹음을 마친 뒤 진행하세요.\n'
printf 'Continue / 계속 [y/N]: '
read -r TASK_ANSWER
[[ "$TASK_ANSWER" == 'y' || "$TASK_ANSWER" == 'Y' ]] || exit 0
/usr/bin/codesign --verify --deep --strict "$TASK_DRIVER"
TASK_TEAM=$(/usr/bin/codesign -dv --verbose=4 "$TASK_DRIVER" 2>&1 | /usr/bin/sed -n 's/^TeamIdentifier=//p')
[[ "$TASK_TEAM" == '46HPN99G3G' ]] || { printf 'Unexpected signing identity. Nothing installed.\n'; exit 1; }
sudo -p 'Mac 로그인 암호 / Mac login password: ' -v
sudo /usr/bin/ditto "$TASK_DRIVER" /Library/Audio/Plug-Ins/HAL/PocketTrackpadMicrophone.driver
sudo /usr/sbin/chown -R root:wheel /Library/Audio/Plug-Ins/HAL/PocketTrackpadMicrophone.driver
sudo /usr/bin/killall coreaudiod || true
printf '\nInstalled. Reopen GPT if its microphone list has not refreshed.\n'
printf '설치됐습니다. GPT에 새 마이크가 보이지 않으면 GPT를 다시 열어주세요.\n'
