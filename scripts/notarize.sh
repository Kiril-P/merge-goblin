#!/usr/bin/env bash
#
# notarize.sh <file.dmg> — send a signed disk image to Apple and staple the ticket.
#
# Credentials, either way:
#   NOTARY_PROFILE=name                       a profile saved with
#                                             `xcrun notarytool store-credentials name`
#   APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD   an app-specific password
#
# The disk image must already be signed with a Developer ID Application identity
# (./build.sh --sign "Developer ID Application: Name (TEAMID)" --dmg). An Apple
# Development certificate cannot be notarised.

set -euo pipefail
FILE="${1:?usage: notarize.sh <file.dmg>}"

if [ -n "${NOTARY_PROFILE:-}" ]; then
  AUTH=(--keychain-profile "$NOTARY_PROFILE")
elif [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ] && [ -n "${APPLE_APP_PASSWORD:-}" ]; then
  AUTH=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD")
else
  echo "no notarisation credentials: set NOTARY_PROFILE, or APPLE_ID + APPLE_TEAM_ID + APPLE_APP_PASSWORD" >&2
  exit 2
fi

codesign --verify --strict "$FILE" 2>/dev/null || { echo "$FILE is not signed" >&2; exit 1; }
echo "submitting $FILE (this usually takes a few minutes)"
xcrun notarytool submit "$FILE" "${AUTH[@]}" --wait
xcrun stapler staple "$FILE"
xcrun stapler validate "$FILE"
spctl --assess --type open --context context:primary-signature -v "$FILE" 2>&1 || true
