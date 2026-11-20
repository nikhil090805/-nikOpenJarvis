#!/usr/bin/env bats

setup() {
    TEST_TMPDIR=$(mktemp -d)
    export STUBS_DIR="$BATS_TEST_DIRNAME/stubs"
    export STUBS_NO_CARGO="$TEST_TMPDIR/stubs-no-cargo"
    mkdir -p "$STUBS_NO_CARGO"
    # Copy all stubs except cargo into the no-cargo dir.
    for s in "$STUBS_DIR"/*; do
        name=$(basename "$s")
        if [[ "$name" != "cargo" ]]; then
            cp "$s" "$STUBS_NO_CARGO/"
        fi
    done
    export RUSTUP_STUB_LOG="$TEST_TMPDIR/rustup.log"
    export CURL_STUB_LOG="$TEST_TMPDIR/curl.log"
    : > "$RUSTUP_STUB_LOG"
    : > "$CURL_STUB_LOG"
    export SCRIPT="$BATS_TEST_DIRNAME/../../../scripts/install/install-rust.sh"
}

teardown() {
    [[ -n "${TEST_TMPDIR:-}" ]] && rm -rf "$TEST_TMPDIR"
}

@test "skips install when cargo already present" {
    PATH="$STUBS_DIR:$PATH" run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -s "$CURL_STUB_LOG" ]
}

@test "installs the pinned minimal toolchain when cargo is missing" {
    # Hermetic HOME. install-rust.sh prepends "$HOME/.cargo/bin" to PATH after
    # calling rustup, exactly as rustup's own installer would. A GitHub-hosted
    # (or developer) machine already has the real cargo there, so without a
    # private HOME this assertion depended on the machine running the test:
    # it passed locally and failed in CI. The script behaviour is correct; the
    # test setup was not isolated.
    export HOME="$TEST_TMPDIR/home"
    mkdir -p "$HOME"
    PATH="$STUBS_NO_CARGO:/usr/bin:/bin:/usr/local/bin" run bash "$SCRIPT"
    # The rustup stub does not actually provide cargo, so the script must
    # report the still-missing prerequisite instead of claiming success.
    [ "$status" -eq 1 ]
    grep -q "toolchain install 1.90.0 --profile minimal --no-self-update" "$RUSTUP_STUB_LOG"
    grep -q "default 1.90.0" "$RUSTUP_STUB_LOG"
    # An existing rustup must NOT fall back to an unpinned curl-pipe-bash.
    [ ! -s "$CURL_STUB_LOG" ]
}

@test "succeeds when rustup installs cargo into ~/.cargo/bin" {
    # Companion to the test above: with a rustup that really provides cargo in
    # "$HOME/.cargo/bin", the same code path must report success instead of a
    # false failure, and still must not download an unpinned installer.
    export HOME="$TEST_TMPDIR/home"
    mkdir -p "$HOME/.cargo/bin"
    local rustup_dir="$TEST_TMPDIR/rustup-bin"
    mkdir -p "$rustup_dir"
    cat > "$rustup_dir/rustup" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "\$RUSTUP_STUB_LOG"
if [[ "\$1" == "toolchain" && "\$2" == "install" ]]; then
    printf '#!/usr/bin/env bash\nexit 0\n' > "\$HOME/.cargo/bin/cargo"
    chmod +x "\$HOME/.cargo/bin/cargo"
fi
exit 0
EOF
    chmod +x "$rustup_dir/rustup"
    PATH="$rustup_dir:/usr/bin:/bin:/usr/local/bin" run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -x "$HOME/.cargo/bin/cargo" ]
    grep -q "toolchain install 1.90.0 --profile minimal --no-self-update" "$RUSTUP_STUB_LOG"
    grep -q "default 1.90.0" "$RUSTUP_STUB_LOG"
    [ ! -s "$CURL_STUB_LOG" ]
}
