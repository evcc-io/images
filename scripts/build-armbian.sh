#!/usr/bin/env bash
set -euo pipefail

# build-armbian.sh
# Wrapper to run Armbian Build in Docker and produce customized images containing
# evcc, cockpit and caddy with reverse proxy to evcc on 443 (TLS internal).

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/.." && pwd)

BOARD=""
HOSTNAME="evcc"
EVCC_CHANNEL="stable" # stable|nightly

usage() {
  cat <<EOF
Usage: $0 --board <armbian-board> [--evcc-channel stable|unstable]

Examples:
  $0 --board rpi4b
  $0 --board radxa-e52c

Supported boards are those supported by Armbian mainline (e.g. rpi4b, radxa-e52c if available).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --board) BOARD="$2"; shift 2 ;;
    --evcc-channel) EVCC_CHANNEL="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1"; usage; exit 1 ;;
  esac
done

if [[ -z "$BOARD" ]]; then
  echo "--board is required" >&2
  usage
  exit 2
fi

mkdir -p "$REPO_ROOT/dist" "$REPO_ROOT/logs"

# Prepare a temporary userpatches with variables passed to customize-image.sh
BUILDTMP=$(mktemp -d)
cleanup() {
  # The Armbian build may create root-owned cache files; try regular rm first, then sudo if needed
  rm -rf "$BUILDTMP" 2>/dev/null || sudo rm -rf "$BUILDTMP" 2>/dev/null || true
  # Clean up macOS-specific build directory
  if [[ "$(uname)" == "Darwin" && -n "$BUILD_DIR" && "$BUILD_DIR" =~ ^$HOME/\.armbian-build- ]]; then
    rm -rf "$BUILD_DIR" 2>/dev/null || sudo rm -rf "$BUILD_DIR" 2>/dev/null || true
  fi
}
trap cleanup EXIT
mkdir -p "$BUILDTMP/userpatches/overlay/etc"


# Exported to the chroot via /etc/evcc-image.env
cat >"$BUILDTMP/userpatches/overlay/etc/evcc-image.env" <<ENV
EVCC_CHANNEL=${EVCC_CHANNEL}
EVCC_HOSTNAME=${HOSTNAME}
ENV

# Copy our customize script and auxiliary files
cp -a "$REPO_ROOT/userpatches/." "$BUILDTMP/userpatches/"
chmod +x "$BUILDTMP/userpatches/customize-image.sh" || true

IMAGE_OUT_DIR="$REPO_ROOT/dist/${BOARD}"
mkdir -p "$IMAGE_OUT_DIR"

# Clone Armbian build framework and run it in Docker mode (it will build its own container image).
# On macOS, Armbian requires the build directory to be under the home directory
if [[ "$(uname)" == "Darwin" ]]; then
  BUILD_DIR="$HOME/.armbian-build-$(date +%s)"
else
  BUILD_DIR="$BUILDTMP/build"
fi
git clone --depth=1 --branch v25.8.1 https://github.com/armbian/build.git "$BUILD_DIR"

# Place our userpatches into the build tree
rm -rf "$BUILD_DIR/userpatches"
cp -a "$BUILDTMP/userpatches" "$BUILD_DIR/userpatches"

# Read evcc version from repository file and compute output channel dir name
if [[ -f "$REPO_ROOT/EVCC_VERSION" ]]; then
  EVCC_VERSION=$(tr -d '\n\r' < "$REPO_ROOT/EVCC_VERSION")
fi

echo "Starting build for board=${BOARD} release=bookworm using Armbian build"
pushd "$BUILD_DIR" >/dev/null
  EXPERT=yes \
  SKIP_LOG_ARCHIVE=yes \
  SHARE_LOG=yes \
  USE_TORRENT=no \
  OFFLINE_WORK=no \
  VENDOR="evcc" \
  VENDORURL="https://evcc.io" \
  IMAGE_SUFFIX="evcc-${EVCC_VERSION}" \
  NETWORKING_STACK="network-manager" \
  ./compile.sh \
    BOARD="$BOARD" \
    BRANCH=current \
    RELEASE="bookworm" \
    BUILD_MINIMAL=no \
    BUILD_DESKTOP=no \
    KERNEL_CONFIGURE=no \
    COMPRESS_OUTPUTIMAGE=sha,zip
popd >/dev/null

# Copy results to channel-specific output directory
IMAGE_OUT_DIR="$REPO_ROOT/dist/${EVCC_CHANNEL}/${BOARD}"
mkdir -p "$IMAGE_OUT_DIR"
if compgen -G "$BUILD_DIR/output/images/*" > /dev/null; then
  cp -a "$BUILD_DIR/output/images/"* "$IMAGE_OUT_DIR/"
fi

# Rename outputs to armbian_evcc-[evcc-version]_[board].img[...]
shopt -s nullglob
for f in "$IMAGE_OUT_DIR"/Armbian-*; do
  base_ext="${f##*.}"
  if [[ "$f" == *.img ]]; then
    mv -f "$f" "$IMAGE_OUT_DIR/armbian_evcc-${EVCC_VERSION}_${BOARD}.img"
  elif [[ "$f" == *.img.sha ]]; then
    mv -f "$f" "$IMAGE_OUT_DIR/armbian_evcc-${EVCC_VERSION}_${BOARD}.img.sha"
  elif [[ "$f" == *.img.txt ]]; then
    mv -f "$f" "$IMAGE_OUT_DIR/armbian_evcc-${EVCC_VERSION}_${BOARD}.img.txt"
  elif [[ "$f" == *.img.zip ]]; then
    mv -f "$f" "$IMAGE_OUT_DIR/armbian_evcc-${EVCC_VERSION}_${BOARD}.img.zip"
  fi
done
shopt -u nullglob

echo "Build done. Output in $IMAGE_OUT_DIR"


