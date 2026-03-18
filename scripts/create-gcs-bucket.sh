#!/bin/bash
# Creates the fazm-releases GCS bucket for hosting arch-specific app payloads.
# Run once: ./scripts/create-gcs-bucket.sh

set -euo pipefail

PROJECT="fazm-prod"
BUCKET="fazm-releases"
REGION="us-east1"

echo "Creating GCS bucket gs://$BUCKET in project $PROJECT..."

# Create bucket
gcloud storage buckets create "gs://$BUCKET" \
    --project="$PROJECT" \
    --location="$REGION" \
    --uniform-bucket-level-access \
    --public-access-prevention=inherited \
    2>/dev/null || echo "Bucket already exists"

# Make objects publicly readable
gcloud storage buckets add-iam-policy-binding "gs://$BUCKET" \
    --member="allUsers" \
    --role="roles/storage.objectViewer" \
    --project="$PROJECT"

# Set CORS for browser downloads
cat > /tmp/fazm-releases-cors.json << 'EOF'
[
  {
    "origin": ["*"],
    "method": ["GET", "HEAD"],
    "responseHeader": ["Content-Type", "Content-Length", "Content-Range"],
    "maxAgeSeconds": 3600
  }
]
EOF

gcloud storage buckets update "gs://$BUCKET" \
    --cors-file=/tmp/fazm-releases-cors.json \
    --project="$PROJECT"

rm /tmp/fazm-releases-cors.json

echo "Done. Bucket gs://$BUCKET is ready for public downloads."
echo "URL pattern: https://storage.googleapis.com/$BUCKET/desktop/{version}/Fazm-{arch}.zip"
