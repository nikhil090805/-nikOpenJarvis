"""Static regression guards for the Windows/Rustup remediation.

These checks are platform-independent so they run on Linux/macOS CI too. The
real PowerShell parser + mocked runtime harness lives in
``tests/install/windows/Assert-WindowsInstaller.ps1`` and runs on Windows CI.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest
import tomllib

ROOT = Path(__file__).resolve().parents[2]
INSTALL_PS1 = ROOT / "deploy" / "windows" / "install.ps1"
SERVICE_PS1 = ROOT / "deploy" / "windows" / "jarvis-service.ps1"
TOOLCHAIN_TOML = ROOT / "rust" / "rust-toolchain.toml"
WORKSPACE_CARGO = ROOT / "rust" / "Cargo.toml"
CRATE_PYPROJECT = ROOT / "rust" / "crates" / "openjarvis-python" / "pyproject.toml"
UV_LOCK = ROOT / "uv.lock"
QUICKSTART = ROOT / "scripts" / "quickstart.sh"
INSTALL_RUST = ROOT / "scripts" / "install" / "install-rust.sh"
BUILD_EXTENSION = ROOT / "scripts" / "install" / "build-extension.sh"
DOCKER_DIR = ROOT / "deploy" / "docker"


def _locked_maturin_version() -> str:
    text = UV_LOCK.read_text()
    match = re.search(r'\[\[package\]\]\nname = "maturin"\nversion = "([^"]+)"', text)
    assert match, "uv.lock must contain a locked maturin version"
    return match.group(1)


# ---------------------------------------------------------------------------
# Rust toolchain pin
# ---------------------------------------------------------------------------


def test_toolchain_pin_is_fully_qualified_minimal_and_dev_free() -> None:
    data = tomllib.loads(TOOLCHAIN_TOML.read_text())
    toolchain = data["toolchain"]
    assert toolchain["channel"] == "1.90.0"
    assert toolchain["profile"] == "minimal"
    assert "components" not in toolchain, "no rustfmt/clippy in runtime installs"
    assert "targets" not in toolchain, "no Windows-only target on Linux/macOS"
    assert not (ROOT / "rust-toolchain.toml").exists(), "no root-level toolchain file"
    assert not (ROOT / "rust-toolchain").exists(), "no root-level toolchain file"


def test_workspace_msrv_matches_toolchain_pin() -> None:
    data = tomllib.loads(WORKSPACE_CARGO.read_text())
    assert data["workspace"]["package"]["rust-version"] == "1.90.0"


def test_maturin_build_backend_matches_lockfile() -> None:
    data = tomllib.loads(CRATE_PYPROJECT.read_text())
    requires = data["build-system"]["requires"]
    assert requires == [f"maturin=={_locked_maturin_version()}"], (
        "the local Rust extension must build with the locked maturin version"
    )


# ---------------------------------------------------------------------------
# Windows installer
# ---------------------------------------------------------------------------


def test_installer_targets_this_fork() -> None:
    text = INSTALL_PS1.read_text()
    assert "https://github.com/nikhil090805/-nikOpenJarvis.git" in text
    assert "'https://github.com/open-jarvis/OpenJarvis.git'" not in text


def test_installer_uses_explicit_pinned_minimal_rust() -> None:
    text = INSTALL_PS1.read_text()
    for token in (
        "PinnedRustVersion = '1.90.0'",
        "RUSTUP_AUTO_INSTALL",
        "RUSTUP_TOOLCHAIN",
        "--profile minimal",
        "--no-self-update",
        "x86_64-pc-windows-msvc",
        "Assert-RustToolchain",
        "Test-PinnedRustToolchain",
        "Assert-RustTarget",
        "Test-WindowsSdk",
    ):
        assert token in text, f"install.ps1 missing {token!r}"


def test_installer_builds_and_verifies_native_extension() -> None:
    text = INSTALL_PS1.read_text()
    assert "uv sync --locked --extra desktop --group desktop-native" in text
    assert "import openjarvis_rust" in text
    assert "maturin will bootstrap a Rust" not in text


def test_installer_supply_chain_verification() -> None:
    text = INSTALL_PS1.read_text()
    for token in (
        "Get-FileHash",
        ".sha256",
        "Get-AuthenticodeSignature",
        "[guid]::NewGuid()",
        "Expand-Archive",
        "Install-WithWinget -WingetId 'astral-sh.uv'",
        "Install-WithWinget -WingetId 'Ollama.Ollama'",
    ):
        assert token in text, f"install.ps1 missing {token!r}"
    assert "Invoke-RestMethod -Uri 'https://astral.sh/uv/install.ps1'" not in text
    assert "Join-Path $env:TEMP 'OllamaSetup.exe'" not in text
    assert "ExecutionPolicy Bypass" not in text
    assert "irm https://open-jarvis.github.io/OpenJarvis/install.ps1 | iex" not in text


def test_installer_has_no_hardcoded_hash_or_secret() -> None:
    text = INSTALL_PS1.read_text()
    assert not re.search(r"\b[0-9a-fA-F]{64}\b", text), "no unverified hardcoded hash"
    for marker in ("api_key=", "API_KEY='", "password=", "ConvertTo-SecureString $"):
        assert marker not in text, f"possible secret in installer: {marker!r}"


def test_installer_handles_existing_checkout_safely() -> None:
    text = INSTALL_PS1.read_text()
    assert "Get-CheckoutOrigin" in text
    assert "Assert-CheckoutMatchesRepo" in text
    assert "status --porcelain" in text
    assert "pull --ff-only" in text
    # tests/install/test_version_history.py extracts the shipped clone branch.
    start = text.index("    if ($repoUrl -like 'file://*'")
    end = text.index("    if ($LASTEXITCODE", start)
    snippet = text[start:end]
    assert snippet.count("{") == snippet.count("}"), "clone branch must stay balanced"
    assert "--filter=blob:none" in snippet


def test_installer_never_bypasses_defender() -> None:
    text = INSTALL_PS1.read_text()
    lowered = text.lower()
    # Prose explaining what NOT to do is expected; actual bypass cmdlets are not.
    for forbidden in (
        "add-mppreference",
        "set-mppreference",
        "-exclusionpath",
        "-exclusionextension",
        "disable-mppreference",
        "restore-mpthreat",
    ):
        assert forbidden not in lowered, f"Defender bypass cmdlet present: {forbidden}"
    assert "do not restore" in lowered
    assert "never restore" in lowered or "never" in lowered


# ---------------------------------------------------------------------------
# Scheduled-task service
# ---------------------------------------------------------------------------


def test_service_validates_arguments_and_never_persists_plaintext_key() -> None:
    text = SERVICE_PS1.read_text()
    for token in (
        "ValidateRange(1, 65535)",
        "ValidatePattern(",
        "Resolve-ListenHost",
        "Test-LoopbackHost",
        "Assert-SafePath",
        "ConvertFrom-SecureString",
        "ConvertTo-SecureString",
        "RunLevel Limited",
        "LogonType Interactive",
    ):
        assert token in text, f"jarvis-service.ps1 missing {token!r}"
    assert "SetEnvironmentVariable(" not in text
    assert "ExecutionPolicy Bypass" not in text
    assert "OPENJARVIS_API_KEY" in text  # requirement is preserved


def test_service_keeps_all_subcommands() -> None:
    text = SERVICE_PS1.read_text()
    for command in ("install", "uninstall", "status", "start", "stop"):
        assert f"'{command}'" in text


# ---------------------------------------------------------------------------
# Other install paths
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("path", [QUICKSTART, INSTALL_RUST, BUILD_EXTENSION])
def test_posix_scripts_disable_proxy_auto_install(path: Path) -> None:
    text = path.read_text()
    assert "RUSTUP_AUTO_INSTALL=0" in text
    assert "1.90.0" in text


def test_install_rust_does_not_install_floating_stable() -> None:
    text = INSTALL_RUST.read_text()
    assert "--default-toolchain stable" not in text
    assert "--profile minimal" in text
    assert "rustup default" in text


def test_quickstart_avoids_toolchain_file_probe() -> None:
    text = QUICKSTART.read_text()
    assert 'cd "$REPO_ROOT/rust" && rustc --version' not in text
    assert "export RUSTUP_TOOLCHAIN" in text
    assert "--no-self-update" in text


def test_build_extension_uses_locked_maturin_and_pinned_toolchain() -> None:
    text = BUILD_EXTENSION.read_text()
    assert 'uvx --from "maturin==${MATURIN_VERSION}"' in text
    assert "uv.lock" in text
    assert 'RUSTUP_TOOLCHAIN="1.90.0"' in text


@pytest.mark.parametrize(
    "name",
    ["Dockerfile", "Dockerfile.gpu", "Dockerfile.gpu.rocm", "Dockerfile.sandbox"],
)
def test_dockerfiles_use_pinned_toolchain_and_maturin(name: str) -> None:
    text = (DOCKER_DIR / name).read_text()
    assert "rustup toolchain install 1.90.0 --profile minimal" in text
    assert "rustup default 1.90.0" in text
    assert "ENV RUSTUP_AUTO_INSTALL=0" in text
    assert "ENV RUSTUP_TOOLCHAIN=1.90.0" in text
    assert f'"maturin=={_locked_maturin_version()}"' in text


def test_ci_uses_pinned_toolchain_and_dev_components_only_in_lint_job() -> None:
    ci = (ROOT / ".github" / "workflows" / "ci.yml").read_text()
    desktop = (ROOT / ".github" / "workflows" / "desktop.yml").read_text()
    assert "dtolnay/rust-toolchain@stable" not in ci
    assert "dtolnay/rust-toolchain@stable" not in desktop
    assert ci.count("rustup toolchain install 1.90.0 --profile minimal") >= 2
    assert "rustup component add rustfmt clippy --toolchain 1.90.0" in ci
    assert 'RUSTUP_AUTO_INSTALL: "0"' in ci
    assert 'RUSTUP_AUTO_INSTALL: "0"' in desktop
    # Intentional ARM64 x64-emulation override is preserved.
    assert "RUSTUP_TOOLCHAIN: stable" in desktop
    assert "rustup target add --toolchain stable x86_64-pc-windows-msvc" in desktop


def test_windows_ci_job_exists_and_is_labelled() -> None:
    text = (ROOT / ".github" / "workflows" / "installer-integration.yml").read_text()
    assert "windows-x64" in text
    assert "windows-latest" in text
    assert "Assert-WindowsInstaller.ps1" in text
    assert "MOCKED" in text
    assert "import openjarvis_rust" in text


# ---------------------------------------------------------------------------
# PowerShell parse hazards
# ---------------------------------------------------------------------------

# Valid PowerShell scope prefixes: "$env:Path", "$script:Name", ...
PS_SCOPES = {
    "env",
    "script",
    "global",
    "local",
    "private",
    "using",
    "variable",
    "function",
    "workflow",
}


def _interpolating_code_lines(path: Path) -> list[tuple[int, str]]:
    """Yield (line number, code) for lines where PowerShell interpolates.

    Full-line and trailing ``#`` comments are dropped (a comment can safely
    contain the pattern), single-quoted strings are dropped (they never
    interpolate), and ``@'...'@`` literal here-strings are skipped while
    ``@"..."@`` interpolating here-strings are kept.
    """
    result: list[tuple[int, str]] = []
    here: str | None = None
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        stripped = raw.strip()
        if here == "literal":
            if stripped == "'@":
                here = None
            continue
        if here == "expand":
            if stripped == '"@':
                here = None
                continue
            result.append((number, raw))
            continue
        if stripped.startswith("@'") and len(stripped) <= 3:
            here = "literal"
            continue
        if stripped.startswith('@"') and len(stripped) <= 3:
            here = "expand"
            continue
        # Strip a trailing comment that is not inside a quoted string.
        out: list[str] = []
        quote: str | None = None
        index = 0
        while index < len(raw):
            char = raw[index]
            if quote:
                out.append(char)
                if char == "`" and quote == '"' and index + 1 < len(raw):
                    out.append(raw[index + 1])
                    index += 2
                    continue
                if char == quote:
                    quote = None
            else:
                if char in "'\"":
                    quote = char
                    out.append(char)
                elif char == "#":
                    break
                else:
                    out.append(char)
            index += 1
        code = "".join(out)
        if code.strip():
            result.append((number, code))
    return result


def test_powershell_files_have_no_drive_qualified_variable_interpolation() -> None:
    """`"$name: ..."` is a parse error, not a string.

    PowerShell reads ``$name:`` as a drive-qualified variable reference and
    fails the WHOLE script with ``InvalidVariableReferenceWithDrive``. That
    exact bug shipped once (``"Refusing to update $srcDir: ..."``) and broke
    every Windows prerequisite test plus the mocked installer harness. The
    fix is to brace the variable: ``"${name}: ..."``.
    """
    pattern = re.compile(r"(?<!`)\$([A-Za-z_][A-Za-z0-9_]*):")
    offenders: list[str] = []
    for path in sorted(ROOT.rglob("*.ps1")):
        if "node_modules" in path.parts:
            continue
        for number, code in _interpolating_code_lines(path):
            for match in pattern.finditer(code):
                if match.group(1).lower() in PS_SCOPES:
                    continue
                offenders.append(f"{path.relative_to(ROOT)}:{number}: {code.strip()}")
    assert not offenders, (
        "PowerShell drive-qualified variable interpolation (brace it, e.g. "
        "${name}):\n" + "\n".join(offenders)
    )


def test_windows_ci_runs_the_real_installer_and_publishes_the_nsis_installer() -> None:
    text = (ROOT / ".github" / "workflows" / "installer-integration.yml").read_text()
    # The real installer must run on the Windows runner, twice, for idempotency.
    assert text.count("& $installer -SourceDir") == 2
    assert "Second run re-downloaded the Rust toolchain" in text
    # The generated NSIS installer is asserted and uploaded, not assumed.
    assert "npx tauri build --bundles nsis" in text
    assert "OpenJarvis-Windows-x64-NSIS" in text
    assert "Get-FileHash -Algorithm SHA256" in text
    # Backend health is verified with a mocked Ollama API, and the mocking is
    # labelled so it is never mistaken for a live model-provider test.
    assert "Ollama HTTP API mocked" in text
    assert "http://127.0.0.1:8000/health" in text


def test_installer_toolchain_health_regex_matches_the_pinned_version() -> None:
    """The health probe compares rustc's output with a regex pin.

    A version bump that only changed ``$script:PinnedRustVersion`` left
    ``-match '1\\.89\\.0'`` behind: every run then treated a perfectly healthy
    toolchain as broken, attempted a repair install and failed. Keep the
    escaped regexes derived from the pin, not duplicated by hand.
    """
    pin = tomllib.loads(TOOLCHAIN_TOML.read_text())["toolchain"]["channel"]
    escaped = pin.replace(".", r"\.")
    text = INSTALL_PS1.read_text()
    assert f"-match '{escaped}'" in text, f"rustc probe regex must match {pin}"
    assert f"-match '^{escaped}'" in text, f"toolchain-list regex must match {pin}"


def test_no_stale_escaped_or_plain_rust_version_pins() -> None:
    """Catch every quoting form of a stale pin (``1.89`` and ``1\\.89``)."""
    pin = tomllib.loads(TOOLCHAIN_TOML.read_text())["toolchain"]["channel"]
    major_minor = ".".join(pin.split(".")[:2])
    # Match any minor version in either quoting form: "1.90", "1\\.90".
    any_pin = re.compile(r"(?<![\d.])1\\\\?\.([89]\\d)")
    scanned = [
        *sorted((ROOT / "deploy").rglob("*.ps1")),
        *sorted((ROOT / "deploy" / "docker").glob("Dockerfile*")),
        *sorted((ROOT / "scripts").rglob("*.sh")),
        *sorted((ROOT / ".github" / "workflows").glob("*.yml")),
        *sorted((ROOT / "tests" / "install").rglob("*.ps1")),
        *sorted((ROOT / "tests" / "install").rglob("*.bats")),
        ROOT / "Makefile",
        ROOT / "frontend" / "src-tauri" / "src" / "lib.rs",
        TOOLCHAIN_TOML,
        WORKSPACE_CARGO,
        ROOT / "frontend" / "src-tauri" / "Cargo.toml",
    ]
    offenders = []
    for path in scanned:
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            for match in any_pin.finditer(line):
                if f"1.{match.group(1)}" == major_minor:
                    continue
                offenders.append(f"{path.relative_to(ROOT)}:{number}: {line.strip()}")
    assert not offenders, (
        f"stale Rust pin ({major_minor}) next to the {pin} pin:\n"
        + "\n".join(offenders)
    )
