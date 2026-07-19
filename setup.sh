#!/bin/bash
# Setup script for Swift-chDB — downloads chDB binaries + test dataset.
#
# Usage:
#   ./setup.sh                        # chDB binary (auto-detect OS + arch)
#   ./setup.sh --dataset              # Download test dataset (hits.parquet)
#   ./setup.sh --all                  # Binary + dataset
#   ./setup.sh --macos-arm64
#   ./setup.sh --macos-x86_64
#   ./setup.sh --linux-amd64
#   ./setup.sh --linux-arm64

set -euo pipefail

CHDB_VERSION="2.2.1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ──────────────────────────────────────────────
# Detection
# ──────────────────────────────────────────────

detect_os() {
    case "$(uname -s)" in
        Darwin*) echo "macos" ;;
        Linux*)  echo "linux" ;;
        *)       echo "unknown" ;;
    esac
}

detect_arch() {
    case "$(uname -m)" in
        arm64|aarch64) echo "arm64" ;;
        x86_64|amd64)  echo "amd64" ;;
        *)             echo "unknown" ;;
    esac
}

OS="$(detect_os)"
ARCH="$(detect_arch)"

# ──────────────────────────────────────────────
# macOS — télécharge et crée chdb.xcframework
# ──────────────────────────────────────────────

download_macos() {
    local arch="${1:-$ARCH}"
    local label="${arch}"

    # Map architecture to chDB release suffix
    case "$arch" in
        arm64)  local suffix="macos-arm64" ;;
        amd64)  local suffix="macos-x86_64" ;;
        *)      echo "❌ Unsupported macOS architecture: $arch"; exit 1 ;;
    esac

    echo "📥 Downloading chDB for macOS ${label}..."

    # Clean any previous partial download
    rm -rf chdb.xcframework

    # Download
    curl -fsSL "https://github.com/chdb-io/chdb/releases/download/v${CHDB_VERSION}/libchdb-${suffix}.tar.gz" \
        -o /tmp/libchdb-macos.tar.gz

    # Create xcframework structure
    local libdir="chdb.xcframework/${suffix}/Headers"
    mkdir -p "$libdir"
    tar xzf /tmp/libchdb-macos.tar.gz -C "chdb.xcframework/${suffix}/"
    rm -f /tmp/libchdb-macos.tar.gz

    # Module map
    cat > "$libdir/module.modulemap" << 'EOF'
module Cchdb [system] {
    header "chdb.h"
    link "chdb"
    export *
}
EOF

    # Info.plist
    cat > chdb.xcframework/Info.plist << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>AvailableLibraries</key>
    <array>
        <dict>
            <key>LibraryIdentifier</key>
            <string>${suffix}</string>
            <key>LibraryPath</key>
            <string>libchdb.so</string>
            <key>SupportedArchitectures</key>
            <array><string>${arch}</string></array>
            <key>SupportedPlatform</key>
            <string>macos</string>
            <key>HeadersPath</key>
            <string>Headers</string>
        </dict>
    </array>
    <key>CFBundlePackageType</key>
    <string>XFWK</string>
    <key>XCFrameworkFormatVersion</key>
    <string>1.0</string>
</dict>
</plist>
EOF

    echo "✅ chDB macOS ${label} → chdb.xcframework/"
}

# ──────────────────────────────────────────────
# Linux — télécharge libchdb.so + chdb.h
# ──────────────────────────────────────────────

download_linux() {
    local arch="${1:-$ARCH}"
    local label="${arch}"

    # Map architecture to chDB release suffix
    case "$arch" in
        arm64)  local suffix="linux-arm64" ;;
        amd64)  local suffix="linux-amd64" ;;
        *)      echo "❌ Unsupported Linux architecture: $arch"; exit 1 ;;
    esac

    echo "📥 Downloading chDB for Linux ${label}..."

    curl -fsSL "https://github.com/chdb-io/chdb/releases/download/v${CHDB_VERSION}/libchdb-${suffix}.tar.gz" \
        -o /tmp/libchdb-linux.tar.gz
    tar xzf /tmp/libchdb-linux.tar.gz -C /tmp/
    cp /tmp/libchdb.so .
    cp /tmp/chdb.h .
    rm -rf /tmp/libchdb*

    echo "✅ libchdb.so ($(ls -lh libchdb.so | awk '{print $5}')) for Linux ${label}"
}

# ──────────────────────────────────────────────
# Dataset — télécharge hits.parquet (ClickBench)
# ──────────────────────────────────────────────

download_dataset() {
    local file="hits.parquet"

    if [ -f "$file" ]; then
        echo "📄 $file already exists ($(ls -lh "$file" | awk '{print $5}'))"
        return
    fi

    echo "📥 Downloading ClickBench dataset..."
    curl -fsSL "https://github.com/ClickHouse/ClickBench/raw/main/hits/Parquet/hits.parquet" \
        -o "$file"
    echo "✅ $file ($(ls -lh "$file" | awk '{print $5}'))"
}

# ──────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────

MODE="${1:-auto}"

case "$MODE" in
    auto)
        case "$OS" in
            macos) download_macos "$ARCH" ;;
            linux) download_linux "$ARCH" ;;
            *)     echo "❌ Unknown OS: $OS"; exit 1 ;;
        esac
        ;;
    --dataset|dataset)
        download_dataset
        ;;
    --all|all)
        case "$OS" in
            macos) download_macos "$ARCH" ;;
            linux) download_linux "$ARCH" ;;
        esac
        download_dataset
        ;;
    --macos)        download_macos "$ARCH" ;;
    --macos-arm64)  download_macos "arm64" ;;
    --macos-x86_64) download_macos "amd64" ;;
    --linux)        download_linux "$ARCH" ;;
    --linux-amd64)  download_linux "amd64" ;;
    --linux-arm64)  download_linux "arm64" ;;
    *)
        echo "Usage: $0 [--macos-arm64|--macos-x86_64|--linux-amd64|--linux-arm64|--dataset|--all]"
        exit 1
        ;;
esac
