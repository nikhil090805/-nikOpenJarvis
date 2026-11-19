# OpenJarvis on native Windows (this fork)

This is the supported native-Windows installation path for
**`nikhil090805/-nikOpenJarvis`**. It installs the CLI/backend **and** prepares
everything the existing Tauri/React desktop GUI needs. It does not use WSL2,
Docker, MSYS2/Git Bash, or a browser-only substitute.

## Supported systems

| Item | Requirement |
|---|---|
| OS | Windows 10 1809 (build 17763) or newer, Windows 11 — **x64** |
| Shell | Windows PowerShell 5.1 or PowerShell 7+ |
| Python | 3.11, 3.12 or 3.13 (3.14 is rejected: no numpy wheels) |
| Git | on `PATH` (auto-installed via winget if missing) |
| uv | auto-installed via winget (`astral-sh.uv`) or a SHA-256-verified pinned release |
| Rust | **1.89.0**, `minimal` profile, target `x86_64-pc-windows-msvc` |
| MSVC | Visual Studio 2022 Build Tools with **Desktop development with C++** (MSVC linker + Windows SDK) |
| Node.js (desktop build from source only) | `>=22.22`, npm `>=11.19.0 <12` (`npm@11.19.0` is the reviewed pin) |
| Ollama | installed via winget (`Ollama.Ollama`) or a signature-verified direct download |

Windows ARM64 is still supported by the desktop app through x64 emulation
(see `docs/getting-started/windows-native.md`); the pinned 1.89.0 MSRV override
on that platform is intentional and documented.

---

## One verified installation procedure

Run in a normal PowerShell (no admin needed unless you want the optional
scheduled task). **Do not** pipe a remote script into PowerShell: run the copy
from your own fork checkout so the installer and source tree always agree.

```powershell
git clone https://github.com/nikhil090805/-nikOpenJarvis.git
cd .\-nikOpenJarvis
powershell -ExecutionPolicy RemoteSigned -File .\deploy\windows\install.ps1 -SkipService
```

Optional flags:

| Flag | Effect |
|---|---|
| `-SkipService` | Don't prompt for / register the scheduled task |
| `-Service` | Register the scheduled task without prompting (elevated shell) |
| `-Force` | Re-run all steps; updates an existing checkout with `git pull --ff-only` |
| `-SourceDir <path>` | Use an existing checkout instead of cloning (its `origin` must match the selected repo) |

Environment equivalents (for non-interactive shells):
`OPENJARVIS_SKIP_SERVICE`, `OPENJARVIS_SERVICE`, `OPENJARVIS_FORCE`,
`OPENJARVIS_HOME`, `OPENJARVIS_REPO_URL`.

### What the installer does, in order

1. Refuses non-Windows / Windows < 10 1809.
2. Detects Python 3.11–3.13 (auto-installs `Python.Python.3.13` via winget if absent).
3. Detects `git` (auto-installs `Git.Git` via winget if absent).
4. Detects `uv`; installs it via winget's hash-verified manifest, or from the
   pinned uv release verified against Astral's published `.sha256` sidecar.
5. Clones **`https://github.com/nikhil090805/-nikOpenJarvis.git`** to
   `%LOCALAPPDATA%\OpenJarvis\src` (override with `OPENJARVIS_REPO_URL`).
   An existing checkout is **verified, never blindly pulled or overwritten**:
   a mismatched `origin` or uncommitted changes cause a clear failure.
6. Verifies the MSVC `link.exe` (via `vswhere`) and Windows SDK headers.
7. **Rust stage**: explicitly detects `rustup`, `rustc`, `cargo`; reports the
   active toolchain; installs `1.89.0` with `--profile minimal` only when the
   pinned toolchain is not healthy; verifies/adds `x86_64-pc-windows-msvc`;
   sets `RUSTUP_TOOLCHAIN=1.89.0` and `RUSTUP_AUTO_INSTALL=0` for the build.
8. Runs `uv sync --locked --extra desktop --group desktop-native`, then
   **verifies `import openjarvis_rust`** before reporting success.
9. Installs/verifies Ollama (winget first, signature-verified download fallback),
   waits for the daemon, pulls `qwen3.5:2b` only if not already present.
10. Writes the `jarvis.cmd` shim and optionally registers the scheduled task.

The installer is idempotent: re-running it reuses an existing checkout, skips
a healthy pinned toolchain (no Rust download), reuses an installed Ollama and
starter model, and replaces the scheduled task only when asked.

### Verify the backend

```powershell
# In a NEW PowerShell (the shim was added to your User PATH):
jarvis doctor
jarvis serve            # or let the desktop app start it for you
```

Then open <http://127.0.0.1:8000/health> — it must return a healthy response.

---

## Repository selection

The default is **this fork**, not upstream. The installer prints the selected
URL. `OPENJARVIS_REPO_URL` overrides it (useful for a local mirror). `-SourceDir`
lets you install from a checkout you already cloned; its `origin` is compared
with the selected repository so you can never accidentally build upstream.

`docs/gen_install_script.py` also publishes `install.ps1` to the project docs
site, but fork users should run the script from their own checkout as shown
above.

---

## Supply-chain verification

| Component | Verification |
|---|---|
| `uv` | winget package manifest (maintained SHA-256), or pinned `uv 0.13.9` GitHub release archive verified against the publisher's `uv-x86_64-pc-windows-msvc.zip.sha256`. No hash is hardcoded. |
| Ollama | winget package `Ollama.Ollama` (maintained installer SHA-256). Direct `OllamaSetup.exe` fallback requires a **valid Authenticode signature from Ollama**; otherwise installation fails safely. |
| Python / Git | winget with `--accept-source-agreements --accept-package-agreements`; PATH is re-read from the registry after each install. |
| Source | Clone of the configured git URL; existing checkouts verified before any update. |
| Python deps | `uv sync --locked` uses the committed `uv.lock` (which carries PyPI hashes). The local Rust extension builds with the exact `maturin` version in that lockfile. |
| Temp files | Unique GUID-based temp directory/file names; partial downloads are deleted in `finally` blocks. |

**Documented limitation:** Ollama does not publish a standalone, maintained
SHA-256 for `OllamaSetup.exe`, and `rustup-init` does not publish an easily
verifiable standalone checksum for the POSIX bootstrap. The Windows installer
therefore refuses to execute an unverified installer and never pipes a remote
script into PowerShell. The POSIX `install-rust.sh` bootstrap is the only
remaining `curl | sh` path and is not used on native Windows.

---

## Scheduled-task service

`deploy/windows/jarvis-service.ps1` registers a per-user task named
`OpenJarvis` (loopback `127.0.0.1:8000` by default, `RunLevel Limited`,
`LogonType Interactive`, restart on failure).

```powershell
$srv = "$env:LOCALAPPDATA\OpenJarvis\src\deploy\windows\jarvis-service.ps1"
powershell -ExecutionPolicy RemoteSigned -File $srv install
powershell -ExecutionPolicy RemoteSigned -File $srv status
powershell -ExecutionPolicy RemoteSigned -File $srv start
powershell -ExecutionPolicy RemoteSigned -File $srv stop
powershell -ExecutionPolicy RemoteSigned -File $srv uninstall
```

Security behaviour:

* `ListenHost` is validated (`ValidatePattern` + IP parse) and `ListenPort`
  uses `[ValidateRange(1, 65535)]`. No unvalidated string reaches the task's
  argument list, so argument injection is blocked.
* A non-loopback bind still requires `OPENJARVIS_API_KEY`.
* The key is **no longer written to a plaintext User environment variable**.
  It is stored in `%LOCALAPPDATA%\OpenJarvis\service\api-key.dpapi` using
  Windows DPAPI (current user only, ACL hardened best-effort) and injected into
  the server process by a local launcher script at task start.
* `-ExecutionPolicy Bypass` is not used; `-ExecutionPolicy RemoteSigned` is
  sufficient for the locally generated launcher.
* `uninstall` removes the task and only the two generated files; other user
  data and configuration are preserved.

---

## Desktop GUI (Tauri / React)

The existing desktop application is preserved. It bundles/uses the same
backend, Ollama integration, chat UI, settings, model selection, history,
energy monitoring and trace views.

### Recommended: install a released Windows x64 build

1. Check <https://github.com/nikhil090805/-nikOpenJarvis/releases> for a
   `desktop-*` / `v*` release containing `OpenJarvis_x64-setup.exe`.
2. Run the installer and launch **OpenJarvis** from the Start Menu.
3. Complete the in-app onboarding (choose the inference source; no API key is
   hardcoded). The app starts `uv sync` and `jarvis serve` itself — you do
   **not** need several PowerShell terminals.
4. The Admin Panel shows **"Starting..."** while the backend boots rather than
   incorrectly reporting it offline; once `/health` is up it shows **Healthy**.

If no desktop release has been published in the fork yet, build from source:

```powershell
cd "$env:LOCALAPPDATA\OpenJarvis\src"
npm install --global npm@11.19.0
cd frontend
npm ci
npm test
npm run build
npx tauri build --bundles nsis
```

The NSIS installer is written to
`frontend\src-tauri\target\release\bundle\nsis\`. The desktop app requires
Rust 1.89.0 (already provisioned by `install.ps1`) and the MSVC Build Tools.
Windows CI builds this exact path on `windows-latest` (see
`.github/workflows/installer-integration.yml`, `windows-x64` job).

---

## Safe Windows Defender investigation

If Defender reports `Trojan:Win32/Suschil!rfn` on a file under
`%USERPROFILE%\.rustup\downloads\`:

1. **Do not** disable Defender, add an exclusion, restore the quarantined file,
   or bypass the warning. The installer fails safely in this situation.
2. Record the detection from Windows Security → Protection history (file path,
   reported SHA-256, detection name/signature version).
3. The download cache name is the **expected SHA-256** of a Rust component.
   For Rust 1.89.0 / `x86_64-pc-windows-msvc`, the official manifest is
   <https://static.rust-lang.org/dist/channel-rust-1.89.0.toml>; the official
   `rustfmt` component sidecar is
   <https://static.rust-lang.org/dist/2025-08-07/rustfmt-1.89.0-x86_64-pc-windows-msvc.tar.xz.sha256>
   and its PGP signature is the same URL with `.asc`. The manifest itself has
   `.sha256` and `.asc` sidecars, and the signing key is at
   <https://static.rust-lang.org/rust-key.gpg.ascii>.
4. On a clean machine, download the artifact + `.sha256` + `.asc`, verify the
   SHA-256 and the GPG signature with the official Rust release key, and
   compare with the Defender-reported hash.
5. Submit the sample/hash to Microsoft's false-positive portal
   <https://www.microsoft.com/en-us/wdsi/filesubmission>. **Do not assume it
   is a false positive** — only Microsoft's determination plus a matching
   hash/signature establishes that.
6. If a toolchain is left partially installed, remove only that toolchain
   (`rustup toolchain uninstall 1.89.0`) and re-run the installer. Never
   restore a quarantined file.

---

## Troubleshooting

| Symptom | Action |
|---|---|
| `rustup was not found` | Install Rust from <https://rustup.rs> (MSVC host), then re-run. |
| `MSVC build tools not found` | Install VS 2022 Build Tools with the C++ workload (`winget install --id Microsoft.VisualStudio.2022.BuildTools --override "--wait --quiet --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"`). |
| Windows SDK warning | Install the Windows 11 SDK component if linking fails with missing Windows libraries. |
| `uv sync failed` | Read the printed output; the installer never reports success without a working `import openjarvis_rust`. |
| `openjarvis_rust` import fails | Re-run `uv sync --locked --extra desktop --group desktop-native` in the source dir and check the pinned 1.89.0 toolchain with `rustup show`. |
| Partial Rust toolchain after a Defender quarantine | See the Defender section above. Rustup makes **one** repair attempt and then fails with instructions; it never loops downloading. |
| `jarvis` not found | Open a new PowerShell so the User PATH change takes effect. |
| Desktop says backend offline | Wait for startup; the Admin Panel shows "Starting..." until `/health` responds. Check `jarvis doctor`. |

## Uninstall

```powershell
powershell -ExecutionPolicy RemoteSigned -File "$env:LOCALAPPDATA\OpenJarvis\src\deploy\windows\jarvis-service.ps1" uninstall
Remove-Item -Recurse -Force "$env:LOCALAPPDATA\OpenJarvis"
```

Uninstalling does not remove `uv`, Rust, Python, Git or Ollama.
