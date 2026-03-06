#!/bin/bash
set -e

# =============================================================================
# Deploy appcast.xml to the latest non-prerelease GitHub Release
# Generates appcast.xml and uploads it as a release asset so that
# https://github.com/m13v/fazm/releases/latest/download/appcast.xml
# always serves the current appcast.
#
# We upload to the latest NON-prerelease release because GitHub's
# /releases/latest/ URL skips prereleases (staging builds).
# =============================================================================

GITHUB_REPO="m13v/fazm"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APPCAST_FILE="/tmp/appcast.xml"

echo "Deploying appcast.xml to latest GitHub release..."

# Step 1: Generate appcast.xml
"$SCRIPT_DIR/generate-appcast.sh" "$APPCAST_FILE"

# Step 2: Get the latest non-prerelease release tag
# GitHub's /releases/latest points to the most recent non-prerelease, non-draft release.
# We mirror that logic here so appcast.xml is always reachable at /releases/latest/download/appcast.xml
LATEST_TAG=$(gh release list --repo "$GITHUB_REPO" --limit 20 --json tagName,isPrerelease,isDraft \
    -q '[.[] | select(.isPrerelease == false and .isDraft == false)][0].tagName' 2>/dev/null)

if [ -z "$LATEST_TAG" ]; then
    echo "Error: No non-prerelease releases found for $GITHUB_REPO"
    rm -f "$APPCAST_FILE"
    exit 1
fi

echo "Uploading appcast.xml to release: $LATEST_TAG"

# Step 3: Upload appcast.xml (--clobber overwrites if it already exists)
gh release upload "$LATEST_TAG" "$APPCAST_FILE" \
    --repo "$GITHUB_REPO" \
    --clobber

# Cleanup
rm -f "$APPCAST_FILE"

echo "Done! Appcast available at:"
echo "  https://github.com/$GITHUB_REPO/releases/latest/download/appcast.xml"
