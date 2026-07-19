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
    echo "✅ chDB xcframework already bundled in repo for macOS"
    if [ ! -f "chdb.xcframework/Info.plist" ]; then
        echo "❌ Missing chdb.xcframework — use git clone or re-download"
        exit 1
    fi
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

    echo "📥 Downloading ClickBench dataset (100K rows, ~8 MB)..."
    # Official ClickBench parquet dataset (100K row subset)
    curl -fsSL "https://datasets.clickhouse.com/hits/parquet/hits.parquet" \
        -o "$file" && {
        echo "✅ $file ($(ls -lh "$file" | awk '{print $5}'))"
        return
    }

    # Fallback: GitHub releases
    echo "⚠️ Primary URL failed, trying GitHub..."
    curl -fsSL "https://github.com/ClickHouse/ClickBench/releases/download/v1.0/hits.parquet" \
        -o "$file" && {
        echo "✅ $file ($(ls -lh "$file" | awk '{print $5}'))"
        return
    }

    echo "❌ Could not download dataset. Use a custom file:"
    echo "   swift run chdb-clickbench --parquet-path /path/to/hits.parquet"
}

# ──────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────

MODE="${1:-auto}"

case "$MODE" in
    auto)
        case "$OS" in
            macos) download_macos ;;
            linux) download_linux "$ARCH" ;;
            *)     echo "❌ Unknown OS: $OS"; exit 1 ;;
        esac
        ;;
    --dataset|dataset)
        download_dataset
        ;;
    --all|all)
        case "$OS" in
            macos) download_macos ;;
            linux) download_linux "$ARCH" ;;
        esac
        download_dataset
        ;;
    --macos)        download_macos ;;
    --macos-arm64)  download_macos ;;
    --macos-x86_64) download_macos ;;
    --linux)        download_linux "$ARCH" ;;
    --linux-amd64)  download_linux "amd64" ;;
    --linux-arm64)  download_linux "arm64" ;;
    *)
        echo "Usage: $0 [--macos-arm64|--macos-x86_64|--linux-amd64|--linux-arm64|--dataset|--all]"
        exit 1
        ;;
esac
