# ============================================================================
# build-windows.ps1 — Native Windows build for legacy atomicdex
# ============================================================================
# Single source of truth for Windows builds. Runs on bare metal, in CI,
# or from any terminal. Zero Docker.
#
# Usage:
#   .\build-windows.ps1                 # full build (KDF only; desktop is manual)
#   .\build-windows.ps1 -KdfOnly        # KDF engine only
#   .\build-windows.ps1 -Yes            # skip all consent prompts
#   .\build-windows.ps1 -InstallDeps    # install missing deps without building
#   .\build-windows.ps1 -DryRun         # check deps and print plan, no build
#   .\build-windows.ps1 -Help           # show this help
#
# Output:
#   output\windows\kdf.exe              # KDF binary (~65MB)
#   output\windows\kdf.exe.sha256
#
# Logs:
#   logs\windows\build.log              # full build output
#   logs\windows\installed.log          # packages installed and how to undo
#
# Desktop wallet: QT5 + WebEngine on Windows requires MSVC and is complex
# to automate. KDF builds natively. Desktop: see README.md for native
# Windows desktop build steps, or cross-compile KDF from Linux and build
# desktop on a Windows VM.
#
# Requirements:
#   Windows 10+ (x86_64)
#   Rust (rustup): https://rustup.rs
#   Git for Windows: https://git-scm.com/download/win
#   Visual Studio Build Tools OR MinGW-w64
#   Optionally: choco or winget for package management
# ============================================================================

param(
    [switch]$KdfOnly,
    [switch]$DesktopOnly,
    [switch]$Yes,
    [switch]$DryRun,
    [switch]$InstallDeps,
    [switch]$Help
)

# ── ENV var overrides ───────────────────────────────────────────
# BUILD_YES=1 is equivalent to -Yes flag
if ($env:BUILD_YES -eq "1") { $Yes = $true }

# ── Help ─────────────────────────────────────────────────────
if ($Help) {
    Get-Content $PSCommandPath | Select-Object -First 30 | ForEach-Object {
        if ($_ -match '^#') { Write-Host $_ -ForegroundColor Cyan }
    }
    exit 0
}

# ── Globals ──────────────────────────────────────────────────

# Reload PATH from registry so winget/choco installs are visible
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")

$ScriptDir    = Split-Path -Parent $PSCommandPath
$ProjectDir   = Split-Path -Parent $ScriptDir
$ConfigDir    = Join-Path $ProjectDir "config"
$OutputDir    = Join-Path $ProjectDir "output\windows"
$LogDir       = Join-Path $ProjectDir "logs\windows"
$BuildDir     = Join-Path $ProjectDir ".build"
$SourcesJson  = Join-Path $ConfigDir "sources.json"
$InstalledLog = Join-Path $LogDir "installed.log"

# Create directories
New-Item -ItemType Directory -Force -Path $OutputDir, $LogDir, $BuildDir | Out-Null

# ── Read config (ENV vars override config files) ──────────────
$Sources  = Get-Content $SourcesJson -Raw | ConvertFrom-Json
$KdfRepo     = if ($env:KDF_REPO) { $env:KDF_REPO } else { $Sources.kdf.repo }
$KdfCommit   = if ($env:KDF_COMMIT) { $env:KDF_COMMIT } else { $Sources.kdf.commit }
$DesktopRepo = if ($env:DESKTOP_REPO) { $env:DESKTOP_REPO } else { $Sources.desktop.repo }
$DesktopCommit = if ($env:DESKTOP_COMMIT) { $env:DESKTOP_COMMIT } else { $Sources.desktop.commit }
$AppName     = if ($env:APP_NAME) { $env:APP_NAME } else { "" }
$AppWebsite  = if ($env:APP_WEBSITE) { $env:APP_WEBSITE } else { "" }
$SeedUrl     = if ($env:SEED_URL) { $env:SEED_URL } else { "" }

# CPU count: use ENV override, or auto-detect (half of logical cores)
if ($env:BUILD_CPUS) {
    $BuildCpus = [int]$env:BUILD_CPUS
    if ($BuildCpus -lt 1) { $BuildCpus = 1 }
} else {
    $TotalCpus = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
    if (-not $TotalCpus) { $TotalCpus = 4 }
    $BuildCpus = [Math]::Max(1, [Math]::Floor($TotalCpus / 2))
}
$env:BUILD_CPUS = $BuildCpus.ToString()

# ── Console helpers ──────────────────────────────────────────
function Step($num, $msg) {
    Write-Host "Step $num" -NoNewline -ForegroundColor Cyan
    Write-Host ": $msg" -ForegroundColor White
}

function OK($msg) {
    Write-Host "  ✓ $msg" -ForegroundColor Green
}

function Warn($msg) {
    Write-Host "  ⚠ $msg" -ForegroundColor Yellow
}

function Fail($msg) {
    Write-Host "  ✗ $msg" -ForegroundColor Red
}

function Info($msg) {
    Write-Host "    $msg" -ForegroundColor Gray
}

# ═══════════════════════════════════════════════════════════════
# Log output to file
# ═══════════════════════════════════════════════════════════════

$LogFile = Join-Path $LogDir "build.log"
$BuildStartTime = Get-Date

# We'll log manually at key points rather than tee-ing all output
function Log($msg) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp $msg" | Out-File -Append -FilePath $LogFile -Encoding utf8
}

function Invoke-GitLogged {
    param(
        [string[]]$Arguments,
        [string]$StepLabel
    )

    $gitExe = (Get-Command git -ErrorAction Stop).Source
    $stdoutPath = Join-Path $LogDir ("git-$StepLabel.stdout.log")
    $stderrPath = Join-Path $LogDir ("git-$StepLabel.stderr.log")

    Remove-Item $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue

    $proc = Start-Process -FilePath $gitExe `
        -ArgumentList $Arguments `
        -NoNewWindow `
        -Wait `
        -PassThru `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath

    [PSCustomObject]@{
        ExitCode   = $proc.ExitCode
        Stdout     = if (Test-Path $stdoutPath) { Get-Content $stdoutPath } else { @() }
        Stderr     = if (Test-Path $stderrPath) { Get-Content $stderrPath } else { @() }
        StdoutPath = $stdoutPath
        StderrPath = $stderrPath
    }
}

Log "=== BUILD STARTED $(Get-Date -Format 'o') ==="
Log "  CPUs: $BuildCpus"
Log "  KDF: $KdfCommit"
Log "  Desktop: $DesktopCommit"

# ═══════════════════════════════════════════════════════════════
# Platform detection
# ═══════════════════════════════════════════════════════════════

function Detect-Platform {
    $os = Get-CimInstance Win32_OperatingSystem
    $arch = $env:PROCESSOR_ARCHITECTURE

    Step "0/5" "Platform: Windows $($os.Version) ($arch)"

    if ($arch -ne "AMD64") {
        Fail "This build requires x86_64. Detected: $arch"
        Log "ERROR: Unsupported architecture: $arch"
        exit 1
    }

    # Detect package manager
    $global:PkgMgr = $null
    if (Get-Command choco -ErrorAction SilentlyContinue) {
        $global:PkgMgr = "choco"
        OK "Package manager: Chocolatey"
    } elseif (Get-Command winget -ErrorAction SilentlyContinue) {
        $global:PkgMgr = "winget"
        OK "Package manager: WinGet"
    } else {
        Warn "No package manager detected (choco or winget)"
        Warn "Manual installs will be needed for some tools."
        Info "Install Chocolatey: Set-ExecutionPolicy Bypass -Scope Process; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))"
    }

    Log "Platform: Windows $($os.Version) $arch, pkg: $global:PkgMgr"
}

# ═══════════════════════════════════════════════════════════════
# Dependency checking
# ═══════════════════════════════════════════════════════════════

function Test-Command($cmd, $pkg, $why, $installHint) {
    if (Get-Command $cmd -ErrorAction SilentlyContinue) {
        OK "$pkg — $why"
        return $true
    }
    Fail "$pkg is not installed — $why"
    if ($installHint) {
        Write-Host "    → Install: $installHint" -ForegroundColor Yellow
    }
    return $false
}

function Check-Deps {
    $totalMissing = 0

    Write-Host ""
    Write-Host "── Checking system dependencies ──" -ForegroundColor White
    Write-Host ""

    # ── Git ────────────────────────────────────────────────
    Write-Host "Version control:" -ForegroundColor White
    if (-not (Test-Command "git" "Git for Windows" "clone repos" `
        "choco install git -y  OR  winget install Git.Git")) {
        $totalMissing++
    }

    # ── Rust ────────────────────────────────────────────────
    Write-Host ""
    Write-Host "Rust toolchain:" -ForegroundColor White
    if (Get-Command rustup -ErrorAction SilentlyContinue) {
        OK "rustup — Rust toolchain manager"
    } else {
        Fail "rustup is not installed — Rust toolchain manager (~1.5GB)"
        Write-Host "    → Install: https://rustup.rs (download rustup-init.exe and run)" -ForegroundColor Yellow
        Write-Host "    → Or: winget install Rustlang.Rustup" -ForegroundColor Yellow
        $totalMissing++
    }

    if (Get-Command cargo -ErrorAction SilentlyContinue) {
        OK "cargo — Rust build system"
        $rustVer = rustc --version 2>$null
        if ($rustVer) { Info "$rustVer" }
    }

    # ── Build tools ────────────────────────────────────────
    Write-Host ""
    Write-Host "Build tools:" -ForegroundColor White
    if (-not (Test-Command "cmake" "CMake" "build system (4.3+)" `
        "choco install cmake -y  OR  winget install Kitware.CMake")) {
        $totalMissing++
    } else {
        # Version check
        $cmakeVer = (cmake --version 2>$null | Select-Object -First 1) -replace '.*?(\d+\.\d+).*', '$1'
        if ($cmakeVer -and ([version]$cmakeVer -lt [version]"4.3")) {
            Warn "cmake $cmakeVer is old — 4.3+ recommended for vcpkg"
        }
    }

    # ── C/C++ toolchain ────────────────────────────────────
    Write-Host ""
    Write-Host "C/C++ toolchain (for desktop wallet):" -ForegroundColor White
    $script:hasMSVC = $false
    $hasMinGW = $false

    # Check for Visual Studio / MSVC
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    $vsPath = if (Test-Path $vswhere) { & $vswhere -latest -property installationPath 2>$null } else { $null }
    if ($vsPath) {
        $vcvars = Join-Path $vsPath "VC\Auxiliary\Build\vcvars64.bat"
        if (Test-Path $vcvars) {
            OK "Visual Studio + MSVC — native C/C++ compiler"
            $script:hasMSVC = $true
        }
    }

    if (-not $script:hasMSVC) {
        # Check for VS Build Tools
        $btDir = if (Test-Path $vswhere) { & $vswhere -products Microsoft.VisualStudio.Product.BuildTools -latest -property installationPath 2>$null } else { $null }
        if ($btDir) {
            $msvcDirs = Get-ChildItem "$btDir\VC\Tools\MSVC\14*" -Directory -ErrorAction SilentlyContinue
            if ($msvcDirs) {
                OK "Visual Studio Build Tools — C/C++ compiler"
                $script:hasMSVC = $true
            }
        }
    }

    if (-not $script:hasMSVC) {
        # Check MinGW
        if (Get-Command gcc -ErrorAction SilentlyContinue) {
            OK "MinGW-w64 (gcc) — cross-compiler toolchain"
            $hasMinGW = $true
        } elseif (Get-Command x86_64-w64-mingw32-gcc -ErrorAction SilentlyContinue) {
            OK "MinGW-w64 — cross-compiler toolchain"
            $hasMinGW = $true
        }
    }

    if (-not $script:hasMSVC -and -not $hasMinGW) {
        Fail "No C/C++ toolchain found"
        Write-Host "    → For Rust-only (KDF): no C compiler needed" -ForegroundColor Yellow
        Write-Host "    → For desktop: install Visual Studio Build Tools (FREE)" -ForegroundColor Yellow
        Write-Host "      https://visualstudio.microsoft.com/downloads/#build-tools-for-visual-studio-2022" -ForegroundColor Yellow
        Write-Host "      Select: 'Desktop development with C++' workload (~6GB)" -ForegroundColor Yellow
        if (-not $KdfOnly) {
            Warn "Desktop wallet needs MSVC. Build KDF only with -KdfOnly flag."
            $totalMissing++
        }
    }

    # ── OpenSSL ────────────────────────────────────────────
    Write-Host ""
    Write-Host "Crypto:" -ForegroundColor White
    $opensslFound = $false
    if (Test-Path "C:\Program Files\OpenSSL\include\openssl\ssl.h") {
        OK "OpenSSL — TLS/crypto (C:\Program Files\OpenSSL)"
        $opensslFound = $true
    } elseif (Test-Path "C:\Program Files (x86)\OpenSSL\include\openssl\ssl.h") {
        OK "OpenSSL — TLS/crypto"
        $opensslFound = $true
    } elseif (Get-Command openssl -ErrorAction SilentlyContinue) {
        OK "OpenSSL (via PATH) — TLS/crypto"
        $opensslFound = $true
    }

    if (-not $opensslFound) {
        Warn "OpenSSL headers not found"
        Write-Host "    → KDF builds without it (Rust uses vendored openssl)" -ForegroundColor Yellow
        Write-Host "    → Desktop needs: choco install openssl -y" -ForegroundColor Yellow
    }

    # ── Protobuf ────────────────────────────────────────────
    $protocFound = Test-Command "protoc" "protobuf" "Protocol Buffers compiler" "choco install protoc -y"
    if (-not $protocFound) {
        $wingetProtoc = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.Protobuf*\bin\protoc.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($wingetProtoc) {
            $protocDir = Split-Path $wingetProtoc.FullName -Parent
            $env:Path = "$protocDir;$env:Path"
            $env:PROTOC = $wingetProtoc.FullName
            OK "protobuf — via WinGet at $protocDir"
            $protocFound = $true
        }
    }
    if (-not $protocFound) { $totalMissing++ }

    # ── Summary ─────────────────────────────────────────────
    Write-Host ""
    if ($totalMissing -gt 0) {
        Write-Host "$totalMissing dependencies missing." -ForegroundColor Yellow
    } else {
        Write-Host "All dependencies present." -ForegroundColor Green
    }

    Log "Dependency check: $totalMissing missing"
    return $totalMissing
}

# ═══════════════════════════════════════════════════════════════
# Install deps with consent
# ═══════════════════════════════════════════════════════════════

function Install-MissingDeps {
    param([int]$MissingCount)

    if ($MissingCount -eq 0) { return }

    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
    Write-Host "║  Dependencies missing. Install them now?               ║" -ForegroundColor Yellow
    Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
    Write-Host ""

    if ($global:PkgMgr -eq "choco") {
        Write-Host "  choco install git cmake protoc openssl -y" -ForegroundColor White
        Info "Rust: download from https://rustup.rs"
        Info "MSVC: download from https://visualstudio.microsoft.com/downloads/#build-tools-for-visual-studio-2022"
    } elseif ($global:PkgMgr -eq "winget") {
        Write-Host "  winget install Git.Git Kitware.CMake" -ForegroundColor White
        Info "Rust: winget install Rustlang.Rustup"
        Info "MSVC: download from https://visualstudio.microsoft.com/downloads/#build-tools-for-visual-studio-2022"
    } else {
        Write-Host "  Manual installs required — see URLs below:" -ForegroundColor White
    }

    Write-Host ""
    Write-Host "  Git:        https://git-scm.com/download/win"
    Write-Host "  Rust:       https://rustup.rs"
    Write-Host "  CMake:      https://cmake.org/download"
    Write-Host "  MSVC:       https://visualstudio.microsoft.com/downloads/#build-tools-for-visual-studio-2022"
    Write-Host "  OpenSSL:    choco install openssl    (or https://slproweb.com/products/Win32OpenSSL.html)"
    Write-Host "  Protobuf:   choco install protoc     (or https://github.com/protocolbuffers/protobuf/releases)"
    Write-Host ""

    if (-not $Yes -and -not $DryRun) {
        $answer = Read-Host "Install missing packages via $global:PkgMgr? [Y/n]"
        if ($answer -eq "n" -or $answer -eq "N") {
            Write-Host "Cannot build without dependencies. Re-run with -InstallDeps to retry."
            Log "User declined dependency install"
            exit 1
        }
    }

    if ($DryRun) {
        Write-Host "  [DRY RUN] would install packages now" -ForegroundColor Gray
        return
    }

    # Try auto-install via choco
    if ($global:PkgMgr -eq "choco") {
        choco install git cmake protoc openssl -y 2>&1 | ForEach-Object { Info $_ }
        OK "Packages installed via Chocolatey"
    } elseif ($global:PkgMgr -eq "winget") {
        winget install Git.Git --accept-package-agreements 2>&1 | ForEach-Object { Info $_ }
        winget install Kitware.CMake --accept-package-agreements 2>&1 | ForEach-Object { Info $_ }
        OK "Packages installed via WinGet"
    }

    Log "Dependencies installed via $global:PkgMgr"
}

# ═══════════════════════════════════════════════════════════════
# Build: KDF engine
# ═══════════════════════════════════════════════════════════════

function Build-Kdf {
    Step "3/5" "Cloning KDF source (pinned commit $KdfCommit)..."
    $kdfDir = Join-Path $BuildDir "kdf"

    git config --global core.longpaths true 2>&1 | Out-Null
    git config --global advice.detachedHead false 2>&1 | Out-Null

    # Use GITHUB_TOKEN for authenticated clones (avoids rate limiting on shared runners)
    if ($env:GITHUB_TOKEN) {
        $authUrl = "https://x-access-token:$env:GITHUB_TOKEN@github.com/"
    } else {
        $authUrl = $null
    }

    if (Test-Path (Join-Path $kdfDir ".git")) {
        Push-Location $kdfDir

        if ($authUrl) {
            git config url."$authUrl".insteadOf https://github.com/ 2>&1 | Out-Null
        }

        $fetchResult = Invoke-GitLogged -Arguments @('-c', 'core.longpaths=true', 'fetch', 'origin') -StepLabel 'fetch'
        if ($fetchResult.ExitCode -ne 0) {
            Pop-Location
            Fail "KDF fetch failed"
            Log "KDF fetch FAILED"
            Info "stdout → $($fetchResult.StdoutPath)"
            $fetchResult.Stdout | ForEach-Object { Info $_ }
            Info "stderr → $($fetchResult.StderrPath)"
            $fetchResult.Stderr | ForEach-Object { Info $_ }
            exit 1
        }

        $checkoutResult = Invoke-GitLogged -Arguments @('checkout', $KdfCommit) -StepLabel 'checkout'
        if ($checkoutResult.ExitCode -ne 0) {
            Pop-Location
            Fail "KDF checkout failed"
            Log "KDF checkout FAILED"
            Info "stdout → $($checkoutResult.StdoutPath)"
            $checkoutResult.Stdout | ForEach-Object { Info $_ }
            Info "stderr → $($checkoutResult.StderrPath)"
            $checkoutResult.Stderr | ForEach-Object { Info $_ }
            exit 1
        }

        $submoduleResult = Invoke-GitLogged -Arguments @('submodule', 'update', '--init', '--recursive') -StepLabel 'submodules'
        if ($submoduleResult.ExitCode -ne 0) {
            Pop-Location
            Fail "KDF submodule update failed"
            Log "KDF submodule update FAILED"
            Info "stdout → $($submoduleResult.StdoutPath)"
            $submoduleResult.Stdout | ForEach-Object { Info $_ }
            Info "stderr → $($submoduleResult.StderrPath)"
            $submoduleResult.Stderr | ForEach-Object { Info $_ }
            exit 1
        }

        Pop-Location
        OK "KDF source updated"
    } else {
        Remove-Item -Recurse -Force $kdfDir -ErrorAction SilentlyContinue

        $cloneArgs = @('-c', 'core.longpaths=true')
        if ($authUrl) {
            $cloneArgs += '-c'
            $cloneArgs += "url.$authUrl.insteadOf=https://github.com/"
        }
        $cloneArgs += 'clone'
        $cloneArgs += '--progress'
        $cloneArgs += '--verbose'
        $cloneArgs += '--no-checkout'
        $cloneArgs += $KdfRepo
        $cloneArgs += $kdfDir

        $cloneResult = Invoke-GitLogged -Arguments $cloneArgs -StepLabel 'clone'
        if ($cloneResult.ExitCode -ne 0) {
            Fail "KDF clone failed"
            Log "KDF clone FAILED"
            Info "stdout → $($cloneResult.StdoutPath)"
            $cloneResult.Stdout | ForEach-Object { Info $_ }
            Info "stderr → $($cloneResult.StderrPath)"
            $cloneResult.Stderr | ForEach-Object { Info $_ }
            exit 1
        }

        Push-Location $kdfDir

        if ($authUrl) {
            git config url."$authUrl".insteadOf https://github.com/ 2>&1 | Out-Null
        }

        $checkoutResult = Invoke-GitLogged -Arguments @('checkout', $KdfCommit) -StepLabel 'checkout'
        if ($checkoutResult.ExitCode -ne 0) {
            Pop-Location
            Fail "KDF checkout failed"
            Log "KDF checkout FAILED"
            Info "stdout → $($checkoutResult.StdoutPath)"
            $checkoutResult.Stdout | ForEach-Object { Info $_ }
            Info "stderr → $($checkoutResult.StderrPath)"
            $checkoutResult.Stderr | ForEach-Object { Info $_ }
            exit 1
        }

        $submoduleResult = Invoke-GitLogged -Arguments @('submodule', 'update', '--init', '--recursive') -StepLabel 'submodules'
        if ($submoduleResult.ExitCode -ne 0) {
            Pop-Location
            Fail "KDF submodule update failed"
            Log "KDF submodule update FAILED"
            Info "stdout → $($submoduleResult.StdoutPath)"
            $submoduleResult.Stdout | ForEach-Object { Info $_ }
            Info "stderr → $($submoduleResult.StderrPath)"
            $submoduleResult.Stderr | ForEach-Object { Info $_ }
            exit 1
        }

        Pop-Location
        OK "KDF source cloned"
    }

    $currentCommit = Push-Location $kdfDir; $c = git rev-parse --short HEAD; Pop-Location; $c
    OK "KDF at commit: $currentCommit"
    Log "KDF source at $currentCommit"

    Step "4/5" "Building KDF engine (Rust, ~10 min on $BuildCpus CPUs)..."

    Push-Location $kdfDir

    # Pick Rust target (ENV override, or auto-detect)
    $hasMsys = (Get-Command link.exe -ErrorAction SilentlyContinue) -or (Test-Path "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\BuildTools\VC\Tools\MSVC\14*\bin\Hostx64\x64\link.exe")
    if ($env:KDF_TARGET) {
        $rustTarget = $env:KDF_TARGET
        Info "KDF target from KDF_TARGET: $rustTarget"
    } elseif ($script:hasMSVC) {
        $rustTarget = "x86_64-pc-windows-msvc"
    } else {
        $rustTarget = "x86_64-pc-windows-gnu"
        Warn "No MSVC detected — using MinGW target: $rustTarget"
    }

    # Ensure target (run via cmd to avoid PS error-action issues)
    Write-Host "    → rustup target add $rustTarget"
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $installedTargets = cmd /c "rustup target list --installed 2>&1"
    $ErrorActionPreference = $prevEAP
    if ($installedTargets -match [regex]::Escape($rustTarget)) {
        Write-Host "    → target already installed, skipping"
    } else {
        Write-Host "    → installing target..."
        $prevEAP2 = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $rustupOutput = cmd /c "rustup target add $rustTarget 2>&1"
        $ErrorActionPreference = $prevEAP2
        if ($LASTEXITCODE -ne 0) {
            Write-Host "    ✗ rustup target add failed (exit $LASTEXITCODE):"
            $rustupOutput | ForEach-Object { Write-Host "      $_" }
            exit 1
        }
        Write-Host "    ✓ target installed"
    }

    $env:SOURCE_DATE_EPOCH = (git log -1 --format=%ct)

    # Set up MSVC environment if using MSVC target
    if ($rustTarget -eq "x86_64-pc-windows-msvc" -and -not $env:LIB) {
        $msvcDirs = Get-ChildItem "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\BuildTools\VC\Tools\MSVC\14*" -Directory -ErrorAction SilentlyContinue
        if ($msvcDirs) {
            $msvcRoot = $msvcDirs[-1].FullName
            $sdkDirs = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\Lib\10*" -Directory -ErrorAction SilentlyContinue
            $sdkVer = if ($sdkDirs) { $sdkDirs[-1].Name } else { $null }
            $msvcBin = "$msvcRoot\bin\Hostx64\x64"
            if (Test-Path $msvcBin) {
                $env:Path = "$msvcBin;$env:Path"
                $env:LIB = "$msvcRoot\lib\x64"
                if ($sdkVer) {
                    $sdkRoot = "${env:ProgramFiles(x86)}\Windows Kits\10"
                    $env:LIB += ";$sdkRoot\Lib\$sdkVer\ucrt\x64;$sdkRoot\Lib\$sdkVer\um\x64"
                    $env:INCLUDE = "$msvcRoot\include;$sdkRoot\Include\$sdkVer\ucrt;$sdkRoot\Include\$sdkVer\um;$sdkRoot\Include\$sdkVer\shared"
                }
            }
        }
    }

    # Find protoc
    if (-not (Get-Command protoc -ErrorAction SilentlyContinue)) {
        $protocDirs = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.Protobuf*\bin\protoc.exe" -ErrorAction SilentlyContinue
        if ($protocDirs) {
            $protocDir = Split-Path (Split-Path $protocDirs[-1].FullName -Parent) -Parent
            $env:Path = "$protocDir\bin;$env:Path"
            $env:PROTOC = "$protocDir\bin\protoc.exe"
        }
    }

    # Build
    $buildResult = cargo build --release `
        --target $rustTarget `
        -p mm2_bin_lib `
        -j $BuildCpus 2>&1

    if ($LASTEXITCODE -ne 0) {
        Fail "KDF build failed"
        Log "KDF build FAILED"
        $buildResult | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
        Pop-Location
        exit 1
    }

    OK "KDF compiled successfully"

    # Copy output
    $kdfSrc = "target\$rustTarget\release\kdf.exe"
    if (Test-Path $kdfSrc) {
        Copy-Item $kdfSrc (Join-Path $OutputDir "kdf.exe") -Force
    } else {
        # Cargo sometimes names it differently
        $found = Get-ChildItem -Path "target\$rustTarget\release" -Filter "kdf.exe" | Select-Object -First 1
        if ($found) {
            Copy-Item $found.FullName (Join-Path $OutputDir "kdf.exe") -Force
        } else {
            Fail "Could not find kdf.exe in build output"
            Pop-Location
            exit 1
        }
    }

    # SHA256
    $sha256 = (Get-FileHash -Path (Join-Path $OutputDir "kdf.exe") -Algorithm SHA256).Hash.ToLower()
    $sha256 | Out-File -FilePath (Join-Path $OutputDir "kdf.exe.sha256") -Encoding ascii -NoNewline

    $size = (Get-Item (Join-Path $OutputDir "kdf.exe")).Length
    $sizeMB = "{0:N0}" -f ($size / 1MB)
    OK "KDF built — ~${sizeMB}MB → $OutputDir\kdf.exe"
    OK "SHA256: $sha256"

    Log "KDF built: $size bytes, SHA256: $sha256"

    Pop-Location
}

# ═══════════════════════════════════════════════════════════════
# Build: Desktop wallet (guidance only — native build is complex)
# ═══════════════════════════════════════════════════════════════

function Build-Desktop {
    Step "5/5" "Desktop wallet — native Windows build guidance"

    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
    Write-Host "║  Desktop wallet on Windows needs manual setup.          ║" -ForegroundColor Yellow
    Write-Host "║  QT5 + WebEngine requires MSVC and cannot be fully      ║" -ForegroundColor Yellow
    Write-Host "║  automated in a script. See README.md for steps.    ║" -ForegroundColor Yellow
    Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
    Write-Host ""

    Write-Host "  Prerequisites:" -ForegroundColor White
    Write-Host "    1. Visual Studio 2022 with 'Desktop development with C++' (~6GB)" -ForegroundColor Gray
    Write-Host "    2. QT 5.15.2 for MSVC 2019/2022 (~3GB)" -ForegroundColor Gray
    Write-Host "       Download: https://download.qt.io/archive/qt/5.15/5.15.2/" -ForegroundColor Gray
    Write-Host "    3. CMake 4.3+ (in PATH)" -ForegroundColor Gray
    Write-Host "    4. OpenSSL for Windows" -ForegroundColor Gray
    Write-Host ""

    Write-Host "  Build steps:" -ForegroundColor White
    Write-Host "    git clone $DesktopRepo" -ForegroundColor Gray
    Write-Host "    cd komodo-wallet-desktop" -ForegroundColor Gray
    Write-Host "    git checkout $DesktopCommit" -ForegroundColor Gray
    Write-Host "    git submodule update --init --recursive" -ForegroundColor Gray
    Write-Host "" -ForegroundColor Gray
    Write-Host "    # Copy KDF (pre-built):" -ForegroundColor Gray
    Write-Host "    copy ..\output\windows\kdf.exe assets\tools\kdf\kdf.exe" -ForegroundColor Gray
    Write-Host "" -ForegroundColor Gray
    Write-Host "    # Edit CMakeLists.txt to use local KDF (same sed commands as Linux)" -ForegroundColor Gray
    Write-Host "    # Set up vcpkg (see ci_tools_atomic_dex/vcpkg-repo/)" -ForegroundColor Gray
    Write-Host "    # cmake -GNinja -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH=C:\Qt\5.15.2\msvc2019_64 .." -ForegroundColor Gray
    Write-Host "    # cmake --build . --config Release -j N" -ForegroundColor Gray
    Write-Host ""

    Warn "Desktop wallet on Windows is a manual process."
    Warn "For automated CI: use the Linux AppImage build (cross-platform distribution)."

    Log "Desktop build — manual guidance displayed"
}

# ═══════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════

function Main {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor White
    Write-Host "║  Native Windows Build" -ForegroundColor White
    Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor White
    Write-Host ""
    Write-Host "  CPUs: $BuildCpus  |  KDF: $KdfCommit  |  Desktop: $DesktopCommit" -ForegroundColor Gray
    Write-Host ""

    Step "1/5" "Detecting platform..."
    Detect-Platform

    Step "2/5" "Checking dependencies..."
    $missing = Check-Deps

    if ($InstallDeps) {
        Install-MissingDeps -MissingCount $missing
        Write-Host ""
        Write-Host "Dependencies installed. Run again without -InstallDeps to build." -ForegroundColor Green
        Log "InstallDeps completed"
        exit 0
    }

    if ($missing -gt 0) {
        Install-MissingDeps -MissingCount $missing
        # Re-check after install
        $missing = Check-Deps
        if ($missing -gt 0) {
            Write-Host ""
            Fail "Some dependencies could not be installed automatically."
            Write-Host "  Install them manually, then re-run."
            Log "Build aborted — missing dependencies"
            exit 1
        }
    }

    if ($DryRun) {
        Write-Host ""
        Write-Host "[DRY RUN] Would build:" -ForegroundColor Green
        if ($KdfOnly) { Write-Host "  → KDF engine only" -ForegroundColor Green }
        if ($DesktopOnly) { Write-Host "  → Desktop wallet guidance" -ForegroundColor Green }
        if (-not $KdfOnly -and -not $DesktopOnly) { Write-Host "  → KDF + Desktop wallet" -ForegroundColor Green }
        Write-Host ""
        Log "Dry run completed"
        exit 0
    }

    # ── Build KDF ──────────────────────────────────────────
    if (-not $DesktopOnly) {
        Build-Kdf
    }

    # ── Desktop guidance ────────────────────────────────────
    if (-not $KdfOnly) {
        Build-Desktop
    }

    # ── Done ───────────────────────────────────────────────
    $elapsed = (Get-Date) - $BuildStartTime
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "║  BUILD COMPLETE                                        ║" -ForegroundColor Green
    Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Output: $OutputDir" -ForegroundColor Gray
    Get-ChildItem $OutputDir | ForEach-Object {
        $size = "{0,10:N0}" -f $_.Length
        Write-Host "    $size bytes  $($_.Name)" -ForegroundColor Gray
    }
    Write-Host ""
    Write-Host "  Elapsed: $($elapsed.ToString('mm\:ss'))" -ForegroundColor Gray
    Write-Host "  Log:     $LogFile" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Run KDF:" -ForegroundColor White
    Write-Host "    .\output\windows\kdf.exe" -ForegroundColor Gray
    Write-Host ""

    Log "BUILD COMPLETE — elapsed: $($elapsed.ToString('mm\:ss'))"
}

# ── Entry point ───────────────────────────────────────────────
# Redirect all output to log file
try {
    Main
} catch {
    $msg = $_.Exception.Message
    Write-Host "FATAL: $msg" -ForegroundColor Red
    Log "FATAL ERROR: $msg"
    exit 1
}
