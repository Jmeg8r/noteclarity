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

# WHAT: source-state gate. WHY: a signed, notarized build from a dirty tree or
# an unpushed commit is otherwise indistinguishable from a real release.
[[ -z "$(git status --porcelain)" ]] \
    || { echo "ERROR: working tree is not clean — commit or stash before releasing."; git status --short; exit 1; }
git fetch origin main --quiet
HEAD_SHA=$(git rev-parse HEAD)
git merge-base --is-ancestor "$HEAD_SHA" origin/main \
    || { echo "ERROR: HEAD ($HEAD_SHA) is not on origin/main — releases build only published main history."; exit 1; }
echo "Source: clean tree at $HEAD_SHA (on origin/main)"

VERSION=$(xcodebuild -showBuildSettings -project NoteClarity.xcodeproj -scheme NoteClarity \
    -configuration Release 2>/dev/null | awk '/ MARKETING_VERSION /{print $3}')
[[ -n "$VERSION" ]] || { echo "ERROR: could not read MARKETING_VERSION."; exit 1; }
echo "Version: $VERSION"
# Check the REMOTE for the tag too — `git fetch origin main` does not bring
# tags down, so a local-only check can miss an already-published release.
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null \
    || [[ -n "$(git ls-remote --tags origin "refs/tags/v$VERSION")" ]]; then
    echo "ERROR: tag v$VERSION already exists — bump MARKETING_VERSION first."; exit 1
fi

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
# hdiutil images are unsigned; give the DMG a Developer ID signature of its
# own so the container has a verifiable origin (and the spctl open-context
# check below can pass).
codesign --force --sign "Developer ID Application" --timestamp "$DMG"
# The DMG needs its own notarization record before it can be stapled — the
# app's ticket doesn't transfer to the container (stapler fails with a
# CloudKit "Record not found" otherwise).
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl -a -t open --context context:primary-signature -vv "$DMG"

# WHAT: published checksum. WHY: lets anyone verify the download they got is
# the artifact this run produced. Basename-relative so a downloader can run
# `shasum -a 256 -c` next to the two assets without recreating build/.
(cd "$(dirname "$DMG")" && shasum -a 256 "$(basename "$DMG")" | tee "$(basename "$DMG").sha256")
echo "DMG ready: $DMG"

if $PUBLISH; then
    echo "== Publish GitHub release v$VERSION =="
    gh release create "v$VERSION" "$DMG" "$DMG.sha256" --repo Jmeg8r/noteclarity \
        --title "NoteClarity $VERSION" --generate-notes
else
    echo "Dry run complete. Re-run with --publish to create the GitHub release."
fi
