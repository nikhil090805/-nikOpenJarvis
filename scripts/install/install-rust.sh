#!/usr/bin/env bash
# install-rust.sh — install the pinned Rust toolchain via rustup if cargo is
# absent (Linux / macOS / WSL2 background install path).
#
# Idempotent: exits 0 immediately if cargo is on PATH, so an already installed
# toolchain is never re-downloaded. The fully qualified version and the
# minimal profile match rust/rust-toolchain.toml and rust/Cargo.toml; a
# two-part "1.90" would be a DIFFERENT rustup toolchain name from "1.90.0".

set -euo pipefail

PINNED_RUST_VERSION="1.90.0"
# Prevent rustup proxies from silently installing toolchains/components.
export RUSTUP_AUTO_INSTALL=0

if command -v cargo >/dev/null 2>&1; then
    echo "install-rust.sh: cargo already present, skipping (no download)"
    exit 0
fi

echo "install-rust.sh: installing Rust ${PINNED_RUST_VERSION} (minimal profile)..."
if command -v rustup >/dev/null 2>&1; then
    rustup toolchain install "${PINNED_RUST_VERSION}" --profile minimal --no-self-update
    rustup default "${PINNED_RUST_VERSION}"
else
    # Bootstrap rustup itself. rustup does not publish a verifiable standalone
    # checksum for rustup-init, so this is an explicit, documented limitation
    # of the POSIX path. Native Windows uses deploy/windows/install.ps1, which
    # never pipes a remote script into a shell.
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --profile minimal --default-toolchain "${PINNED_RUST_VERSION}"
fi

if [[ -d "$HOME/.cargo/bin" ]]; then
    export PATH="$HOME/.cargo/bin:$PATH"
fi

if ! command -v cargo >/dev/null 2>&1; then
    echo "install-rust.sh: cargo still not on PATH after install; check rustup output" >&2
    exit 1
fi
