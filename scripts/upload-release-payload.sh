#!/bin/bash
# Uploads arch-specific ZIPs and latest.json manifest to GCS.
# Usage: ./scripts/upload-release-payload.sh <version> <arm64-zip> <x86_64-zip>
# Example: ./scripts/upload-release-payload.sh 0.2.4+16 build/Fazm-arm64.zip build/Fazm-x86_64.zip

set -euo pipefail

VERSION="${1:?Usage: $0 <version> <arm64-zip> <x86_64-zip>}"
ARM64_ZIP="${2:?Missing arm64 ZIP path}"
X86_64_ZIP="${3:?Missing x86_64 ZIP path}"

BUCKET="fazm-releases"
PREFIX="desktop/$VERSION"
BASE_URL="https://storage.googleapis.com/$BUCKET"

echo "Uploading Fazm $VERSION payloads to gs://$BUCKET/$PREFIX/"

# Upload arch-specific ZIPs
gcloud storage cp "$ARM64_ZIP"  "gs://$BUCKET/$PREFIX/Fazm-arm64.zip"
gcloud storage cp "$X86_64_ZIP" "gs://$BUCKET/$PREFIX/Fazm-x86_64.zip"

# Compute SHA256 and sizes
ARM64_SHA256=$(shasum -a 256 "$ARM64_ZIP" | awk '{print $1}')
X86_64_SHA256=$(shasum -a 256 "$X86_64_ZIP" | awk '{print $1}')
ARM64_SIZE=$(stat -f%z "$ARM64_ZIP" 2>/dev/null || stat -c%s "$ARM64_ZIP")
X86_64_SIZE=$(stat -f%z "$X86_64_ZIP" 2>/dev/null || stat -c%s "$X86_64_ZIP")

# Generate latest.json manifest
cat > /tmp/fazm-latest.json << EOF
{
  "version": "$VERSION",
  "arm64": {
    "url": "$BASE_URL/$PREFIX/Fazm-arm64.zip",
    "size": $ARM64_SIZE,
    "sha256": "$ARM64_SHA256"
  },
  "x86_64": {
    "url": "$BASE_URL/$PREFIX/Fazm-x86_64.zip",
    "size": $X86_64_SIZE,
    "sha256": "$X86_64_SHA256"
  }
}
EOF

echo "Manifest:"
cat /tmp/fazm-latest.json

# Upload manifest (versioned + latest)
gcloud storage cp /tmp/fazm-latest.json "gs://$BUCKET/$PREFIX/latest.json"
gcloud storage cp /tmp/fazm-latest.json "gs://$BUCKET/desktop/latest.json" \
    --cache-control="no-cache, max-age=0"

rm /tmp/fazm-latest.json

echo ""
echo "Upload complete:"
echo "  arm64:  $BASE_URL/$PREFIX/Fazm-arm64.zip ($ARM64_SIZE bytes, sha256=$ARM64_SHA256)"
echo "  x86_64: $BASE_URL/$PREFIX/Fazm-x86_64.zip ($X86_64_SIZE bytes, sha256=$X86_64_SHA256)"
echo "  manifest: $BASE_URL/desktop/latest.json"
