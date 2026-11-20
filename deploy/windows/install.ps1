<#
.SYNOPSIS
    OpenJarvis native Windows installer.

.DESCRIPTION
    Phase-1 of the native-Windows-support RFC (#298). Mirrors the
    behavior of scripts/install/install.sh (the curl-pipe-bash installer
    for Linux/WSL2/macOS) but for native Windows PowerShell - no WSL,
    no Docker, no MSYS2.

    Steps:
      1.  Refuse non-Windows / Windows < 10.
      2.  Check Python 3.11 - 3.13 on PATH (3.14 has no numpy wheels yet,
          see #432).
      3.  Check git on PATH.
      4.  Install uv via winget, or a SHA-256-verified pinned uv release.
      5.  Clone THIS FORK (nikhil090805/-nikOpenJarvis) to
          $env:LOCALAPPDATA\OpenJarvis, or reuse -SourceDir. Existing
          checkouts are verified, never blindly pulled or overwritten.
      5b. Check the MSVC linker and Windows SDK.
      5c. Install/verify the pinned Rust 1.90.0 toolchain with --profile
          minimal and the x86_64-pc-windows-msvc target, with Rustup proxy
          auto-installation disabled.
      6.  Run `uv sync --locked --extra desktop --group desktop-native` and
          verify that `openjarvis_rust` actually imports.
      7.  Install/verify Ollama and a starter model.
      8.  Optionally register the scheduled-task service (see
          deploy/windows/jarvis-service.ps1).

    Usage (verified, recommended - no remote script piped into PowerShell):
      git clone https://github.com/nikhil090805/-nikOpenJarvis.git
      cd .\-nikOpenJarvis
      powershell -ExecutionPolicy RemoteSigned -File .\deploy\windows\install.ps1 -SkipService

    The same script is published on the project docs site, but fork users
    should run the copy from their own checkout so the installer and the
    source tree always agree.

    Flags (when running the file directly):
      -SkipService    Don't prompt for / install the scheduled task.
      -Service        Install the scheduled task without prompting.
      -Force          Re-run all steps even if already done.
      -SourceDir      Use an existing checkout instead of cloning; its
                      origin must match the selected repository.

    The same knobs are honored via env vars when the corresponding flag is
    absent (useful in non-interactive shells):
      $env:OPENJARVIS_SKIP_SERVICE = '1'
      $env:OPENJARVIS_SERVICE      = '1'
      $env:OPENJARVIS_FORCE        = '1'
      $env:OPENJARVIS_REPO_URL     = 'https://github.com/nikhil090805/-nikOpenJarvis.git'

.NOTES
    Loopback default: the scheduled-task service binds 127.0.0.1, so no
    API key is needed. For LAN exposure the service now stores the key in a
    DPAPI-protected file instead of a plaintext user environment variable;
    see deploy/windows/README.md.

    If Windows Defender quarantines a file in %USERPROFILE%\.rustup\downloads,
    this installer FAILS SAFELY with investigation instructions. It never
    restores quarantined files, adds exclusions, or disables Defender.
#>

[CmdletBinding()]
param(
    [switch] $SkipService,
    [switch] $Service,
    [switch] $Force,
    [string] $SourceDir
)

$ErrorActionPreference = 'Stop'

# Pinned, fully qualified toolchain. Keep in sync with rust/rust-toolchain.toml
# and rust/Cargo.toml. A two-part name ("1.90") is a DIFFERENT rustup
# toolchain from "1.90.0" and caused repeated six-component downloads.
$script:PinnedRustVersion = '1.90.0'
$script:RustHostTarget    = 'x86_64-pc-windows-msvc'
# This fork, not upstream. Override with $env:OPENJARVIS_REPO_URL.
$script:DefaultRepoUrl    = 'https://github.com/nikhil090805/-nikOpenJarvis.git'
# Pinned uv release used only when winget is unavailable. Astral publishes a
# .sha256 sidecar next to each release asset; no hash is hardcoded here.
$script:UvVersion         = '0.13.9'

# Prevent rustup proxies from silently installing a toolchain (and its
# components) during `uv sync`, `cargo --version` probes, etc. All installs
# below are explicit and use --profile minimal.
$env:RUSTUP_AUTO_INSTALL = '0'

# Env-var fallback for non-interactive invocations. Any explicit -switch
# wins; env vars only fill in the gaps.
if (-not $SkipService -and $env:OPENJARVIS_SKIP_SERVICE) { $SkipService = $true }
if (-not $Service     -and $env:OPENJARVIS_SERVICE)      { $Service     = $true }
if (-not $Force       -and $env:OPENJARVIS_FORCE)        { $Force       = $true }

# ---------------------------------------------------------------------------
# Output helpers - coloured but plain enough for Constrained Language Mode.
# ---------------------------------------------------------------------------

function Write-Info  ($msg) { Write-Host "[info]  $msg" -ForegroundColor Cyan }
function Write-Ok    ($msg) { Write-Host "[ok]    $msg" -ForegroundColor Green }
function Write-Warn2 ($msg) { Write-Host "[warn]  $msg" -ForegroundColor Yellow }
function Write-Fail  ($msg) {
    Write-Host "[fail]  $msg" -ForegroundColor Red
    # A terminating error aborts this installer while returning control to an
    # existing interactive PowerShell. `exit` would close the entire host when
    # the documented `irm ... | iex` command is run in a terminal (#868).
    throw [System.InvalidOperationException]::new([string] $msg)
}

# ---------------------------------------------------------------------------
# Shared helpers - winget bootstrap + PATH refresh
# ---------------------------------------------------------------------------

# Pull the latest Machine + User PATH from the registry into the current
# PowerShell session. Tools installed by `winget install` (Python, git,
# Ollama, etc.) update the User PATH, but the running process inherits
# the parent shell's environment - so without this refresh the just-
# installed tool stays invisible to subsequent `Get-Command` calls.
#
# CRITICAL: registry PATH entries can be REG_EXPAND_SZ (with literal
# `%VAR%` placeholders); the Python.org installer in per-user mode adds
# entries like `%LOCALAPPDATA%\Programs\Python\Python313\` unexpanded.
# `GetEnvironmentVariable` returns the raw string and PowerShell does
# NOT auto-expand on assignment to `$env:Path`, so `Get-Command python`
# would miss the just-installed binary. Expand explicitly.
function Update-PathFromRegistry {
    $machinePath = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath    = [System.Environment]::GetEnvironmentVariable('Path', 'User')
    $combined    = "$machinePath;$userPath"
    $env:Path = [System.Environment]::ExpandEnvironmentVariables($combined)
}

# Bootstrap a tool by winget id. Returns the resolved command source on
# success, $null on failure. Caller decides whether failure is fatal.
function Install-WithWinget {
    param(
        [string] $WingetId,    # e.g. 'Python.Python.3.13'
        [string] $CommandName  # e.g. 'python' or 'git'
    )
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        # Windows 10 pre-2004 / Windows Server / locked-down corporate
        # images may not have winget. Fall back to the caller's manual
        # instructions.
        return $null
    }
    Write-Info "  Installing $WingetId via winget (silent)..."
    & winget install --id $WingetId --silent --accept-source-agreements --accept-package-agreements 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warn2 "  winget install $WingetId exited $LASTEXITCODE"
        return $null
    }
    Update-PathFromRegistry
    $cmd = Get-Command $CommandName -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

# ---------------------------------------------------------------------------
# Shared helpers - verified downloads, repository and Rust toolchain
# ---------------------------------------------------------------------------

function Get-NormalizedRepoUrl {
    param([string] $Url)
    if (-not $Url) { return '' }
    $normalized = $Url.Trim().TrimEnd('/')
    if ($normalized.ToLowerInvariant().EndsWith('.git')) {
        $normalized = $normalized.Substring(0, $normalized.Length - 4)
    }
    return $normalized.ToLowerInvariant()
}

# Install uv from a PINNED GitHub release, verifying the archive against the
# publisher-maintained .sha256 sidecar fetched over TLS. No hash is hardcoded,
# no remote script is piped into PowerShell, and the temp directory is unique
# and always cleaned up.
function Install-UvFromVerifiedRelease {
    $asset = 'uv-x86_64-pc-windows-msvc.zip'
    $base = "https://github.com/astral-sh/uv/releases/download/$($script:UvVersion)"
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) `
        ('openjarvis-uv-' + [guid]::NewGuid().ToString('N'))
    $zipPath = Join-Path $tempDir $asset
    $sumPath = "$zipPath.sha256"
    try {
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        $prevProgress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try {
            Invoke-WebRequest -Uri "$base/$asset.sha256" -OutFile $sumPath -UseBasicParsing
            Invoke-WebRequest -Uri "$base/$asset" -OutFile $zipPath -UseBasicParsing
        } finally {
            $ProgressPreference = $prevProgress
        }
        if (-not (Test-Path -LiteralPath $sumPath -PathType Leaf) -or
            -not (Test-Path -LiteralPath $zipPath -PathType Leaf) -or
            (Get-Item -LiteralPath $zipPath).Length -eq 0) {
            Write-Warn2 '  uv release download was incomplete.'
            return $null
        }
        $expected = ((Get-Content -LiteralPath $sumPath -Raw).Trim() -split '\s+')[0]
        if ($expected -notmatch '^[0-9a-fA-F]{64}$') {
            Write-Warn2 '  uv release checksum sidecar is malformed; refusing to continue.'
            return $null
        }
        $actual = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected.ToLowerInvariant()) {
            Write-Warn2 '  uv release SHA-256 mismatch; refusing to run the downloaded binary.'
            return $null
        }
        Write-Info "  uv $($script:UvVersion) archive SHA-256 verified"
        Expand-Archive -LiteralPath $zipPath -DestinationPath $tempDir -Force
        $uvBin = Get-ChildItem -LiteralPath $tempDir -Filter 'uv.exe' -Recurse -File `
            -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $uvBin) {
            Write-Warn2 '  uv.exe not found in the verified archive.'
            return $null
        }
        $targetDir = Join-Path $env:USERPROFILE '.local\bin'
        if (-not (Test-Path -LiteralPath $targetDir)) {
            New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        }
        Copy-Item -LiteralPath $uvBin.FullName -Destination (Join-Path $targetDir 'uv.exe') -Force
        $uvxBin = Get-ChildItem -LiteralPath $tempDir -Filter 'uvx.exe' -Recurse -File `
            -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($uvxBin) {
            Copy-Item -LiteralPath $uvxBin.FullName -Destination (Join-Path $targetDir 'uvx.exe') -Force
        }
        $uvPath = Join-Path $targetDir 'uv.exe'
        & $uvPath --version | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warn2 '  The verified uv.exe failed to run.'
            return $null
        }
        return $uvPath
    } catch {
        Write-Warn2 "  Verified uv download failed: $($_.Exception.Message)"
        return $null
    } finally {
        if (Test-Path -LiteralPath $tempDir) {
            Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# Direct Ollama download is only a fallback when winget (which verifies
# installer SHA-256 from a maintained manifest) is unavailable. It requires a
# valid Authenticode signature from Ollama; if that cannot be verified we fail
# safely instead of executing an unverified installer.
function Install-OllamaFromVerifiedDownload {
    $setup = Join-Path ([System.IO.Path]::GetTempPath()) `
        ('OllamaSetup-' + [guid]::NewGuid().ToString('N') + '.exe')
    try {
        $prevProgress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try {
            Invoke-WebRequest -Uri 'https://ollama.com/download/OllamaSetup.exe' `
                -OutFile $setup -UseBasicParsing
        } finally {
            $ProgressPreference = $prevProgress
        }
        if (-not (Test-Path -LiteralPath $setup -PathType Leaf) -or
            (Get-Item -LiteralPath $setup).Length -eq 0) {
            Write-Warn2 '  Ollama download was incomplete.'
            return $false
        }
        $sig = Get-AuthenticodeSignature -LiteralPath $setup
        if ($sig.Status -ne 'Valid') {
            Write-Warn2 "  OllamaSetup.exe has no valid Authenticode signature ($($sig.Status))."
            return $false
        }
        $subject = $sig.SignerCertificate.Subject
        if ($subject -notmatch 'Ollama') {
            Write-Warn2 "  OllamaSetup.exe is signed by an unexpected publisher: $subject"
            return $false
        }
        Write-Info "  OllamaSetup.exe Authenticode verified ($subject)"
        $proc = Start-Process -FilePath $setup -ArgumentList '/S' -Wait -PassThru
        if ($proc.ExitCode -ne 0) {
            Write-Warn2 "  Ollama installer exited $($proc.ExitCode)."
            return $false
        }
        return $true
    } catch {
        Write-Warn2 "  Ollama download/verification failed: $($_.Exception.Message)"
        return $false
    } finally {
        if (Test-Path -LiteralPath $setup) {
            Remove-Item -LiteralPath $setup -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------------
# 1. OS check
# ---------------------------------------------------------------------------

Write-Info "Checking OS..."
if ($PSVersionTable.Platform -and $PSVersionTable.Platform -ne 'Win32NT') {
    Write-Fail "install.ps1 is for native Windows. On Linux/macOS use install.sh."
}

# Build number 17763 = Windows 10 1809 (the oldest LTS we test against).
$build = [System.Environment]::OSVersion.Version.Build
if ($build -lt 17763) {
    Write-Fail "Windows 10 1809 (build 17763) or newer is required. Detected build $build."
}
Write-Ok "Windows build $build"

# ---------------------------------------------------------------------------
# 2. Python check
# ---------------------------------------------------------------------------

function Get-PythonCommand {
    # A Store alias can point to installed Python or to the Store placeholder;
    # its zero-byte file size does not distinguish them. Probe with an argument
    # (which never opens the Store) and continue past failed/shadowing aliases.
    $seen = @{}
    foreach ($name in @('python', 'python3')) {
        foreach ($cmd in @(Get-Command $name -All -CommandType Application -ErrorAction SilentlyContinue)) {
            if (-not $cmd.Source -or $seen.ContainsKey($cmd.Source)) { continue }
            $seen[$cmd.Source] = $true
            try {
                $version = & $cmd.Source --version 2>$null
                $match = [regex]::Match(($version -join ' '), '^Python (\d+)\.(\d+)\.\d+')
                if ($LASTEXITCODE -eq 0 -and $match.Success -and
                    [int]$match.Groups[1].Value -eq 3 -and
                    [int]$match.Groups[2].Value -ge 11 -and
                    [int]$match.Groups[2].Value -le 13) {
                    return $cmd.Source
                }
            } catch {
                # PS 5.1 can turn a native stderr message into an exception.
            }
            Write-Warn2 "  Ignoring unavailable or unsupported Python at $($cmd.Source)"
        }
    }
    return $null
}

Write-Info "Checking Python (3.11 - 3.13)..."
$pythonExe = Get-PythonCommand
if (-not $pythonExe) {
    Write-Info "Python not on PATH - attempting auto-install via winget..."
    $null = Install-WithWinget -WingetId 'Python.Python.3.13' -CommandName 'python'
    # Refreshing PATH can still leave a failed Store alias ahead of python.org.
    $pythonExe = Get-PythonCommand
    if (-not $pythonExe) {
        Write-Fail @"
Python 3.11 - 3.13 not found and auto-install via winget failed.

Install manually from https://python.org (check 'Add python.exe to PATH'
during install) or via winget:

    winget install Python.Python.3.13

Then re-run this installer.
"@
    }
}

$verRaw = & $pythonExe --version 2>&1
$verMatch = [regex]::Match($verRaw, '(\d+)\.(\d+)\.(\d+)')
if (-not $verMatch.Success) {
    Write-Fail "Could not parse Python version from: $verRaw"
}
$pyMajor = [int]$verMatch.Groups[1].Value
$pyMinor = [int]$verMatch.Groups[2].Value
if ($pyMajor -ne 3 -or $pyMinor -lt 11 -or $pyMinor -gt 13) {
    Write-Fail @"
Found Python $pyMajor.$pyMinor at $pythonExe, but OpenJarvis requires
3.11 - 3.13. Python 3.14 has no numpy Windows wheels yet (#432, will
re-open once numpy ships cp314).
"@
}
Write-Ok "Python $pyMajor.$pyMinor ($pythonExe)"

# ---------------------------------------------------------------------------
# 3. git check
# ---------------------------------------------------------------------------

Write-Info "Checking git..."
$gitExe = (Get-Command git -ErrorAction SilentlyContinue).Source
if (-not $gitExe) {
    Write-Info "git not on PATH - attempting auto-install via winget..."
    $gitExe = Install-WithWinget -WingetId 'Git.Git' -CommandName 'git'
    if (-not $gitExe) {
        Write-Fail @"
git not found and auto-install via winget failed.

Install manually via winget:

    winget install Git.Git

or download from https://git-scm.com, then re-run this installer.
"@
    }
}
Write-Ok "git ($gitExe)"

# ---------------------------------------------------------------------------
# 4. uv check / install
# ---------------------------------------------------------------------------

Write-Info "Checking uv..."
Update-PathFromRegistry
$uvExe = (Get-Command uv -ErrorAction SilentlyContinue).Source
if (-not $uvExe) {
    # winget verifies the installer hash from a maintained package manifest.
    Write-Info "Installing uv via winget (hash-verified package manifest)..."
    $uvExe = Install-WithWinget -WingetId 'astral-sh.uv' -CommandName 'uv'
    if (-not $uvExe) {
        Write-Info "winget unavailable or failed - falling back to a SHA-256-verified uv release..."
        $uvExe = Install-UvFromVerifiedRelease
    }
    if (-not $uvExe) {
        Write-Fail @"
uv could not be installed or verified. Install it manually with one of:

    winget install --id astral-sh.uv -e

or download a signed archive from https://github.com/astral-sh/uv/releases,
verify its published .sha256, and re-run this installer. This script will
not execute an unverified remote installer.
"@
    }
}
Write-Ok "uv ($uvExe)"

# ---------------------------------------------------------------------------
# 5. Source checkout - this fork by default, existing checkouts are safe
# ---------------------------------------------------------------------------

$installRoot = if ($env:OPENJARVIS_HOME) {
    $env:OPENJARVIS_HOME
} else {
    Join-Path $env:LOCALAPPDATA 'OpenJarvis'
}
$srcDir = Join-Path $installRoot 'src'

Write-Info "Install root: $installRoot"

if (-not (Test-Path $installRoot)) {
    New-Item -ItemType Directory -Path $installRoot | Out-Null
}

$repoUrl = if ($env:OPENJARVIS_REPO_URL) {
    $env:OPENJARVIS_REPO_URL
} else {
    $script:DefaultRepoUrl
}
Write-Info "Source repo: $repoUrl"

# -SourceDir installs from an existing checkout of this fork without cloning
# again (handy when you already cloned it to run this script). Its origin is
# still checked so we never silently build upstream or an unrelated fork.
if ($SourceDir) {
    $candidate = (Resolve-Path -LiteralPath $SourceDir -ErrorAction SilentlyContinue).Path
    if (-not $candidate -or -not (Test-Path (Join-Path $candidate '.git'))) {
        Write-Fail "-SourceDir must point at a git checkout (no .git found at '$SourceDir')."
    }
    $srcDir = $candidate
}

function Get-CheckoutOrigin {
    param([string] $Path)
    $origin = & $gitExe -C $Path remote get-url origin 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return ($origin | Select-Object -First 1)
}

function Assert-CheckoutMatchesRepo {
    param([string] $Path, [string] $Expected)
    $origin = Get-CheckoutOrigin $Path
    if (-not $origin) {
        Write-Fail "Could not read 'origin' from the existing checkout at $Path."
    }
    if ((Get-NormalizedRepoUrl $origin) -ne (Get-NormalizedRepoUrl $Expected)) {
        Write-Fail @"
The existing checkout at $Path points at:
  $origin
but this installer is configured for:
  $Expected

Refusing to overwrite it. Use -SourceDir with the correct checkout, set
`$env:OPENJARVIS_REPO_URL explicitly, or move the old checkout aside first.
"@
    }
    Write-Ok "Existing checkout origin matches the selected repository"
}

if (Test-Path (Join-Path $srcDir '.git')) {
    # Idempotent re-run: verify BEFORE touching anything. Never `git pull`
    # over an existing checkout that belongs to a different repository or has
    # uncommitted user work.
    Assert-CheckoutMatchesRepo $srcDir $repoUrl
    if ($Force) {
        $dirty = @(& $gitExe -C $srcDir status --porcelain 2>$null)
        if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) {
            # ${srcDir} must stay braced: "$srcDir:" is parsed by PowerShell as
            # a drive-qualified variable reference (InvalidVariableReferenceWithDrive)
            # and makes the whole script fail to parse.
            Write-Fail "Refusing to update ${srcDir}: uncommitted changes present. Commit or stash them, then re-run with -Force."
        }
        Write-Info "Force: pulling latest from $repoUrl..."
        & $gitExe -C $srcDir pull --ff-only
        if ($LASTEXITCODE -ne 0) { Write-Fail "git pull failed" }
    } else {
        Write-Ok "Repository already cloned (use -Force to update)"
    }
} else {
    Write-Info "Cloning $repoUrl..."
    # Preserve history without partial-clone lazy fetches from local sources,
    # which may themselves be shallow. Remote sources can omit old blobs.
    if ($repoUrl -like 'file://*' -or (Test-Path -LiteralPath $repoUrl -ErrorAction SilentlyContinue)) {
        # A file:// URL still goes through git's upload-pack transport, which
        # refuses to serve a shallow source repository ("attempt to fetch/clone
        # from a shallow repository") and cannot satisfy a partial clone's lazy
        # fetches. Hand git the plain filesystem path instead, so a local source
        # (shallow or not, and with spaces or brackets in its path) always
        # clones through the local transport. Remote URLs are unaffected.
        $localSource = $repoUrl
        if ($repoUrl -like 'file://*') { $localSource = ([uri]$repoUrl).LocalPath }
        & $gitExe clone $localSource $srcDir
    } else {
        & $gitExe clone --filter=blob:none $repoUrl $srcDir
    }
    if ($LASTEXITCODE -ne 0) { Write-Fail "git clone failed" }
    Write-Ok "Cloned to $srcDir"
}

# ---------------------------------------------------------------------------
# 5b. MSVC build tools - required by the mandatory Rust extension
# ---------------------------------------------------------------------------

# `--group desktop-native` builds openjarvis-rust from source via maturin
# (pyproject.toml pins it to a local path; it is not published to PyPI), and
# src/openjarvis/_rust_bridge.py raises a hard ImportError when the module is
# missing - there is no pure-Python fallback.
#
# Rust provisioning, precisely: maturin itself just shells out to cargo/rustc,
# but its PEP 517 build backend pulls in `puccinialin`, which WILL download and
# run rustup-init into a temp dir when no cargo is found. That produces an
# unmanaged, unpinned toolchain and can trigger repeated component downloads.
# Step 5c therefore provides cargo/rustc through the pinned 1.90.0 minimal
# toolchain FIRST, then sets RUSTUP_TOOLCHAIN=1.90.0 and RUSTUP_AUTO_INSTALL=0,
# so neither rustup proxies nor the build backend bootstrap anything. The
# x86_64-pc-windows-msvc target also needs the MSVC linker, which no earlier
# step installs (#1060).
function Test-MsvcLinker {
    # Git/MSYS can put an unrelated GNU link.exe on PATH. Only Microsoft's
    # linker satisfies the native extension's MSVC prerequisite.
    foreach ($cmd in @(Get-Command link.exe -All -CommandType Application -ErrorAction SilentlyContinue)) {
        $item = Get-Item -LiteralPath $cmd.Source -ErrorAction SilentlyContinue
        if ($item -and $item.VersionInfo.CompanyName -match '^Microsoft' -and
            $item.VersionInfo.OriginalFilename -ieq 'link.exe') {
            return $true
        }
    }
    # link.exe is only on PATH inside a Developer Command Prompt, so probe
    # the install root via vswhere (shipped with any VS 2017+ installer).
    if (-not ${env:ProgramFiles(x86)}) { return $false }
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere)) { return $false }
    $found = & $vswhere -latest -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -find 'VC\Tools\MSVC\**\bin\Host*\*\link.exe' 2>$null
    if ($LASTEXITCODE -ne 0) { return $false }
    foreach ($linker in $found) {
        if (Test-Path -LiteralPath $linker -PathType Leaf) { return $true }
    }
    return $false
}

# The native extension also links against Windows import libraries. A missing
# Windows SDK produces confusing link errors, so verify it explicitly. This is
# a best-effort probe: some valid installs only expose the SDK inside a
# Developer Command Prompt, so a miss is a warning, not a hard failure.
function Test-WindowsSdk {
    $roots = @()
    if ($env:WindowsSdkDir) { $roots += (Join-Path $env:WindowsSdkDir 'Include') }
    if (${env:ProgramFiles(x86)}) {
        $roots += (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Include')
    }
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $versions = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue
        foreach ($version in $versions) {
            if (Test-Path -LiteralPath (Join-Path $version.FullName 'um\Windows.h') -PathType Leaf) {
                return $true
            }
        }
    }
    return $false
}

Write-Info "Checking MSVC build tools (needed to compile the native extension)..."
if (Test-MsvcLinker) {
    Write-Ok "MSVC linker (link.exe) present"
} else {
    # Detect and instruct only. Installing the Build Tools is a multi-GB
    # download behind a UAC prompt, which is not something an installer
    # should start on the user's behalf without asking.
    Write-Fail @"
MSVC build tools not found.

The next step compiles the mandatory openjarvis-rust extension, which
needs the MSVC linker (link.exe). Without it every cargo build script
fails with "error: linker ``link.exe`` not found".

Install via winget - expect a multi-GB download and a UAC prompt:

    winget install --id Microsoft.VisualStudio.2022.BuildTools ``
        --override "--wait --quiet --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"

--override is load-bearing: the default Build Tools install ships no
workload at all, so VCTools has to be requested explicitly.

Alternatively download "Build Tools for Visual Studio" from
https://visualstudio.microsoft.com/downloads/ and select the
"Desktop development with C++" workload.

Then re-run this installer.
"@
}

if (-not (Test-WindowsSdk)) {
    Write-Warn2 "Windows SDK headers were not found in the usual locations."
    Write-Warn2 "  If linking fails with missing Windows libraries, install the"
    Write-Warn2 "  'Windows 11 SDK' component via Visual Studio Build Tools."
} else {
    Write-Ok "Windows SDK headers present"
}

# ---------------------------------------------------------------------------
# 5c. Rust toolchain - explicit, pinned, minimal, no proxy auto-install
# ---------------------------------------------------------------------------

function Get-RustupCommand {
    $cmd = Get-Command rustup -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $fallback = Join-Path $env:USERPROFILE '.cargo\bin\rustup.exe'
    if (Test-Path -LiteralPath $fallback) { return $fallback }
    return $null
}

# Health check uses an EXPLICIT toolchain name and RUSTUP_AUTO_INSTALL=0, so
# it can never trigger a download or a component install.
function Test-PinnedRustToolchain {
    param([string] $RustupExe)
    if (-not $RustupExe) { return $false }
    try {
        $rustcOut = & $RustupExe run $script:PinnedRustVersion rustc --version 2>$null
        if ($LASTEXITCODE -ne 0) { return $false }
        & $RustupExe run $script:PinnedRustVersion cargo --version 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { return $false }
        if (-not ($rustcOut -match '1\.90\.0')) { return $false }
        return $true
    } catch {
        return $false
    }
}

function Assert-RustTarget {
    param([string] $RustupExe)
    $targets = @(& $RustupExe target list --installed --toolchain $script:PinnedRustVersion 2>$null)
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "rustup could not list installed targets for $($script:PinnedRustVersion). Run 'rustup toolchain install $($script:PinnedRustVersion) --profile minimal' manually."
    }
    if ($targets -notcontains $script:RustHostTarget) {
        Write-Info "  Adding Rust target $($script:RustHostTarget)..."
        & $RustupExe target add --toolchain $script:PinnedRustVersion $script:RustHostTarget
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "rustup could not add target $($script:RustHostTarget)."
        }
    }
    Write-Ok "Rust target $($script:RustHostTarget)"
}

function Assert-RustToolchain {
    Write-Info "Checking Rust toolchain ($($script:PinnedRustVersion), minimal profile)..."
    Update-PathFromRegistry
    $rustupExe = Get-RustupCommand
    if (-not $rustupExe) {
        Write-Fail @"
rustup was not found, so the mandatory openjarvis-rust extension cannot be
built. Install Rust from https://rustup.rs (choose the default MSVC host
toolchain), then re-run this installer. This script deliberately does not
download or execute an unverified rustup-init binary.
"@
    }
    Write-Info "  rustup ($rustupExe)"

    # Read-only because RUSTUP_AUTO_INSTALL=0 was set at the top of this script.
    $activeToolchain = & $rustupExe show active-toolchain 2>$null
    if ($LASTEXITCODE -eq 0 -and $activeToolchain) {
        Write-Info "  active toolchain: $($activeToolchain | Select-Object -First 1)"
    }

    $rustcCmd = Get-Command rustc -ErrorAction SilentlyContinue
    $cargoCmd = Get-Command cargo -ErrorAction SilentlyContinue
    if ($rustcCmd) { Write-Info "  rustc ($($rustcCmd.Source))" } else { Write-Info "  rustc: proxy not on PATH yet" }
    if ($cargoCmd) { Write-Info "  cargo ($($cargoCmd.Source))" } else { Write-Info "  cargo: proxy not on PATH yet" }

    $registered = @(& $rustupExe toolchain list 2>$null) | Where-Object { $_ -match '^1\.90\.0' }

    if (-not (Test-PinnedRustToolchain $rustupExe)) {
        if ($registered) {
            Write-Warn2 "  Rust $($script:PinnedRustVersion) is registered but rustc/cargo cannot run (partial install)."
            Write-Warn2 "  Attempting ONE repair install. Never restore quarantined Defender files."
        }
        Write-Info "  Installing Rust $($script:PinnedRustVersion) with --profile minimal (single attempt)..."
        & $rustupExe toolchain install $script:PinnedRustVersion --profile minimal --no-self-update
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "rustup failed to install $($script:PinnedRustVersion). Check the output above."
        }
        if (-not (Test-PinnedRustToolchain $rustupExe)) {
            Write-Fail @"
Rust $($script:PinnedRustVersion) is still not usable after the install attempt.
This normally means the toolchain is partially installed (for example a
component download was quarantined by Windows Defender). Safe recovery:

  1. Review Windows Security -> Protection history. Do NOT restore the
     quarantined file, add an exclusion, or disable Defender.
  2. Verify the detection against the official Rust 1.90.0 checksums and
     signatures (see deploy/windows/README.md).
  3. Remove ONLY the incomplete toolchain:
        rustup toolchain uninstall 1.90.0
  4. Re-run this installer.
"@
        }
    } else {
        Write-Ok "Rust $($script:PinnedRustVersion) already healthy (no download needed)"
    }

    Assert-RustTarget $rustupExe

    # Force every later cargo/rustc proxy call - including the ones maturin
    # makes during `uv sync` - onto the pinned toolchain with auto-install off.
    $env:RUSTUP_TOOLCHAIN = $script:PinnedRustVersion
    $env:RUSTUP_AUTO_INSTALL = '0'
    Write-Info "  RUSTUP_TOOLCHAIN=$($script:PinnedRustVersion); RUSTUP_AUTO_INSTALL=0 for the build"
}

Assert-RustToolchain

# ---------------------------------------------------------------------------
# 6. uv sync --locked --extra desktop --group desktop-native
# ---------------------------------------------------------------------------

Write-Info "Running 'uv sync --locked --extra desktop --group desktop-native' in $srcDir (this can take a few minutes)..."
Push-Location $srcDir
try {
    & $uvExe sync --locked --extra desktop --group desktop-native
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "uv sync failed with exit code $LASTEXITCODE. Check the output above."
    }
} finally {
    Pop-Location
}
Write-Ok "Dependencies installed"

Write-Info "Verifying the compiled native extension..."
& $uvExe run --no-sync --project $srcDir python -c "import openjarvis_rust"
if ($LASTEXITCODE -ne 0) {
    Write-Fail @"
'openjarvis_rust' could not be imported after uv sync. The native extension
was not built correctly; the installer is NOT reporting success. Check the
uv sync output above, then run:

    cd "$srcDir"
    uv sync --locked --extra desktop --group desktop-native
    uv run python -c "import openjarvis_rust"
"@
}
Write-Ok "openjarvis_rust extension imports successfully"

# ---------------------------------------------------------------------------
# 7. Ollama - install + start + wait for daemon
# ---------------------------------------------------------------------------

Write-Info "Checking Ollama..."
Update-PathFromRegistry
$ollamaExe = (Get-Command ollama -ErrorAction SilentlyContinue).Source
if (-not $ollamaExe) {
    # Prefer winget: its maintained manifest verifies the installer SHA-256.
    Write-Info "  Ollama not on PATH - installing via winget (hash-verified manifest)..."
    $installed = Install-WithWinget -WingetId 'Ollama.Ollama' -CommandName 'ollama'
    if (-not $installed) {
        Write-Info "  winget unavailable or failed - falling back to a signature-verified direct download..."
        $verified = Install-OllamaFromVerifiedDownload
        if (-not $verified) {
            Write-Fail @"
Ollama could not be installed or verified automatically. Install it manually
from https://ollama.com/download (or 'winget install --id Ollama.Ollama -e'),
then re-run this installer. This script will not execute an installer whose
Authenticode signature and publisher could not be verified.
"@
        }
        Update-PathFromRegistry
        $installed = (Get-Command ollama -ErrorAction SilentlyContinue).Source
    }
    if (-not $installed) {
        Write-Fail "Ollama was installed but 'ollama' is not on PATH. Open a fresh PowerShell and re-run."
    }
    $ollamaExe = $installed
}
Write-Ok "Ollama ($ollamaExe)"

# Make sure the daemon is actually responsive before pulling. The Ollama
# Windows installer launches the tray app at install time, but on a re-
# run with an existing install the daemon may not be running yet.
Write-Info "Waiting for Ollama daemon..."
$ollamaReady = $false
for ($i = 0; $i -lt 60; $i++) {
    # 'ollama list' writes to stderr until the daemon is reachable; under
    # $ErrorActionPreference='Stop' the 2>&1 merge surfaces that as a
    # terminating NativeCommandError that would abort the whole install on
    # the very first probe. Swallow it and rely on $LASTEXITCODE so the
    # Start-Process serve fallback below actually runs (issue #522).
    try { & $ollamaExe list 2>&1 | Out-Null } catch { }
    if ($LASTEXITCODE -eq 0) {
        $ollamaReady = $true
        break
    }
    if ($i -eq 5) {
        # Daemon clearly isn't auto-running - start it ourselves. Ollama
        # for Windows uses the tray app `ollama app.exe`; falling back to
        # `ollama serve` works headless.
        Start-Process -FilePath $ollamaExe -ArgumentList 'serve' -WindowStyle Hidden -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 1
}
if (-not $ollamaReady) {
    Write-Warn2 "Ollama daemon didn't become ready in 60s. Continuing - bg-orchestrator will retry later."
}

# ---------------------------------------------------------------------------
# 8. Pull a starter model (qwen3.5:2b - ~1.5 GB)
# ---------------------------------------------------------------------------

$modelPullOk = $false
if ($ollamaReady) {
    # Idempotent: don't re-pull (or report a misleading fresh download) when
    # the starter model is already in the local Ollama store.
    $existingModels = @(& $ollamaExe list 2>$null)
    if ($LASTEXITCODE -eq 0 -and ($existingModels -match 'qwen3\.5:2b')) {
        $modelPullOk = $true
        Write-Ok "Starter model already present"
    } else {
        Write-Info "Pulling qwen3.5:2b (~1.5 GB) so 'jarvis' works on first run..."
        & $ollamaExe pull 'qwen3.5:2b'
        if ($LASTEXITCODE -eq 0) {
            $modelPullOk = $true
            Write-Ok "Starter model ready"
        } else {
            Write-Warn2 "ollama pull failed; the bg-orchestrator will retry once Ollama is reachable."
        }
    }
} else {
    Write-Warn2 "Skipping model pull - daemon wasn't ready."
}

# ---------------------------------------------------------------------------
# 9. jarvis.cmd shim - so bare `jarvis` works in any new PowerShell
# ---------------------------------------------------------------------------

$binDir = Join-Path $installRoot 'bin'
$shimPath = Join-Path $binDir 'jarvis.cmd'

if (-not (Test-Path $binDir)) {
    New-Item -ItemType Directory -Path $binDir | Out-Null
}

# %~dp0 in a .cmd file resolves to the directory containing the script,
# so the shim is self-locating - moving %LOCALAPPDATA%\OpenJarvis won't
# break it as long as the user moves the whole tree. `uv` is resolved
# from PATH at runtime (astral installer adds it to User PATH); avoids
# pinning to the install-time uv.exe path which can shift on uv updates.
# The extras and the native-extension group are spelled out so `uv run` can
# never re-sync the environment down to the bare default set and drop what the
# installer just built (uvicorn/fastapi from the desktop extra, the maturin
# build from the desktop-native group, the cloud provider SDKs).
$shimContent = @"
@echo off
setlocal
set "SRC=%~dp0..\src"
uv run --locked --project "%SRC%" --extra desktop --extra inference-cloud --extra inference-google --group desktop-native jarvis %*
"@
Set-Content -Path $shimPath -Value $shimContent -Encoding ASCII

# Add %LOCALAPPDATA%\OpenJarvis\bin to User PATH if it isn't already
# there. The current process won't see it until restart - handled in the
# final banner.
#
# Compare against the EXPANDED form: a previous install may have written
# the entry as `%LOCALAPPDATA%\OpenJarvis\bin` (unexpanded) into User
# PATH, and a literal `-ieq` against the expanded `$binDir` would miss
# it and append a duplicate every re-run.
$userPath = [System.Environment]::GetEnvironmentVariable('Path', 'User')
$pathOnUser = $false
if ($userPath) {
    foreach ($entry in ($userPath -split ';')) {
        $expanded = [System.Environment]::ExpandEnvironmentVariables($entry)
        if ($expanded -ieq $binDir) { $pathOnUser = $true; break }
    }
}
$pathNeedsRefresh = $false
if (-not $pathOnUser) {
    $newUserPath = if ($userPath) { "$userPath;$binDir" } else { $binDir }
    [System.Environment]::SetEnvironmentVariable('Path', $newUserPath, 'User')
    $pathNeedsRefresh = $true
}
Write-Ok "jarvis shim installed at $shimPath"

# ---------------------------------------------------------------------------
# 10. Optional: register the scheduled-task service
# ---------------------------------------------------------------------------

$serviceScript = Join-Path $srcDir 'deploy\windows\jarvis-service.ps1'
$shouldInstallService = $false

# Pre-check admin if the user wants the service - Register-ScheduledTask
# requires elevation. We do this before the prompt so we don't ask "do
# you want the service?" only to fail with Access Denied after they say
# yes.
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if ($Service -and -not $isAdmin) {
    Write-Fail "-Service was requested, but this PowerShell is not elevated. Register-ScheduledTask needs admin rights - re-run from an elevated PowerShell, or drop -Service."
}
if ($Service) {
    $shouldInstallService = $true
} elseif ($SkipService) {
    $shouldInstallService = $false
} elseif (-not $isAdmin) {
    # Default to skip-with-explanation when we can't elevate, rather
    # than prompting and then failing at Register-ScheduledTask.
    Write-Warn2 "Skipping scheduled-task setup - this PowerShell is not elevated."
    Write-Warn2 "  Register-ScheduledTask requires admin. To install the service later:"
    Write-Warn2 "    Right-click PowerShell -> Run as administrator, then run:"
    Write-Warn2 "    powershell -ExecutionPolicy RemoteSigned -File `"$serviceScript`" install"
} else {
    # Interactive prompt only when there's a real user at the keyboard
    # AND stdin isn't piped. [Environment]::UserInteractive is the
    # canonical PowerShell idiom for "is this a user session" (false for
    # services, scheduled tasks, etc); we additionally guard against the
    # `irm | iex` case where stdin is redirected.
    $isInteractive = [Environment]::UserInteractive `
        -and -not [System.Console]::IsInputRedirected
    if ($isInteractive) {
        $reply = Read-Host "Register OpenJarvis as a Windows scheduled task (auto-start at logon, loopback only)? [y/N]"
        $shouldInstallService = ($reply -match '^[yY]')
    } else {
        Write-Warn2 "Non-interactive install - skipping scheduled-task setup."
        Write-Warn2 "To register the service later, run (from an elevated PowerShell):"
        Write-Warn2 "  powershell -ExecutionPolicy RemoteSigned -File `"$serviceScript`" install"
    }
}

if ($shouldInstallService) {
    if (-not (Test-Path $serviceScript)) {
        Write-Fail "Service script not found at $serviceScript (the clone may be missing files; try -Force)."
    }
    Write-Info "Installing scheduled task..."
    & powershell -ExecutionPolicy RemoteSigned -File $serviceScript install -InstallRoot $installRoot
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Scheduled task setup failed."
    }
    Write-Ok "Scheduled task 'OpenJarvis' registered (loopback default)."
}

# ---------------------------------------------------------------------------
# 8. Final message
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "  +----------------------------------+" -ForegroundColor Green
Write-Host "  |   OpenJarvis install complete    |" -ForegroundColor Green
Write-Host "  +----------------------------------+" -ForegroundColor Green
Write-Host ""
Write-Host "  Repo:    $srcDir"

# Tell the truth about what the user can run next, given (a) whether the
# starter model finished pulling and (b) whether the User-PATH update
# needs a fresh PowerShell to take effect.
$nextCmd = if ($modelPullOk) { 'jarvis' } else { 'jarvis doctor' }

if ($pathNeedsRefresh) {
    Write-Host ""
    Write-Host "  Run it:  open a NEW PowerShell, then: $nextCmd" -ForegroundColor Yellow
    Write-Host "           (the jarvis shim was added to your User PATH; the"
    Write-Host "            current PowerShell won't see it until restart)"
} else {
    Write-Host "  Run it:  $nextCmd"
}

if (-not $modelPullOk) {
    Write-Host ""
    Write-Host "  NOTE: the qwen3.5:2b model didn't finish downloading." -ForegroundColor Yellow
    Write-Host "        Chat will fail until the bg-orchestrator finishes the retry."
    Write-Host "        'jarvis doctor' shows progress."
}

if ($shouldInstallService) {
    Write-Host ""
    Write-Host "  Service: schtasks /Query /TN OpenJarvis     (status)"
    Write-Host "           powershell -File `"$serviceScript`" uninstall    (remove)"
}
Write-Host ""
Write-Host "  Docs:    https://github.com/nikhil090805/-nikOpenJarvis/blob/main/deploy/windows/README.md"
Write-Host "  Health:  http://127.0.0.1:8000/health"
Write-Host "  Desktop: install the OpenJarvis_x64-setup.exe release, or build from frontend/."
Write-Host "           See deploy/windows/README.md (Desktop GUI section)."
Write-Host ""
