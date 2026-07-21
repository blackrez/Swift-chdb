#!/bin/bash
# Setup script for Swift-chDB — downloads chDB binaries + SPM artifact bundle.
# Usage:
#   ./setup.sh                          # download current platform variant (static)
#   ./setup.sh --current-dynamic        # download current platform variant (dynamic)
#   ./setup.sh --dataset                # download hits.parquet
#   ./setup.sh --all                    # current variant + dataset
#   ./setup.sh --build-bundle           # download ALL variants & build artifact bundle
#   ./setup.sh --install                # Linux: install libchdb.so system-wide
#   ./setup.sh --install-dynamic        # macOS: install libchdb.dylib system-wide

set -euo pipefail

CHDB_VERSION="26.5.0"
RELEASE_VERSION="26.5.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

detect_os()   { case "$(uname -s)" in Darwin*) echo macos ;; Linux*) echo linux ;; *) echo unknown ;; esac; }
detect_arch() { case "$(uname -m)" in arm64|aarch64) echo arm64 ;; x86_64|amd64) echo amd64 ;; *) echo unknown ;; esac; }
OS=$(detect_os); ARCH=$(detect_arch)

# ──────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────

variant_suffix() {
    case "$1" in
        macos-arm64)   echo "macos-arm64" ;;
        macos-x86_64)  echo "macos-x86_64" ;;
        linux-x86_64)  echo "linux-x86_64" ;;
        linux-aarch64) echo "linux-aarch64" ;;
        *) echo "unknown"; exit 1 ;;
    esac
}

target_triple() {
    case "$1" in
        macos-arm64)   echo "arm64-apple-macosx" ;;
        macos-x86_64)  echo "x86_64-apple-macosx" ;;
        linux-x86_64)  echo "x86_64-unknown-linux-gnu" ;;
        linux-aarch64) echo "aarch64-unknown-linux-gnu" ;;
        *) echo "unknown"; exit 1 ;;
    esac
}

lib_extension() {
    case "$1" in
        macos-*) echo "dylib" ;;
        *)       echo "so" ;;
    esac
}

download_variant() {
    local variant="$1"
    local suffix
    suffix=$(variant_suffix "$variant")
    local url="https://github.com/chdb-io/chdb-core/releases/download/v${CHDB_VERSION}/${suffix}-libchdb-static.tar.gz"
    local tmpdir="/tmp/chdb-variant-${variant}"
    rm -rf "$tmpdir"
    mkdir -p "$tmpdir"
    echo >&2 "📥 Downloading ${variant} (static)..."
    curl -fsSL "$url" -o "/tmp/${variant}.tar.gz"
    tar xzf "/tmp/${variant}.tar.gz" -C "$tmpdir"
    rm -f "/tmp/${variant}.tar.gz"
    echo "$tmpdir"
}

# ──────────────────────────────────────────────
# Build artifact bundle (all platforms)
# ──────────────────────────────────────────────

build_artifactbundle() {
    local variants=("$@")
    [ ${#variants[@]} -eq 0 ] && variants=("macos-arm64" "macos-x86_64" "linux-x86_64" "linux-aarch64")

    local checksums=()

    for variant in "${variants[@]}"; do
        local tmpdir
        tmpdir=$(download_variant "$variant") || {
            echo >&2 "⚠️  Skipping ${variant} (download failed)"
            rm -rf "$tmpdir" 2>/dev/null || true
            continue
        }
        local triple
        triple=$(target_triple "$variant")
        local ext
        ext=$(lib_extension "$variant")
        local name="Cchdb-${variant}.artifactbundle"
        local dir="${name}/${variant}"

        rm -rf "$name"
        mkdir -p "$dir"

        # Copy binary with correct platform extension
        cp "$tmpdir/libchdb.a" "$dir/libchdb.a"

        # Copy header
        [ -f "$tmpdir/chdb.h" ] && cp "$tmpdir/chdb.h" "$dir/"

        # Create modulemap
        cat > "$dir/module.modulemap" << 'EOF'
module Cchdb [system] {
    header "chdb.h"
    link "chdb"
    export *
}
EOF

        # Create info.json
        cat > "$name/info.json" << JSON
{
    "schemaVersion": "1.0",
    "artifacts": {
        "Cchdb": {
            "version": "${CHDB_VERSION}",
            "type": "staticLibrary",
            "variants": [
                {
                    "path": "${variant}/libchdb.${ext}",
                    "supportedTriples": ["${triple}"],
                    "staticLibraryMetadata": {
                        "moduleMapPath": "${variant}/module.modulemap",
                        "headerPaths": ["${variant}/chdb.h"]
                    }
                }
            ]
        }
    }
}
JSON

        # Zip (plain zip to avoid macOS metadata issues)
        local zipname="${name}.zip"
        rm -f "$zipname"
        zip -r --symlinks "$zipname" "$name"
        local chksum
        chksum=$(shasum -a 256 "$zipname" | awk '{print $1}')
        local size
        size=$(ls -lh "$zipname" | awk '{print $5}')

        echo >&2 "  ✅ ${zipname} (${size})  sha256: ${chksum}"

        # Save for final summary
        checksums+=("${variant}|${zipname}|${chksum}|${triple}")

        rm -rf "$tmpdir" "$name"
    done

    echo >&2 ""
    echo >&2 "────────────────────────────────────────────"
    echo >&2 "  Update Package.swift with these values:"
    echo >&2 "────────────────────────────────────────────"
    echo >&2 ""

    for entry in "${checksums[@]}"; do
        IFS='|' read -r variant zipname chksum triple <<< "$entry"
        # Map variant to os/arch condition
        case "$variant" in
            macos-arm64)   cond="#if os(macOS) && arch(arm64)" ;;
            macos-x86_64)  cond="#elseif os(macOS) && arch(x86_64)" ;;
            linux-x86_64)  cond="#elseif os(Linux) && arch(x86_64)" ;;
            linux-aarch64) cond="#elseif os(Linux) && arch(arm64)" ;;
        esac
        echo >&2 "$cond"
        echo >&2 "let chdbTarget: Target = .binaryTarget("
        echo >&2 "    name: \"Cchdb\","
        echo >&2 "    url: \"https://github.com/blackrez/Swift-chdb/releases/download/v${RELEASE_VERSION}/${zipname}\","
        echo >&2 "    checksum: \"$chksum\""
        echo >&2 ")"
    done
    echo >&2 "#endif"
}

# ──────────────────────────────────────────────
# Download single variant (for local dev)
# ──────────────────────────────────────────────

download_current() {
    case "$OS" in
        macos) variant="macos-${ARCH}" ;;
        linux) variant="linux-${ARCH}" ;;
        *) echo "❌ Unsupported platform: $OS $ARCH"; exit 1 ;;
    esac
    local tmpdir
    tmpdir=$(download_variant "$variant")
    rm -rf chdb.xcframework Cchdb.artifactbundle libchdb.a libchdb.so chdb.h
    mkdir -p "Cchdb.artifactbundle/${variant}"
    cp "$tmpdir/libchdb.a" "Cchdb.artifactbundle/${variant}/"
    [ -f "$tmpdir/chdb.h" ] && cp "$tmpdir/chdb.h" .
    rm -rf "$tmpdir"
    echo "✅ ${variant} → Cchdb.artifactbundle/${variant}/libchdb.a ($(ls -lh "Cchdb.artifactbundle/${variant}/libchdb.a" | awk '{print $5}'))"
}

# ──────────────────────────────────────────────
# Download dynamic variant (for local dev)
# ──────────────────────────────────────────────

download_current_dynamic() {
    case "$OS" in
        macos) variant="macos-${ARCH}" ;;
        linux) variant="linux-${ARCH}" ;;
        *) echo "❌ Unsupported platform: $OS $ARCH"; exit 1 ;;
    esac
    local suffix
    suffix=$(variant_suffix "$variant")
    local ext
    case "$OS" in macos) ext="dylib" ;; linux) ext="so" ;; esac

    local url="https://github.com/chdb-io/chdb-core/releases/download/v${CHDB_VERSION}/${suffix}-libchdb.tar.gz"
    local tmpdir="/tmp/chdb-dynamic"
    rm -rf "$tmpdir"
    mkdir -p "$tmpdir"
    echo >&2 "📥 Downloading ${variant} (dynamic)..."
    curl -fsSL "$url" -o "/tmp/chdb-dynamic.tar.gz"
    tar xzf "/tmp/chdb-dynamic.tar.gz" -C "$tmpdir"
    rm -f "/tmp/chdb-dynamic.tar.gz"

    # macOS releases may ship as .so — rename to .dylib
    if [ "$OS" = "macos" ] && [ -f "$tmpdir/libchdb.so" ]; then
        mv "$tmpdir/libchdb.so" "$tmpdir/libchdb.${ext}"
    fi

    local libfile="$tmpdir/libchdb.${ext}"
    if [ ! -f "$libfile" ]; then
        echo "❌ Library not found in downloaded archive (expected libchdb.${ext})"
        rm -rf "$tmpdir"
        exit 1
    fi

    mkdir -p .local/lib .local/include .local/lib/pkgconfig
    cp "$libfile" .local/lib/
    [ -f "$tmpdir/chdb.h" ] && cp "$tmpdir/chdb.h" .local/include/

    # Fix install name to absolute path — no rpath needed at runtime
    if [ "$OS" = "macos" ]; then
        install_name_tool -id "${prefix}/lib/libchdb.dylib" .local/lib/libchdb.dylib
    fi

    # Write pkg-config file
    local prefix="${PWD}/.local"
    cat > .local/lib/pkgconfig/chdb.pc << EOF
prefix=${prefix}
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: chdb
Description: chDB embedded OLAP SQL engine
Version: ${CHDB_VERSION}
Libs: -L\${libdir} -lchdb
Cflags: -I\${includedir}
EOF

    rm -rf "$tmpdir"
    echo "✅ ${variant} dynamic → .local/lib/libchdb.${ext} ($(ls -lh ".local/lib/libchdb.${ext}" | awk '{print $5}'))"
}

# ──────────────────────────────────────────────
# Linux — install libchdb.so system-wide + pkg-config
# ──────────────────────────────────────────────

install_linux() {
    if [ ! -f libchdb.so ]; then
        echo "📥 libchdb.so not found locally, downloading first..."
        download_current
    fi
    local prefix="/usr/local"
    echo "📦 Installing libchdb.so → ${prefix}/lib/ ..."
    sudo mkdir -p "${prefix}/lib" "${prefix}/include" "${prefix}/lib/pkgconfig"
    sudo cp libchdb.so "${prefix}/lib/"
    [ -f chdb.h ] && sudo cp chdb.h "${prefix}/include/"
    sudo tee "${prefix}/lib/pkgconfig/chdb.pc" > /dev/null << EOF
prefix=${prefix}
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: chdb
Description: chDB embedded OLAP SQL engine
Version: ${CHDB_VERSION}
Libs: -L\${libdir} -lchdb
Cflags: -I\${includedir}
EOF
    echo "✅ chDB installed system-wide (${prefix}/lib/libchdb.so)"
    echo "   pkg-config: ${prefix}/lib/pkgconfig/chdb.pc"
    echo ""
    echo "Verify with: pkg-config --libs --cflags chdb"
}

# ──────────────────────────────────────────────
# macOS — install libchdb.dylib system-wide + pkg-config (dynamic library)
# ──────────────────────────────────────────────

install_macos_dynamic() {
    local variant="macos-${ARCH}"
    echo "📥 Downloading dynamic library for ${variant}..."
    local url="https://github.com/chdb-io/chdb-core/releases/download/v${CHDB_VERSION}/${variant}-libchdb.tar.gz"
    local tmpdir="/tmp/chdb-dynamic"
    rm -rf "$tmpdir"
    mkdir -p "$tmpdir"
    curl -fsSL "$url" -o "/tmp/chdb-dynamic.tar.gz"
    tar xzf "/tmp/chdb-dynamic.tar.gz" -C "$tmpdir"
    rm -f "/tmp/chdb-dynamic.tar.gz"

    # Rename .so to .dylib (macOS convention)
    if [ -f "$tmpdir/libchdb.so" ]; then
        mv "$tmpdir/libchdb.so" "$tmpdir/libchdb.dylib"
    fi

    local prefix="/usr/local"
    echo "📦 Installing libchdb.dylib → ${prefix}/lib/ ..."
    sudo mkdir -p "${prefix}/lib" "${prefix}/include" "${prefix}/lib/pkgconfig"
    sudo cp "$tmpdir/libchdb.dylib" "${prefix}/lib/"
    [ -f "$tmpdir/chdb.h" ] && sudo cp "$tmpdir/chdb.h" "${prefix}/include/"
    sudo tee "${prefix}/lib/pkgconfig/chdb.pc" > /dev/null << EOF
prefix=${prefix}
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: chdb
Description: chDB embedded OLAP SQL engine
Version: ${CHDB_VERSION}
Libs: -L\${libdir} -lchdb
Cflags: -I\${includedir}
EOF
    sudo install_name_tool -id "${prefix}/lib/libchdb.dylib" "${prefix}/lib/libchdb.dylib" 2>/dev/null || true
    rm -rf "$tmpdir"
    echo "✅ chDB dynamic library installed (${prefix}/lib/libchdb.dylib)"
    echo "   pkg-config: ${prefix}/lib/pkgconfig/chdb.pc"
    echo ""
    echo "Use with: swift build -Xswiftc -I${prefix}/include -Xlinker -L${prefix}/lib"
    echo "Or via pkg-config: swift build -Xswiftc \$(pkg-config --cflags chdb) -Xlinker \$(pkg-config --libs chdb)"
}

download_dataset() {
    local file="hits.parquet"
    [ -f "$file" ] && echo "📄 $file already exists ($(ls -lh "$file" | awk '{print $5}'))" && return
    echo "📥 Downloading ClickBench dataset (100K rows, ~8 MB)..."
    curl -fsSL "https://datasets.clickhouse.com/hits/parquet/hits.parquet" -o "$file" && { echo "✅ $file ($(ls -lh "$file" | awk '{print $5}'))"; return; }
    echo "❌ Could not download. Use: swift run chdb-clickbench --parquet-path /path/to/hits.parquet"
}

# ──────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────

case "${1:-auto}" in
    auto|--current)          download_current ;;
    --current-dynamic|--dynamic) download_current_dynamic ;;
    --dataset|dataset)       download_dataset ;;
    --all|all)               download_current; download_dataset ;;
    --build-bundle)          build_artifactbundle ;;
    --install)               if [ "$OS" = "linux" ]; then install_linux; elif [ "$OS" = "macos" ]; then install_macos_dynamic; else echo "Unsupported OS: $OS"; fi ;;
    --install-dynamic)       install_macos_dynamic ;;
    *) echo "Usage: $0 [--current|--current-dynamic|--dataset|--all|--build-bundle|--install|--install-dynamic]"; exit 1 ;;
esac
