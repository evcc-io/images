#!/usr/bin/env bash
set -euo pipefail

# build-local.sh
# Local testing script for evcc image builds on macOS using Docker
# Mimics the GitHub Actions workflow for local development and testing

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
REPO_ROOT="$SCRIPT_DIR"

BOARD=""

usage() {
  cat <<EOF
Usage: $0 --board <board>

Build evcc images locally using Docker (mimics GitHub Actions workflow)

Arguments:
  --board <board>      Target board (rpi, nanopi-r3s)

Examples:
  ./build-local.sh --board rpi
  ./build-local.sh --board nanopi-r3s

Supported boards:
  - rpi          Raspberry Pi
  - nanopi-r3s   NanoPi R3S

EOF
}

check_requirements() {
  echo "🔍 Checking requirements..."
  
  # Check if Docker is installed and running
  if ! command -v docker >/dev/null 2>&1; then
    echo "❌ Docker is not installed. Please install Docker Desktop for Mac."
    exit 1
  fi
  
  if ! docker info >/dev/null 2>&1; then
    echo "❌ Docker is not running. Please start Docker Desktop."
    exit 1
  fi
  
  # Check if required tools are available
  for cmd in git curl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "❌ Required command '$cmd' not found"
      exit 1
    fi
  done
  
  echo "✅ All requirements met"
}

validate_board() {
  case "$BOARD" in
    rpi|nanopi-r3s)
      echo "✅ Board '$BOARD' is supported"
      ;;
    *)
      echo "❌ Unsupported board: '$BOARD'"
      echo "Supported boards: rpi, nanopi-r3s"
      exit 1
      ;;
  esac
}


parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --board)
        BOARD="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "❌ Unknown argument: $1"
        usage
        exit 1
        ;;
    esac
  done

  if [[ -z "$BOARD" ]]; then
    echo "❌ --board is required"
    usage
    exit 1
  fi
}

setup_environment() {
  echo "🔧 Setting up build environment..."
  
  # Create required directories
  mkdir -p "$REPO_ROOT/dist" "$REPO_ROOT/logs"
  
  echo "🎯 Target: $BOARD"
}

build_image() {
  echo "🚀 Starting image build..."
  echo "⏰ This may take 30-60 minutes depending on your hardware..."
  
  # Run the build script with 'local' as release name for local builds
  if ! bash "$REPO_ROOT/scripts/build-armbian.sh" --board "$BOARD" --release-name "local"; then
    echo "❌ Build failed"
    exit 1
  fi
  
  echo "✅ Build completed successfully"
}



show_results() {
  echo ""
  echo "🎉 Build completed successfully!"
  echo ""
  echo "📁 Output files:"
  find "$REPO_ROOT/dist" -type f \( -name "*.img" -o -name "*.img.sha" -o -name "*.img.txt" \) -exec ls -lh {} \; | sed 's/^/   /'
  echo ""
  echo "📍 Location: $REPO_ROOT/dist/"
}

cleanup_build() {
  echo "🧹 Cleaning up build artifacts..."
  # The build script handles its own cleanup
}

main() {
  echo "🔧 evcc Local Image Builder"
  echo "=========================="
  echo ""
  
  parse_args "$@"
  check_requirements
  validate_board
  setup_environment
  
  # Set up cleanup trap
  trap cleanup_build EXIT
  
  build_image
  show_results
  
  echo ""
  echo "✨ Done! You can now test your image."
}

main "$@"
