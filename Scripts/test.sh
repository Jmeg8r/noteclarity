#!/usr/bin/env bash
# AppKit also writes preferences, so the test host needs its own bundle id in
# addition to the scheme's scratch support directory and file-backed settings.
set -euo pipefail
cd "$(dirname "$0")/.."
run_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
exec xcodebuild -project NoteClarity.xcodeproj -scheme NoteClarity \
    -configuration Debug -destination 'platform=macOS' \
    CODE_SIGNING_ALLOWED=NO \
    "NOTECLARITY_BUNDLE_ID=com.jmeg8r.noteclarity.verification.$run_id" \
    "$@" test
