#!/bin/bash
set -euo pipefail

# This script updates the rpi-imager.json file with the latest release information
# It should be run after a new release is created

# Check if gh CLI is available
if ! command -v gh &> /dev/null; then
    echo "GitHub CLI (gh) is required but not installed."
    exit 1
fi

# Check if jq is available
if ! command -v jq &> /dev/null; then
    echo "jq is required but not installed."
    exit 1
fi

# Get the latest non-draft release
LATEST_RELEASE=$(gh release list --exclude-drafts --limit 1 --json tagName -q '.[0].tagName' 2>/dev/null)
if [ -z "$LATEST_RELEASE" ]; then
    echo "No non-draft releases found"
    exit 1
fi

echo "Processing release: $LATEST_RELEASE"

# Get release info (verify it's not a draft)
RELEASE_INFO=$(gh release view "$LATEST_RELEASE" --json tagName,publishedAt,assets,isDraft)
IS_DRAFT=$(echo "$RELEASE_INFO" | jq -r '.isDraft')
if [ "$IS_DRAFT" = "true" ]; then
    echo "Release $LATEST_RELEASE is a draft, skipping"
    exit 1
fi
RELEASE_DATE=$(echo "$RELEASE_INFO" | jq -r '.publishedAt' | cut -d'T' -f1)
VERSION=$(echo "$LATEST_RELEASE" | sed 's/^v//')

# Find the rpi image (which works on RPi 3, 4, and 5)
RPI_IMAGE_ZIP=$(echo "$RELEASE_INFO" | jq -r '.assets[] | select(.name | contains("_rpi") and contains(".img.zip")) | .name')
RPI_IMAGE_SHA=$(echo "$RELEASE_INFO" | jq -r '.assets[] | select(.name | contains("_rpi") and contains(".img.sha")) | .name')

if [ -z "$RPI_IMAGE_ZIP" ] || [ -z "$RPI_IMAGE_SHA" ]; then
    echo "RPi image not found in release"
    echo "Available assets:"
    echo "$RELEASE_INFO" | jq -r '.assets[].name'
    exit 1
fi

echo "Found RPi image: $RPI_IMAGE_ZIP"
echo "Found SHA file: $RPI_IMAGE_SHA"

# Construct download URLs
IMAGE_URL="https://github.com/evcc-io/images/releases/download/${LATEST_RELEASE}/${RPI_IMAGE_ZIP}"
SHA_URL="https://github.com/evcc-io/images/releases/download/${LATEST_RELEASE}/${RPI_IMAGE_SHA}"

# Download SHA file to get checksums
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

echo "Downloading SHA file from: $SHA_URL"
if ! curl -fL "$SHA_URL" -o "$TEMP_DIR/image.sha"; then
    echo "Failed to download SHA file from $SHA_URL"
    exit 1
fi

# Parse SHA file - it's just "hash filename" format
EXTRACT_SHA256=$(cut -d' ' -f1 "$TEMP_DIR/image.sha")
if [ -z "$EXTRACT_SHA256" ]; then
    echo "Failed to parse SHA256 from SHA file"
    echo "SHA file contents:"
    cat "$TEMP_DIR/image.sha"
    exit 1
fi
echo "Extracted SHA256: $EXTRACT_SHA256"

# Get file size from GitHub
IMAGE_SIZE=$(echo "$RELEASE_INFO" | jq -r ".assets[] | select(.name == \"$RPI_IMAGE_ZIP\") | .size")
if [ -z "$IMAGE_SIZE" ]; then
    echo "Failed to get image size from GitHub"
    exit 1
fi
echo "Image download size: $IMAGE_SIZE bytes"

# Calculate SHA256 of the ZIP file (we need to download it)
echo "Downloading image to calculate ZIP SHA256 from: $IMAGE_URL"
if ! curl -fL "$IMAGE_URL" -o "$TEMP_DIR/image.zip"; then
    echo "Failed to download image from $IMAGE_URL"
    exit 1
fi
IMAGE_SHA256=$(sha256sum "$TEMP_DIR/image.zip" | cut -d' ' -f1)

# Get uncompressed size (extract and check)
echo "Extracting image to get uncompressed size..."
if ! unzip -q "$TEMP_DIR/image.zip" -d "$TEMP_DIR/"; then
    echo "Failed to extract image"
    exit 1
fi
EXTRACT_SIZE=$(stat -c%s "$TEMP_DIR"/*.img)
echo "Extracted image size: $EXTRACT_SIZE bytes"

# Create the final JSON from template
cp scripts/rpi-imager/template.json rpi-imager.json

# Replace placeholders (Linux sed syntax for GitHub Actions)
sed -i "s|__VERSION__|$VERSION|g" rpi-imager.json
sed -i "s|__RELEASE_DATE__|$RELEASE_DATE|g" rpi-imager.json
sed -i "s|__IMAGE_URL__|$IMAGE_URL|g" rpi-imager.json
sed -i "s|__EXTRACT_SIZE__|$EXTRACT_SIZE|g" rpi-imager.json
sed -i "s|__EXTRACT_SHA256__|$EXTRACT_SHA256|g" rpi-imager.json
sed -i "s|__IMAGE_SIZE__|$IMAGE_SIZE|g" rpi-imager.json
sed -i "s|__IMAGE_SHA256__|$IMAGE_SHA256|g" rpi-imager.json

echo "Successfully updated rpi-imager.json"
echo "Version: $VERSION"
echo "Image URL: $IMAGE_URL"
echo "Image Size: $IMAGE_SIZE bytes"
echo "Extract Size: $EXTRACT_SIZE bytes"