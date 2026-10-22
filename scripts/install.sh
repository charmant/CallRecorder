#!/bin/bash
# Builds CallRecorder, installs it to ~/Applications (where Spotlight and Launchpad find it) and launches it.
set -euo pipefail
cd "$(dirname "$0")/.."

LOG=~/Calls/_diagnostics/audio-processes.log
if pgrep -f "CallRecorder.app/Contents/MacOS/CallRecorder" >/dev/null && [ -f "$LOG" ] \
   && grep -E "● recording|■ stop" "$LOG" | tail -1 | grep -q "● recording"; then
  echo "A recording is in progress — stop it and run the install again."
  exit 1
fi

./scripts/build-app.sh
osascript -e 'quit app id "com.sergeipotenko.CallRecorder"' 2>/dev/null || true
sleep 1

mkdir -p ~/Applications
rm -rf ~/Applications/CallRecorder.app
# Move rather than copy: two copies with the same bundle ID confuse Launch Services.
mv build/CallRecorder.app ~/Applications/
open ~/Applications/CallRecorder.app
echo "Installed and launched: ~/Applications/CallRecorder.app"
