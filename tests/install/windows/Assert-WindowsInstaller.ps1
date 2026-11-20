<#
.SYNOPSIS
    Windows installer / service regression harness.

.DESCRIPTION
    MOCKED + STATIC tests only. It never installs Rust, uv, Ollama, registers a
    scheduled task, contacts a third-party service, or touches user data. The
    real integration steps (native extension build/import, frontend build,
    Tauri build, backend health) live in installer-integration.yml and are
    clearly labelled there.

    Compatibility: Windows PowerShell 5.1 and PowerShell 7+.
#>
param(
    [string] $RepoRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $RepoRoot) {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
}

$installerPath = Join-Path $RepoRoot 'deploy\windows\install.ps1'
$servicePath   = Join-Path $RepoRoot 'deploy\windows\jarvis-service.ps1'
$installerText = Get-Content -LiteralPath $installerPath -Raw
$serviceText   = Get-Content -LiteralPath $servicePath -Raw

$script:Passed = 0
function Assert-True {
    param($Condition, [string] $Message)
    if (-not $Condition) { throw "ASSERT FAILED: $Message" }
    $script:Passed++
}
function Assert-Contains {
    param([string] $Needle, [string] $Message)
    Assert-True ($installerText.Contains($Needle) -or $serviceText.Contains($Needle)) $Message
}
function Assert-NotContains {
    param([string] $Needle, [string] $Message)
    Assert-True (-not ($installerText.Contains($Needle) -or $serviceText.Contains($Needle))) $Message
}
function Assert-NotContainsService {
    param([string] $Needle, [string] $Message)
    Assert-True (-not $serviceText.Contains($Needle)) $Message
}

# ---------------------------------------------------------------------------
# 1. REAL PowerShell syntax check (both shipped scripts)
# ---------------------------------------------------------------------------
foreach ($path in @($installerPath, $servicePath)) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $path, [ref]$tokens, [ref]$errors)
    Assert-True ($errors.Count -eq 0) "Parse errors in $path : $($errors | Out-String)"
    Write-Host "[ok] PowerShell parses: $path"
}

# ---------------------------------------------------------------------------
# 2. STATIC assertions: repository, Rust pin, verification, service security
# ---------------------------------------------------------------------------
Assert-Contains 'https://github.com/nikhil090805/-nikOpenJarvis.git' 'installer must default to this fork'
Assert-True (-not $installerText.Contains("'https://github.com/open-jarvis/OpenJarvis.git'")) 'installer must not default to upstream'
Assert-Contains "PinnedRustVersion = '1.90.0'" 'fully qualified Rust pin'
Assert-Contains '--profile minimal' 'minimal Rust profile'
Assert-Contains 'RUSTUP_AUTO_INSTALL' 'proxy auto-install must be disabled'
Assert-Contains 'RUSTUP_TOOLCHAIN' 'explicit toolchain selection'
Assert-Contains 'x86_64-pc-windows-msvc' 'Windows MSVC target'
Assert-Contains 'uv sync --locked --extra desktop --group desktop-native' 'locked sync with native group'
Assert-Contains 'import openjarvis_rust' 'native extension import verification'
Assert-Contains 'Get-FileHash' 'SHA-256 verification of downloaded uv archive'
Assert-Contains '.sha256' 'publisher checksum sidecar'
Assert-Contains 'Get-AuthenticodeSignature' 'Authenticode verification for Ollama fallback'
Assert-Contains 'Get-CheckoutOrigin' 'existing checkout must be verified'
Assert-Contains 'status --porcelain' 'uncommitted work must not be overwritten'
Assert-Contains 'Test-WindowsSdk' 'Windows SDK verification'
Assert-Contains 'Assert-RustToolchain' 'explicit Rust prerequisite stage'

Assert-NotContains "Invoke-RestMethod -Uri 'https://astral.sh/uv/install.ps1'" 'no unverified remote script piped to IEX'
Assert-NotContains 'ExecutionPolicy Bypass' 'no ExecutionPolicy Bypass'
Assert-NotContains "Join-Path `$env:TEMP 'OllamaSetup.exe'" 'no predictable temp exe path'
Assert-NotContainsService 'SetEnvironmentVariable(' 'no plaintext API key in user environment'
Assert-NotContains 'maturin will bootstrap a Rust' 'inaccurate maturin claim removed'
Assert-Contains 'ConvertFrom-SecureString' 'DPAPI-protected API key'
Assert-Contains 'ValidateRange(1, 65535)' 'ListenPort range validation'
Assert-Contains 'ValidatePattern(' 'ListenHost pattern validation'
Assert-Contains 'RunLevel Limited' 'least-privileged task principal'
Assert-Contains 'Resolve-ListenHost' 'ListenHost validation function'
Write-Host "[ok] static assertions ($($script:Passed) checks so far)"

# ---------------------------------------------------------------------------
# 3. MOCKED unit tests: extract real functions, override all external effects
# ---------------------------------------------------------------------------
$errors = $null
$tokens = $null
$installerAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $installerPath, [ref]$tokens, [ref]$errors)
$serviceAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $servicePath, [ref]$tokens, [ref]$errors)

$wanted = @(
    'Get-NormalizedRepoUrl', 'Get-RustupCommand', 'Test-PinnedRustToolchain',
    'Assert-RustTarget', 'Assert-RustToolchain', 'Test-WindowsSdk',
    'Install-UvFromVerifiedRelease', 'Resolve-ListenHost', 'Test-LoopbackHost',
    'Assert-SafePath', 'ConvertTo-PsSingleQuoted'
)
foreach ($ast in @($installerAst, $serviceAst)) {
    $defs = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $wanted -contains $node.Name
    }, $true)
    foreach ($def in $defs) { Invoke-Expression $def.Extent.Text }
}

$script:PinnedRustVersion = '1.90.0'
$script:RustHostTarget = 'x86_64-pc-windows-msvc'
$env:RUSTUP_AUTO_INSTALL = '0'

function Write-Info  { param($msg) }
function Write-Ok    { param($msg) }
function Write-Warn2 { param($msg) }
function Write-Fail  { param($msg) throw "Write-Fail: $msg" }
function Update-PathFromRegistry { }
function Get-Command {
    param($Name, $ErrorAction)
    if ($Name -in @('rustup', 'rustc', 'cargo')) {
        return [pscustomobject]@{ Source = "$Name-mock" }
    }
    return $null
}

# --- repository normalisation / selection ---
Assert-True ((Get-NormalizedRepoUrl 'https://github.com/nikhil090805/-nikOpenJarvis.git') -eq
             (Get-NormalizedRepoUrl 'https://github.com/nikhil090805/-nikOpenJarvis')) 'repo URL normalisation'
Assert-True ((Get-NormalizedRepoUrl 'https://github.com/nikhil090805/-nikOpenJarvis.git') -ne
             (Get-NormalizedRepoUrl 'https://github.com/open-jarvis/OpenJarvis.git')) 'upstream must not match fork'
Write-Host '[ok] repository selection (mocked)'

# --- Rust stage: healthy toolchain => ZERO installs ---
$mockDir = Join-Path ([System.IO.Path]::GetTempPath()) ('oj-rustup-mock-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $mockDir -Force | Out-Null
$mockLog = Join-Path $mockDir 'calls.log'
$mockRustup = Join-Path $mockDir 'rustup.cmd'
$mockRustupContent = @"
@echo off
echo %* >> "$mockLog"
echo 1.90.0-x86_64-pc-windows-msvc
echo x86_64-pc-windows-msvc
exit /b 0
"@
Set-Content -LiteralPath $mockRustup -Value $mockRustupContent -Encoding ASCII

function Get-RustupCommand { return $mockRustup }
function Assert-RustTarget { param($RustupExe) }
function Test-WindowsSdk { return $true }
function Test-PinnedRustToolchain { param($RustupExe) return $true }

try {
    Assert-RustToolchain
    $calls = @(Get-Content -LiteralPath $mockLog -ErrorAction SilentlyContinue)
    Assert-True (-not ($calls -match 'toolchain install')) 'healthy pinned toolchain must not be re-downloaded'
    Assert-True ($env:RUSTUP_TOOLCHAIN -eq '1.90.0') 'explicit toolchain selected for the build'
    Assert-True ($env:RUSTUP_AUTO_INSTALL -eq '0') 'auto-install disabled for the build'
    Write-Host '[ok] Rust 1.90.0 minimal: healthy path performs no download (mocked)'
} finally {
    Remove-Item -LiteralPath $mockDir -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Rust stage: partial/unhealthy toolchain => exactly ONE repair, then fail ---
$mockDir2 = Join-Path ([System.IO.Path]::GetTempPath()) ('oj-rustup-mock-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $mockDir2 -Force | Out-Null
$mockLog2 = Join-Path $mockDir2 'calls.log'
$mockRustup2 = Join-Path $mockDir2 'rustup.cmd'
$mockRustupContent2 = @"
@echo off
echo %* >> "$mockLog2"
echo 1.90.0-x86_64-pc-windows-msvc
exit /b 0
"@
Set-Content -LiteralPath $mockRustup2 -Value $mockRustupContent2 -Encoding ASCII
function Get-RustupCommand { return $mockRustup2 }
function Test-PinnedRustToolchain { param($RustupExe) return $false }
$failedAsExpected = $false
try { Assert-RustToolchain } catch { $failedAsExpected = $true }
try {
    $calls2 = @(Get-Content -LiteralPath $mockLog2 -ErrorAction SilentlyContinue)
    $installs = @($calls2 | Where-Object { $_ -match 'toolchain install' })
    Assert-True ($installs.Count -eq 1) "expected exactly one repair install, got $($installs.Count)"
    Assert-True $failedAsExpected 'unhealthy toolchain must fail safely, not report success'
    Write-Host '[ok] partial toolchain: single repair then safe failure (mocked)'
} finally {
    Remove-Item -LiteralPath $mockDir2 -Recurse -Force -ErrorAction SilentlyContinue
}

# --- verified download: an incomplete/failed download must never execute ---
function Invoke-WebRequest { param($Uri, $OutFile, $UseBasicParsing) throw 'simulated download failure' }
function New-Item { param($ItemType, $Path, $Force) }
function Test-Path { param($LiteralPath, $PathType) return $false }
$uvResult = Install-UvFromVerifiedRelease
Assert-True ($null -eq $uvResult) 'failed download must return null (fail safe)'
Write-Host '[ok] failed download handling (mocked)'

# --- scheduled-task argument validation ---
Assert-True ((Resolve-ListenHost '127.0.0.1') -eq '127.0.0.1') 'loopback default'
Assert-True ((Resolve-ListenHost 'localhost') -eq '127.0.0.1') 'localhost maps to loopback'
Assert-True ((Resolve-ListenHost '0.0.0.0') -eq '0.0.0.0') 'non-loopback allowed only with key'
Assert-True (Test-LoopbackHost '127.0.0.1') 'loopback detection'
Assert-True (-not (Test-LoopbackHost '0.0.0.0')) 'non-loopback detection'
Assert-True ((ConvertTo-PsSingleQuoted "a'b") -eq "'a''b'") 'single-quote escaping'

$badHostRejected = $false
try { Resolve-ListenHost '999.1.1.1' } catch { $badHostRejected = $true }
Assert-True $badHostRejected 'invalid IP rejected'

$badPathRejected = $false
try { Assert-SafePath 'C:\bad" & calc.exe' } catch { $badPathRejected = $true }
Assert-True $badPathRejected 'argument-injection characters in paths rejected'

# Real parameter-binding validation via a child process (no task is registered).
$psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$oldEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    $badPort = & $psExe -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned `
        -File $servicePath -Command status -ListenHost '0.0.0.0' -ListenPort 99999 2>&1
    $badPortExit = $LASTEXITCODE
    $badHost = & $psExe -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned `
        -File $servicePath -Command status -ListenHost '127.0.0.1 & calc' 2>&1
    $badHostExit = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $oldEap
}
Assert-True ($badPortExit -ne 0) 'out-of-range ListenPort must be rejected by the script'
Assert-True ($badHostExit -ne 0) 'injected ListenHost must be rejected by the script'
Write-Host '[ok] scheduled-task argument validation (mocked + parameter binding)'

Write-Host ""
Write-Host "ALL WINDOWS INSTALLER CHECKS PASSED ($($script:Passed) assertions)" -ForegroundColor Green
