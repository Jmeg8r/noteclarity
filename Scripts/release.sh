#!/usr/bin/env bash
# WHAT: NoteClarity release pipeline — archive, Developer ID export, notarize,
#       staple, package a DMG, and (only with --publish) create the GitHub release.
# WHY the flag: a bare run produces a fully validated local DMG and never
#       publishes anything.
#
# One-time setup:
#   export DEVELOPMENT_TEAM=<your team id>           # never committed
#   xcrun notarytool store-credentials NoteClarityRelease \
#       --apple-id <apple-id email> --team-id "$DEVELOPMENT_TEAM"
set -euo pipefail
cd "$(dirname "$0")/.."

: "${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to your Apple Developer Team ID (never commit it)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-NoteClarityRelease}"
PUBLISH=false
[[ "${1:-}" == "--publish" ]] && PUBLISH=true

echo "== Preflight =="
security find-identity -v -p codesigning | grep -q "Developer ID Application" \
    || { echo "ERROR: no 'Developer ID Application' identity in the keychain."; exit 1; }
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || { echo "ERROR: notary profile '$NOTARY_PROFILE' missing — run the store-credentials command in this script's header."; exit 1; }

VERSION=$(xcodebuild -showBuildSettings -project NoteClarity.xcodeproj -scheme NoteClarity \
    -configuration Release 2>/dev/null | awk '/ MARKETING_VERSION /{print $3}')
[[ -n "$VERSION" ]] || { echo "ERROR: could not read MARKETING_VERSION."; exit 1; }
echo "Version: $VERSION"

BUILD=build
APP=NoteClarity.app
ARCHIVE="$BUILD/NoteClarity.xcarchive"
rm -rf "$BUILD"; mkdir -p "$BUILD"

echo "== Archive (Release, Developer ID) =="
xcodebuild archive -project NoteClarity.xcodeproj -scheme NoteClarity \
    -configuration Release -archivePath "$ARCHIVE" \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" | tail -2

echo "== Export =="
cat > "$BUILD/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>method</key><string>developer-id</string>
	<key>teamID</key><string>$DEVELOPMENT_TEAM</string>
	<key>signingStyle</key><string>manual</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$BUILD/export" \
    -exportOptionsPlist "$BUILD/ExportOptions.plist" | tail -2

echo "== Notarize =="
ditto -c -k --keepParent "$BUILD/export/$APP" "$BUILD/NoteClarity.zip"
xcrun notarytool submit "$BUILD/NoteClarity.zip" --keychain-profile "$NOTARY_PROFILE" --wait

echo "== Staple + validate app =="
xcrun stapler staple "$BUILD/export/$APP"
xcrun stapler validate "$BUILD/export/$APP"
spctl -a -vv --type execute "$BUILD/export/$APP"

echo "== Package DMG =="
DMG_STAGE="$BUILD/dmg-staging"
mkdir -p "$DMG_STAGE"
cp -R "$BUILD/export/$APP" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"
DMG="$BUILD/NoteClarity-$VERSION.dmg"
hdiutil create -volname "NoteClarity" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DMG" >/dev/null
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
echo "DMG ready: $DMG"

if $PUBLISH; then
    echo "== Publish GitHub release v$VERSION =="
    gh release create "v$VERSION" "$DMG" --repo Jmeg8r/noteclarity \
        --title "NoteClarity $VERSION" --generate-notes
else
    echo "Dry run complete. Re-run with --publish to create the GitHub release."
fi
