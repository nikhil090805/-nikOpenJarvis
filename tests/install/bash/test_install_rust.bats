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
    PATH="$STUBS_NO_CARGO:/usr/bin:/bin:/usr/local/bin" run bash "$SCRIPT"
    # The rustup stub does not actually provide cargo, so the script must
    # report the still-missing prerequisite instead of claiming success.
    [ "$status" -eq 1 ]
    grep -q "toolchain install 1.89.0 --profile minimal --no-self-update" "$RUSTUP_STUB_LOG"
    grep -q "default 1.89.0" "$RUSTUP_STUB_LOG"
    # An existing rustup must NOT fall back to an unpinned curl-pipe-bash.
    [ ! -s "$CURL_STUB_LOG" ]
}
