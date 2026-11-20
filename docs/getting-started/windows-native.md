# Native Windows (advanced)

This is the native Windows PowerShell path for
**[`nikhil090805/-nikOpenJarvis`](https://github.com/nikhil090805/-nikOpenJarvis)**.
It does not use WSL2, Docker, or Git Bash. WSL2 remains the smoother option for
most CLI users; this page is for users who want the native Windows install and
the existing Tauri/React desktop GUI.

The full reference (prerequisites, verification, Defender guidance, desktop
launch) is [`deploy/windows/README.md`](https://github.com/nikhil090805/-nikOpenJarvis/blob/main/deploy/windows/README.md).
The commands below match that script exactly.

## Windows ARM64 desktop

The existing Tauri/React desktop app can be built for Windows 11 on ARM. The
desktop release workflow produces an `arm64-setup.exe` NSIS installer and adds
`windows-aarch64` to the updater manifest alongside the x64 build. Use the
ARM64 installer when it appears in a new desktop release; older releases only
include x64 installers.

This uses the same UI, backend, and Ollama integration as the other desktop
builds. The desktop executable and bundled Ollama are ARM64. The current Python
dependency stack has no Windows ARM64 wheels for several packages, including
the locked NumPy, PyArrow, and speech dependencies. The app therefore selects
uv-managed **x64 CPython 3.12** and builds the Rust Python extension for x64;
Windows runs that backend through x64 emulation. This preserves the existing
features without a separate UI or dependency stack.

First-launch prerequisites are the same as the x64 desktop: Git, uv, Rust, and
Visual Studio Build Tools with the **x64 C++ workload**. With an ARM64 Rust
installation, install the x64 target for stable Rust:

```powershell
rustup toolchain install stable --profile minimal --no-self-update
rustup target add --toolchain stable x86_64-pc-windows-msvc
```

The ARM64 app intentionally uses **stable** Rust for backend builds so the
compiler matches the installed x64 target, rather than selecting the 1.90.0
MSRV pin (`RUSTUP_TOOLCHAIN=stable` in `frontend/src-tauri/src/lib.rs` and the
ARM64 CI job). This override is deliberate; do not apply it to x64 installs.
It also supplies PyO3's cross-compilation settings for x64 CPython 3.12. The
Python extension still targets x64. The ARM64 desktop build itself requires
the ARM64 C++ build tools and Clang (the Visual Studio **C++ Clang tools for
Windows** component, with `clang.exe` on PATH). Setup still requires the user's
inference-source choice before starting local inference or downloading a model.

### Testing without a Windows ARM laptop

The desktop workflow's `test-windows-arm64` PR job runs on GitHub's
`windows-11-arm` runner. It checks backend imports and CLI startup under x64
emulation, builds an unsigned NSIS installer, checks that the desktop and
Ollama executable headers identify ARM64, and uploads the
`windows-arm64-test-installer` artifact. Passing this job verifies the build
and dependency path; it does not verify interactive chat or hardware
acceleration on physical Windows ARM hardware.

For an interactive test, use Windows 11 ARM in UTM, Parallels, or VMware Fusion
on an Apple silicon Mac. Download the installer artifact from the PR's Actions
run, then check:

1. Settings → System → About identifies an ARM-based processor.
2. The installer completes and OpenJarvis launches.
3. Local setup completes with a small model; chat streams and Stop cancels.
4. Settings, conversation history, and relaunch work as on the x64 app.
5. In Task Manager's Details tab, enable the Architecture column: the desktop
   and Ollama are ARM64, while Python is x64.

A VM is useful for compatibility testing; it does not validate GPU/NPU
performance on physical Windows ARM hardware.

## What you get

- A PowerShell installer that probes prerequisites, installs `uv`, verifies or
  clones this fork, provisions Rust 1.90.0 (`minimal`), and runs
  `uv sync --locked --extra desktop --group desktop-native`.
- An optional Windows scheduled-task service with validated arguments and
  DPAPI-protected credentials.
- The existing Tauri/React desktop GUI, which starts the backend itself.
- Loopback default — the service binds `127.0.0.1` so no API key is required.

## What you need

| Item | Requirement |
|---|---|
| OS | Windows 10 1809+ or Windows 11, x64 |
| Python | 3.11 – 3.13 (3.14 has no numpy Windows wheels yet, see #432) |
| Git | on `PATH` |
| Rust | **1.90.0**, `minimal` profile, target `x86_64-pc-windows-msvc` (see note below) |
| MSVC | VS 2022 Build Tools, **Desktop development with C++** (linker + Windows SDK) |
| Node.js / npm (desktop source build only) | `>=22.22`, npm `11.19.0` |
| Disk | ~5 GB free on `%LOCALAPPDATA%` |

Rust **1.90.0** is a hard minimum, not a preference: the Tauri 2.12 desktop
stack pinned in `frontend/src-tauri/Cargo.lock` (`tauri-utils`,
`tauri-runtime`, `tauri-runtime-wry`, `muda`, `tray-icon`, the `tauri-plugin-*`
crates) declares `rust-version = "1.90"`, so 1.89 cannot build the desktop app
at all. The backend workspace, both Docker images, the installers and CI are
pinned to the same fully qualified `1.90.0` so no second toolchain gets
downloaded. Ordinary installs use `--profile minimal` (no rustfmt/clippy);
only the lint job installs those components.

## Install (one verified procedure)

```powershell
git clone https://github.com/nikhil090805/-nikOpenJarvis.git
cd .\-nikOpenJarvis
powershell -ExecutionPolicy RemoteSigned -File .\deploy\windows\install.ps1 -SkipService
```

Do **not** use `irm ... | iex` or the upstream docs-site copy: run the script
from your own fork checkout so the installer and source tree agree. The
installer defaults to this fork's URL; `OPENJARVIS_REPO_URL` overrides it and
`-SourceDir` reuses an existing checkout whose `origin` matches.

The installer will:

1. Refuse non-Windows hosts and old Windows builds.
2. Confirm Python 3.11–3.13 and `git` (winget fallback for both).
3. Install `uv` via winget or a SHA-256-verified pinned release.
4. Clone / verify this fork at `%LOCALAPPDATA%\OpenJarvis\src`.
5. Verify the MSVC linker and Windows SDK.
6. Detect `rustup`, `rustc`, `cargo`; install Rust 1.90.0 with
   `--profile minimal` only if needed; verify the MSVC target; set
   `RUSTUP_TOOLCHAIN=1.90.0` and `RUSTUP_AUTO_INSTALL=0`.
7. Run `uv sync --locked --extra desktop --group desktop-native` and verify
   `import openjarvis_rust`.
8. Install/verify Ollama and the starter model.
9. Optionally register the scheduled-task service (`-SkipService` skips it).

## Run it

```powershell
# New PowerShell so the jarvis shim is on PATH
jarvis doctor
jarvis serve
```

The shim pins the environment the installer synced (`uv run --locked
--extra desktop --extra inference-cloud --extra inference-google --group
desktop-native jarvis`), so `jarvis` never re-syncs itself down to the bare
defaults. Pass the same flags if you run `uv run` directly.

Open <http://127.0.0.1:8000/health> to verify. With the desktop app you do not
need to start the backend manually — launch **OpenJarvis** and complete the
in-app onboarding; the Admin Panel shows "Starting..." until `/health` responds.

## Desktop GUI on Windows x64

Prefer an existing release from
<https://github.com/nikhil090805/-nikOpenJarvis/releases> (look for
`OpenJarvis_x64-setup.exe`). If no release is published in the fork yet, build
from the checkout:

```powershell
cd "$env:LOCALAPPDATA\OpenJarvis\src"
npm install --global npm@11.19.0
cd frontend
npm ci
npm test
npm run build
npx tauri build --bundles nsis
```

The NSIS installer is in
`frontend\src-tauri\target\release\bundle\nsis\`. If you do not want to
build it yourself, every Windows installer-integration run publishes a built
copy: open
<https://github.com/nikhil090805/-nikOpenJarvis/actions/workflows/installer-integration.yml>,
pick the newest successful `Windows x64` run, and download the
**`OpenJarvis-Windows-x64-NSIS`** artifact (retained 14 days). It contains
`*_x64-setup.exe` plus the raw `openjarvis-desktop.exe`, and the run log prints
the installer's SHA-256.

That `windows-x64` job verifies, on a real Windows runner: the pinned Rust
toolchain and MSVC/SDK, `uv sync --locked --extra desktop --group
desktop-native`, `import openjarvis_rust`, the real `install.ps1` run twice
(idempotency), the frontend tests and production build, the real Tauri build,
the presence and hash of the NSIS installer, and a real `jarvis serve` process
whose `/health` returns `{"status": "ok"}`. The Ollama HTTP API is mocked for
that last check (and Ollama itself is stubbed for the installer run) so no
model is downloaded in CI; the backend and the health route are real.

The desktop app preserves chat, settings, model selection, history, energy
monitoring and trace views; it starts `uv sync` and `jarvis serve` itself, so
no extra terminals are needed.

## Scheduled-task service

```powershell
$srv = "$env:LOCALAPPDATA\OpenJarvis\src\deploy\windows\jarvis-service.ps1"
powershell -ExecutionPolicy RemoteSigned -File $srv install
powershell -ExecutionPolicy RemoteSigned -File $srv status
powershell -ExecutionPolicy RemoteSigned -File $srv start
powershell -ExecutionPolicy RemoteSigned -File $srv stop
powershell -ExecutionPolicy RemoteSigned -File $srv uninstall
```

`ListenHost`/`ListenPort` are validated, task arguments cannot be injected, and
a non-loopback API key is stored with DPAPI rather than in a plaintext user
environment variable. See `deploy/windows/README.md` for details.

## Safe Defender investigation

If Windows Defender flags a file in `%USERPROFILE%\.rustup\downloads\`:
do not disable Defender, add exclusions, or restore the quarantined file.
Record the reported SHA-256 from Protection history, compare it with the
official Rust 1.90.0 checksums/signatures at
`https://static.rust-lang.org/dist/channel-rust-1.90.0.toml`, and submit the
sample to <https://www.microsoft.com/en-us/wdsi/filesubmission>. Do not assume
a false positive until the hash/signature and Microsoft's determination agree.
Full steps are in `deploy/windows/README.md`.

## See also

- [WSL2 install](wsl2.md) — the recommended Windows CLI path.
- [Full installer reference](install.md).
- [`deploy/windows/README.md`](https://github.com/nikhil090805/-nikOpenJarvis/blob/main/deploy/windows/README.md).
