#!/bin/bash
set -euo pipefail
LABEL="dev.ruben.jpr-transcribe"
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
echo "servicio descargado y plist eliminado"
echo "el binario en ~/.local/bin/jpr-transcribe y el ledger se conservan"
