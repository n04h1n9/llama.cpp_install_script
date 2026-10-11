<#
.SYNOPSIS
    llama.cpp one-click build script -- Windows / PowerShell edition

.DESCRIPTION
    Windows-only. Toolchain: GCC/G++ (MinGW-w64) or MSVC, plus CMake and GDB.
    Flow: toolchain check -> pick backend -> build options -> clone source
          -> CMake configure -> build -> verify

.PARAMETER Toolchain
    auto (default) = prefer MSVC; fall back to GCC/G++ (MinGW-w64) when MSVC is absent
    gcc            = require GCC/G++ (MinGW-w64)
    msvc           = require MSVC (Visual Studio with the C++ workload)

.PARAMETER Backend
    Hardware backend, multi-select: CPU CUDA HIP SYCL Metal Vulkan MUSA ZenDNN CANN OpenVINO
    When omitted, an interactive menu is shown.

.PARAMETER BuildType
    Release / RelWithDebInfo / Debug / MinSizeRel
    When omitted and running interactively, you are asked to choose.

.PARAMETER Jobs
    Parallel compile jobs. When omitted and running interactively, you are asked
    to choose (the default offered is the logical core count).

.PARAMETER NoStatic
    Disable static linking. Static linking is ON by default: with GCC it adds
    -static, with MSVC it selects the non-DLL C runtime (MultiThreaded).

.PARAMETER AvxVnni
    Force -DGGML_AVX_VNNI=ON. On the MSVC path the script already detects AVX-VNNI on
    the build machine and enables it automatically; this switch is only needed when
    that detection is unavailable (Windows PowerShell 5.1).

.PARAMETER Lto
    Enable link time optimization (-DGGML_LTO=ON). Slower builds and more memory;
    gains vary by project, so it is off by default.

.PARAMETER WithTests
    Build tests and run ctest (off by default to save build time).

.PARAMETER NoVerify
    Skip post-build verification.

.PARAMETER NonInteractive
    Fully non-interactive: defaults are used instead of prompts
    (backend = CPU, build type = Release, jobs = logical core count).

.PARAMETER Force
    Ignore the pre-flight gates (incompatible backend, missing external SDK)
    and let CMake try.

.EXAMPLE
    .\llm_install.ps1
    Fully interactive: pick a backend, a build type and the job count, then build.

.EXAMPLE
    .\llm_install.ps1 -Backend CPU -Jobs 20 -BuildType Release
    Non-interactive for the options you passed.

.EXAMPLE
    .\llm_install.ps1 -Toolchain msvc -Backend CUDA
    Use MSVC, which is the only toolchain on Windows that can build the CUDA backend.

.NOTES
    The full compile flow of this script has not yet been run end-to-end on every
    toolchain combination. Run it once with -Backend CPU first.
    Tip: if you run this script directly, use PowerShell 7 (pwsh); the default
    execution policy of PowerShell 5.1 refuses to run scripts.
#>

[CmdletBinding()]
param(
    [ValidateSet('auto', 'gcc', 'msvc')]
    [string]   $Toolchain = 'auto',

    [ValidateSet('Release', 'RelWithDebInfo', 'Debug', 'MinSizeRel')]
    [string]   $BuildType,

    [ValidateSet('CPU', 'CUDA', 'HIP', 'SYCL', 'Metal', 'Vulkan', 'MUSA', 'ZenDNN', 'CANN', 'OpenVINO')]
    [string[]] $Backend,

    [string]   $SourceDir,
    [string]   $BuildDir,

    [int]      $Jobs = 0,

    [switch]   $NoLog,
    [string]   $LogFile,

    [switch]   $NoStatic,
    [switch]   $AvxVnni,
    [switch]   $Lto,
    [switch]   $WithTests,
    [switch]   $NoVerify,
    [switch]   $NonInteractive,
    [switch]   $Force
)

$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 defaults $OutputEncoding to US-ASCII, which turns any
# non-ASCII text piped to a native program into '?'. Pin it to UTF-8.
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
# The session may have started before the toolchain was installed, in which case
# its PATH is stale. PATH lives in two places (machine and user), so take both.
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')

# MSBuild's CL.exe file tracker writes temp files. If the system temp directory is
# not writable, the build fails with MSB6003 / UnauthorizedAccessException, so
# probe it once and redirect to a writable spot.
$tmpProbe = Join-Path $env:TEMP ('tmp_' + [guid]::NewGuid().ToString('N') + '.tmp')
$tmpWritable = $false
try {
    [System.IO.File]::WriteAllText($tmpProbe, 'x')
    Remove-Item $tmpProbe -Force -ErrorAction SilentlyContinue
    $tmpWritable = $true
} catch { }
if (-not $tmpWritable) {
    $altTmp = Join-Path (Get-Location).ProviderPath '.llama_tmp'
    New-Item -ItemType Directory -Path $altTmp -Force | Out-Null
    $env:TEMP = $altTmp
    $env:TMP  = $altTmp
    Write-Warning "System temp directory is not writable; using $altTmp instead"
}

# ============================================================================
#  Backend definition table
#  GCC  : works under Windows + GCC/G++ (MinGW-w64)
#  MSVC : works under Windows + MSVC (Visual Studio)
#  Values: ok = supported | warn = may work, needs an external SDK | no = blocked
# ============================================================================
$BackendDefs = [ordered]@{
    'CPU'    = @{ Flags = @('-DGGML_NATIVE=ON');                            Need = 'gcc/g++ or cl.exe';      GCC = 'ok';   MSVC = 'ok';   Desc = 'All CPUs, optimized for this machine' }
    'CUDA'   = @{ Flags = @('-DGGML_CUDA=ON');                              Need = 'CUDA Toolkit (nvcc)';     GCC = 'no';   MSVC = 'ok';   Desc = 'NVIDIA GPU (needs MSVC on Windows)' }
    'HIP'    = @{ Flags = @('-DGGML_HIP=ON');                               Need = 'ROCm / HIP SDK';          GCC = 'no';   MSVC = 'warn'; Desc = 'AMD GPU' }
    'ZenDNN' = @{ Flags = @('-DGGML_ZENDNN=ON');                            Need = 'ZenDNN SDK';              GCC = 'warn'; MSVC = 'warn'; Desc = 'AMD CPU (Zen)' }
    'SYCL'   = @{ Flags = @('-DGGML_SYCL=ON');                              Need = 'Intel oneAPI (icpx)';     GCC = 'no';   MSVC = 'no';   Desc = 'Intel GPU / CPU (needs the oneAPI icpx compiler)' }
    'Metal'  = @{ Flags = @('-DGGML_METAL=ON');                             Need = 'macOS';                   GCC = 'no';   MSVC = 'no';   Desc = 'Apple GPU (macOS only)' }
    'CANN'   = @{ Flags = @('-DGGML_CANN=ON');                              Need = 'CANN Toolkit + Ascend NPU'; GCC = 'no'; MSVC = 'no';   Desc = 'Huawei Ascend (backend is Linux-only)' }
    'MUSA'   = @{ Flags = @('-DGGML_MUSA=ON', '-DGGML_MUSA_MUDNN_COPY=ON'); Need = 'MUSA SDK';                GCC = 'no';   MSVC = 'warn'; Desc = 'Moore Threads GPU' }
    'Vulkan' = @{ Flags = @('-DGGML_VULKAN=ON');                            Need = 'Vulkan SDK (glslc)';      GCC = 'ok';   MSVC = 'ok';   Desc = 'Any Vulkan GPU (NVIDIA/AMD/Intel)' }
    'OpenVINO' = @{ Flags = @('-DGGML_OPENVINO=ON');                          Need = 'OpenVINO Runtime + OpenCL'; GCC = 'warn'; MSVC = 'warn'; Desc = 'Intel CPU / GPU / NPU (AI Boost)' }
}

# Menu order
$MenuOrder = @('CPU', 'CUDA', 'HIP', 'ZenDNN', 'SYCL', 'Metal', 'CANN', 'MUSA', 'Vulkan', 'OpenVINO')

# ============================================================================
#  Output helpers
# ============================================================================
function Write-Section ([string]$Text) {
    Write-Log ''
    Write-Log "==== $Text " -ForegroundColor Cyan -NoNewline
    Write-Log ('=' * [Math]::Max(2, 60 - $Text.Length)) -ForegroundColor Cyan
}
function Write-Ok   ([string]$Text) { Write-Log "  [ ok ] $Text" -ForegroundColor Green }
function Write-Warn ([string]$Text) { Write-Log "  [warn] $Text" -ForegroundColor Yellow }
function Write-Bad  ([string]$Text) { Write-Log "  [FAIL] $Text" -ForegroundColor Red }
function Write-Note ([string]$Text) { Write-Log "         $Text" -ForegroundColor DarkGray }

function Get-ToolPath ([string]$Name) {
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-CMakeVersion {
    $line = (& cmake --version 2>&1 | Select-Object -First 1)
    if ("$line" -match '(\d+\.\d+(\.\d+)?)') { return [version]$Matches[1] }
    return $null
}

# Query whether the CPU supports an instruction set extension. Only .NET 5+ exposes
# System.Runtime.Intrinsics; Windows PowerShell 5.1 does not, and this then returns
# $null meaning "unknown" - callers must treat that as unknown, never as supported.
function Get-IntrinsicSupported ([string]$TypeName) {
    $full = "System.Runtime.Intrinsics.X86.$TypeName"
    $t = $null
    try { $t = [System.Type]::GetType("$full, System.Runtime.Intrinsics") } catch { }
    if (-not $t) {
        foreach ($a in [AppDomain]::CurrentDomain.GetAssemblies()) {
            $t = $a.GetType($full)
            if ($t) { break }
        }
    }
    if (-not $t) { return $null }
    $p = $t.GetProperty('IsSupported')
    if (-not $p) { return $null }
    return [bool]$p.GetValue($null)
}

# Locate vswhere.exe. Besides the two standard locations, accept one already on PATH.
# Visual Studio may live elsewhere, and the Installer's registered location may not be
# one of the default paths.
function Get-VsWherePath {
    $candidates = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft Visual Studio\Installer\vswhere.exe')
    )
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    $cmd = Get-Command 'vswhere' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

# Locate a Visual Studio install that carries the C++ toolset
function Get-VisualStudioPath {
    $vswhere = Get-VsWherePath
    if ($vswhere) {
        $p = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
        if ($p) { return ("$p").Trim() }
    }
    # Fallback: vswhere is itself part of the VS Installer, so it can be missing
    # (uninstalled, trimmed, moved). Visual Studio records every instance under
    # ProgramData; read that directly. The registry is NOT usable here - since the
    # 2017 installer model it keeps no install path at all.
    $instRoot = Join-Path $env:ProgramData 'Microsoft\VisualStudio\Packages\_Instances'
    if (Test-Path $instRoot) {
        foreach ($d in (Get-ChildItem $instRoot -Directory -ErrorAction SilentlyContinue)) {
            $sj = Join-Path $d.FullName 'state.json'
            if (-not (Test-Path $sj)) { continue }
            try {
                $s = Get-Content $sj -Raw | ConvertFrom-Json
                if ($s.installationPath -and (Test-Path $s.installationPath)) { return [string]$s.installationPath }
            } catch { }
        }
    }
    return $null
}

# Map a Visual Studio install path to the CMake generator name
function Get-VisualStudioGenerator {
    # Derive the generator from the version vswhere reports, not from the install
    # path: Visual Studio can live anywhere (C:\VS2022, D:\Tools\VS), so matching
    # the path breaks on custom install locations.
    $vswhere = Get-VsWherePath
    if (-not $vswhere) { return $null }
    $ver = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationVersion 2>$null
    if (-not $ver) { return $null }
    $major = ([string]$ver).Trim().Split('.')[0]
    switch ($major) {
        '18' { return 'Visual Studio 18 2026' }
        '17' { return 'Visual Studio 17 2022' }
        '16' { return 'Visual Studio 16 2019' }
        '15' { return 'Visual Studio 15 2017' }
    }
    return $null
}

# ============================================================================
#  Logging: every line goes to the console AND to llm_install.log, identically
# ============================================================================
$script:LogPath = $null
$script:LogEncoding = [System.Text.UTF8Encoding]::new($false)
if (-not $NoLog) {
    if (-not $LogFile) { $LogFile = Join-Path $PSScriptRoot 'llm_install.log' }
    $LogFile = [System.IO.Path]::GetFullPath($LogFile)
    try {
        # overwrite on each run. No handle is kept open, so the log file can be
        # deleted or moved at any time, even while this script is still running.
        # (an interrupted run therefore does not keep the log file locked)
        [System.IO.File]::WriteAllText($LogFile, '', $script:LogEncoding)
        $script:LogPath = $LogFile
    }
    catch {
        Write-Warning "Could not open the log file $LogFile : $($_.Exception.Message)"
    }
}

# Print to the console and append the same text to the log file
function Write-Log ([string]$Text, [string]$ForegroundColor, [switch]$NoNewline) {
    if ($ForegroundColor) { Write-Host $Text -ForegroundColor $ForegroundColor -NoNewline:$NoNewline }
    else { Write-Host $Text -NoNewline:$NoNewline }
    if ($script:LogPath) {
        $chunk = if ($NoNewline) { $Text } else { $Text + [Environment]::NewLine }
        try { [System.IO.File]::AppendAllText($script:LogPath, $chunk, $script:LogEncoding) } catch { }
    }
}
# Native tools routinely print normal progress text to stderr. Under
# $ErrorActionPreference = 'Stop', Windows PowerShell 5.1 turns that into a
# terminating RemoteException, so relax the preference while the child runs.
function Invoke-External ([scriptblock]$Command) {
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Command 2>&1 | ForEach-Object {
            # Native stderr arrives as an ErrorRecord here; take its message text
            # instead of letting it stringify to the exception type name.
            $line = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { "$_" }
            Write-Log $line
        }
    }
    finally {
        $ErrorActionPreference = $saved
    }
}
# ============================================================================
#  0. Default parameter values
# ============================================================================
if (-not $SourceDir) {
    # Anchored on the CURRENT WORKING DIRECTORY: wherever you run it, the source lands there
    $cwd = (Get-Location).ProviderPath
    if ((Test-Path (Join-Path $cwd 'CMakeLists.txt')) -and (Test-Path (Join-Path $cwd 'ggml'))) {
        # The current directory already IS a llama.cpp source tree
        $SourceDir = $cwd
    }
    else {
        # <cwd>\llama.cpp-src; a later step clones into it when missing
        $SourceDir = Join-Path $cwd 'llama.cpp-src'
    }
}
$SourceDir = [System.IO.Path]::GetFullPath($SourceDir)

Write-Log ''
Write-Log '============================================================'  -ForegroundColor DarkCyan
Write-Log '  llama.cpp build script  --  Windows / PowerShell edition'    -ForegroundColor DarkCyan
Write-Log '  toolchain: GCC/G++ (MinGW-w64) or MSVC  +  CMake'             -ForegroundColor DarkCyan
Write-Log '============================================================'  -ForegroundColor DarkCyan
Write-Note "Source dir : $SourceDir"
if ($script:LogPath) { Write-Note "Log file   : $LogFile" }

# ============================================================================
#  1. Toolchain check
# ============================================================================
Write-Section '1/8 Toolchain check'

# --- CMake itself is required either way ---
$missing = @()
$cmakePath = Get-ToolPath 'cmake'
if ($cmakePath) {
    Write-Ok "cmake  ->  $cmakePath"
    $cv = Get-CMakeVersion
    if ($cv -and $cv -ge [version]'3.14') { Write-Ok "cmake version $cv (>= 3.14 OK)" }
    else { Write-Bad "cmake version $cv is too old; llama.cpp requires >= 3.14"; $missing += 'cmake-version' }
}
else {
    Write-Bad 'cmake  missing'
    Write-Note 'winget install --id Kitware.CMake -e      (or use the cmake bundled with Visual Studio)'
    $missing += 'cmake'
}
# git is only needed to clone the source automatically; a missing git is fine
# when the source tree already exists
$gitPath = Get-ToolPath 'git'
if ($gitPath) { Write-Ok "git  ->  $gitPath" }
else { Write-Warn 'git not found (only needed to clone the source automatically)' }

# --- GCC availability ---
$gccPath = Get-ToolPath 'gcc'
$gxxPath = Get-ToolPath 'g++'
$gdbPath = Get-ToolPath 'gdb'
$gccReady = [bool]($gccPath -and $gxxPath)

# --- MSVC availability ---
$vsPath = $null
$vsGenerator = $null
$vsCl = $null
if ($Toolchain -ne 'gcc') {
    $vsPath = Get-VisualStudioPath
    if ($vsPath) {
        $vsGenerator = Get-VisualStudioGenerator
        $vsCl = Get-ChildItem (Join-Path $vsPath 'VC\Tools\MSVC') -Directory -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending |
                ForEach-Object { Join-Path $_.FullName 'bin\Hostx64\x64\cl.exe' } |
                Where-Object { Test-Path $_ } |
                Select-Object -First 1
    }
}
$msvcReady = [bool]($vsPath -and $vsGenerator -and $vsCl)
# --- Intel oneAPI (SYCL) availability ---
$oneApiCompiler = $null
foreach ($c in 'icpx', 'icx', 'dpcpp') {
    $p = Get-ToolPath $c
    if ($p) { $oneApiCompiler = $p; break }
}
$oneApiReady = [bool]$oneApiCompiler

# --- CUDA Toolkit (nvcc) availability ---
$nvccPath = Get-ToolPath 'nvcc'
if (-not $nvccPath) {
    $cudaRoot = Join-Path $env:ProgramFiles 'NVIDIA GPU Computing Toolkit\CUDA'
    if (Test-Path $cudaRoot) {
        $nvccPath = Get-ChildItem $cudaRoot -Directory -ErrorAction SilentlyContinue |
                    Sort-Object Name -Descending |
                    ForEach-Object { Join-Path $_.FullName 'bin\nvcc.exe' } |
                    Where-Object { Test-Path $_ } |
                    Select-Object -First 1
    }
}
$cudaReady = [bool]$nvccPath

# --- Vulkan SDK availability ---
$glslcPath = Get-ToolPath 'glslc'
$vulkanReady = [bool]($env:VULKAN_SDK -or $glslcPath)

# --- Intel OpenVINO (CPU / GPU / NPU) availability ---
# ggml-openvino/CMakeLists.txt: find_package(OpenVINO REQUIRED COMPONENTS Runtime Threading)
# and find_package(OpenCL REQUIRED).
# setupvars.ps1 exports INTEL_OPENVINO_DIR (the package root) and OpenVINO_DIR (which
# points at <root>/runtime/cmake), and prepends the runtime DLLs to PATH. It must be
# sourced before CMake can find OpenVINO, so the setup script is located here.
$ovRoot = $env:INTEL_OPENVINO_DIR
if (-not $ovRoot -and $env:OpenVINO_DIR) {
    # OpenVINO_DIR is <root>/runtime/cmake, so walk back two levels
    $ovRoot = Split-Path (Split-Path $env:OpenVINO_DIR -Parent) -Parent
}
if (-not $ovRoot) {
    $cands = @()
    foreach ($c in 'C:\Intel\openvino', "$env:ProgramFiles\Intel", "${env:ProgramFiles(x86)}\Intel") {
        if (Test-Path $c) { $cands += @(Get-ChildItem $c -Directory -Filter 'openvino*' -ErrorAction SilentlyContinue) }
    }
    # winget / MSIX packages land under WindowsApps
    $cands += @(Get-ChildItem 'C:\Program Files\WindowsApps' -Directory -Filter 'Intel.OpenVINOToolkit*' -ErrorAction SilentlyContinue)
    $hit = $cands | Where-Object { Test-Path (Join-Path $_.FullName 'setupvars.ps1') } | Sort-Object Name -Descending | Select-Object -First 1
    if ($hit) { $ovRoot = $hit.FullName }
}
$ovSetup = $null
if ($ovRoot -and (Test-Path (Join-Path $ovRoot 'setupvars.ps1'))) { $ovSetup = Join-Path $ovRoot 'setupvars.ps1' }
$openvinoReady = [bool]($ovRoot -and (Test-Path $ovRoot))
# ggml-openvino requires OpenCL, and FindOpenCL needs BOTH the headers (CL/cl.h plus
# CL/cl2.hpp for the C++ bindings) and an import library (OpenCL.lib). A runtime
# OpenCL.dll alone is not enough. OpenVINO does not require CUDA, so a standalone
# OpenCL (vcpkg, or the Khronos headers + ICD loader) is preferred; CUDA is only a
# last-resort fallback because its bundled headers lack cl2.hpp.
$openclInc = $null; $openclLib = $null
$oclRoots = @()
if ($env:OpenCL_ROOT) { $oclRoots += $env:OpenCL_ROOT }
$vcpkgRoots = @()
if ($env:VCPKG_ROOT) { $vcpkgRoots += $env:VCPKG_ROOT }
$vcpkgRoots += @('C:\vcpkg', "$env:USERPROFILE\vcpkg", "$env:USERPROFILE\source\vcpkg")
foreach ($v in ($vcpkgRoots | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique)) {
    $oclRoots += @(Get-ChildItem (Join-Path $v 'installed') -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
}
$oclRoots += @('C:\opencl', "$env:ProgramFiles\OpenCL", "${env:ProgramFiles(x86)}\OpenCL")
if ($nvccPath) { $oclRoots += (Split-Path (Split-Path $nvccPath -Parent) -Parent) }
foreach ($r in ($oclRoots | Where-Object { $_ } | Select-Object -Unique)) {
    if (-not $openclInc) {
        foreach ($inc in (Join-Path $r 'include'), (Join-Path $r 'Include')) {
            if ((Test-Path (Join-Path $inc 'CL\cl2.hpp')) -and (Test-Path (Join-Path $inc 'CL\cl.h'))) { $openclInc = $inc; break }
        }
    }
    if (-not $openclLib) {
        foreach ($lib in (Join-Path $r 'lib\OpenCL.lib'), (Join-Path $r 'lib\x64\OpenCL.lib'), (Join-Path $r 'OpenCL.lib')) {
            if (Test-Path $lib) { $openclLib = $lib; break }
        }
    }
    if ($openclInc -and $openclLib) { break }
}
$openclReady = [bool]($openclInc -and $openclLib)

# --- Intel NPU (AI Boost) hardware ---
# ggml-openvino can target the NPU via GGML_OPENVINO_DEVICE=NPU. pnputil is used
# instead of CIM because Win32_PnPEntity is not always queryable.
$npuPresent = $false
try {
    $npuOut = & pnputil /enum-devices /class ComputeAccelerator 2>$null | Out-String
    $npuPresent = [bool]($npuOut -match 'Intel\(R\) AI Boost')
} catch { }
# --- AMD GPU (HIP / ROCm) availability ---
# per ggml-hip/CMakeLists.txt: it reads ROCM_PATH only, and requires ROCm/HIP >= 6.1
$hipRoot = $env:ROCM_PATH
$hipCompiler = Get-ToolPath 'hipcc'; if (-not $hipCompiler) { $hipCompiler = Get-ToolPath 'hipconfig' }
$hipDir = 'C:\Program Files\AMD\ROCm'
$hipReady = [bool]($hipRoot -or $hipCompiler -or (Test-Path $hipDir))

# --- AMD CPU (ZenDNN) availability ---
$zendnnRoot = $env:ZENDNN_ROOT
$zendnnDir = 'C:\Program Files\AMD\ZenDNN'
$zendnnReady = [bool]($zendnnRoot -or (Test-Path $zendnnDir))

# --- Moore Threads GPU (MUSA) availability ---
# ggml-musa/CMakeLists.txt reads MUSA_PATH and nothing else. Do not guess from a
# compiler name: "mcc" is also MATLAB's compiler, which made machines with no
# Moore Threads hardware report MUSA as available.
$musaRoot = $env:MUSA_PATH
$musaReady = [bool]($musaRoot -and (Test-Path $musaRoot))

# Backend availability is decided by what is ACTUALLY installed, not by a static table
function Get-BackendState ([string]$Name) {
    switch ($Name) {
        'CUDA' {
            if (-not $cudaReady) { return 'need-sdk' }
            if ($script:use -eq 'gcc') { return 'no' }
            return 'ok'
        }
        'SYCL' {
            if (-not $oneApiReady) { return 'need-sdk' }
            return 'ok'
        }
        'HIP' {
            if (-not $hipReady) { return 'need-sdk' }
            return 'ok'
        }
        'ZenDNN' {
            # per ggml-zendnn/CMakeLists.txt: an empty ZENDNN_ROOT makes the build
            # download and compile ZenDNN itself, so this is not a hard blocker
            if ($zendnnReady) { return 'ok' }
            return 'warn'
        }
        'MUSA' {
            if (-not $musaReady) { return 'need-sdk' }
            return 'ok'
        }
        'OpenVINO' {
            if (-not $openvinoReady) { return 'need-sdk' }
            return 'ok'
        }
        'Vulkan' {
            if (-not $vulkanReady) { return 'need-sdk' }
            return 'ok'
        }
        default {
            if ($script:use -eq 'gcc') { return $BackendDefs[$Name].GCC }
            return $BackendDefs[$Name].MSVC
        }
    }
}

# --- pick one: MSVC first, GCC as the fallback ---
$use = $null
if ($Toolchain -eq 'gcc') {
    if ($gccReady) { $use = 'gcc' }
}
elseif ($Toolchain -eq 'msvc') {
    if ($msvcReady) { $use = 'msvc' }
}
else {
    if ($msvcReady) { $use = 'msvc' }
    elseif ($gccReady) { $use = 'gcc' }
}

# --- report ---
Write-Log ''
Write-Log '  GCC/G++ (MinGW-w64):' -ForegroundColor DarkGray
if ($gccPath) { Write-Ok "gcc  ->  $gccPath" } else { Write-Warn 'gcc  not found' }
if ($gxxPath) { Write-Ok "g++  ->  $gxxPath" } else { Write-Warn 'g++  not found' }
if ($gdbPath) { Write-Ok "gdb  ->  $gdbPath" } else { Write-Warn 'gdb  not found (only needed for debugging)' }

Write-Log ''
Write-Log '  MSVC (Visual Studio):' -ForegroundColor DarkGray
if ($vsPath)      { Write-Ok "Visual Studio  ->  $vsPath" } else { Write-Warn 'Visual Studio with the C++ workload not found' }
if ($vsGenerator) { Write-Ok "VS generator   ->  $vsGenerator (used only when ninja is absent)" }
if ($vsCl)        { Write-Ok "cl.exe         ->  $vsCl" }
Write-Log ''
Write-Log '  SDKs needed by the optional backends:' -ForegroundColor DarkGray
if ($cudaReady)   { Write-Ok "CUDA Toolkit  ->  $nvccPath" }       else { Write-Warn 'CUDA Toolkit  not installed (required by the CUDA backend; a GPU driver is not enough)' }
if ($oneApiReady) { Write-Ok "Intel oneAPI  ->  $oneApiCompiler" } else { Write-Warn 'Intel oneAPI  not installed (required by the SYCL backend)' }
if ($vulkanReady) { Write-Ok "Vulkan SDK    ->  $(if ($env:VULKAN_SDK) { $env:VULKAN_SDK } else { $glslcPath })" } else { Write-Warn 'Vulkan SDK    not installed (required by the Vulkan backend)' }
if ($hipReady)    { Write-Ok "AMD ROCm/HIP  ->  $(if ($hipCompiler) { $hipCompiler } else { $hipRoot })" } else { Write-Warn 'AMD ROCm/HIP   not installed (required by the HIP backend; Windows support is limited)' }
if ($zendnnReady) { Write-Ok "AMD ZenDNN    ->  $zendnnRoot" }  else { Write-Warn 'AMD ZenDNN     ZENDNN_ROOT not set (the build downloads and compiles it, takes a while)' }
if ($musaReady)   { Write-Ok "Moore Threads ->  $musaRoot" } else { Write-Warn 'Moore Threads  not installed (required by the MUSA backend)' }
if ($openvinoReady) { Write-Ok "Intel OpenVINO ->  $ovRoot"; if (-not $openclReady) { Write-Warn 'OpenCL not found; ggml-openvino also needs find_package(OpenCL)' } } else { Write-Warn 'Intel OpenVINO  not installed (required by the OpenVINO backend; enables Intel NPU)' }
if ($npuPresent)   { Write-Ok "Intel AI Boost ->  NPU detected (usable via the OpenVINO backend)" }

Write-Log ''
switch ($use) {
    'gcc'  { Write-Ok 'Selected toolchain: GCC/G++ (MinGW-w64)' }
    'msvc' { Write-Ok 'Selected toolchain: MSVC (Visual Studio)' }
    default {
        Write-Bad 'No usable toolchain found: need either GCC/G++ or MSVC.'
        Write-Note 'Option A (GCC / MinGW-w64):'
        Write-Note '  MSYS2 UCRT64: pacman -S mingw-w64-ucrt-x86_64-gcc mingw-w64-ucrt-x86_64-gdb'
        Write-Note '  or a portable w64devkit / WinLibs package, then put its bin on PATH'
        Write-Note 'Option B (MSVC):'
        Write-Note '  install Visual Studio (or Build Tools) with the "Desktop development with C++" workload'
        Write-Log ''
        exit 1
    }
}

if ($use -eq 'gcc' -and -not $gdbPath) {
    Write-Warn 'gdb is missing: fine for building, but -BuildType Debug/RelWithDebInfo will have nothing to debug with'
}

# --- Generator selection: prefer ninja in all three cases ---
# Ninja may be unable to create child processes in a restricted environment (a sandbox,
# or some security software). It then hangs forever on the first try_compile during
# configure, with no error at all. So probe once with a minimal task first, and fall
# back to another generator if ninja cannot spawn: degrade, never hang silently.
function Test-NinjaSpawn ([string]$NinjaPath) {
    $probeDir = Join-Path ([System.IO.Path]::GetTempPath()) ('ninja_probe_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $probeDir -Force -ErrorAction SilentlyContinue | Out-Null
    try {
        Set-Content -LiteralPath (Join-Path $probeDir 'build.ninja') -Encoding ascii -Value @'
rule probe
  command = cmd /c echo ok > probe.txt
build probe.txt: probe
'@
        $proc = Start-Process -FilePath $NinjaPath -ArgumentList 'probe.txt' -WorkingDirectory $probeDir -PassThru -WindowStyle Hidden
        if (-not $proc.WaitForExit(20000)) { try { $proc.Kill() } catch { }; return $false }
        return (Test-Path -LiteralPath (Join-Path $probeDir 'probe.txt'))
    }
    catch { return $false }
    finally { Remove-Item -LiteralPath $probeDir -Recurse -Force -ErrorAction SilentlyContinue }
}

$generator = $null
$useNinja = $false
$ninjaPath = Get-ToolPath 'ninja'
$ninjaUsable = $false
if ($ninjaPath) {
    $ninjaUsable = Test-NinjaSpawn $ninjaPath
    if (-not $ninjaUsable) {
        Write-Warn 'ninja cannot spawn child processes (restricted sandbox or security software); not using Ninja this run'
        Write-Note 'This normally does not happen when the script runs from a regular desktop terminal'
    }
}
if ($use -eq 'gcc') {
    if ($ninjaUsable) {
        $generator = 'Ninja'; $useNinja = $true; Write-Ok "ninja  ->  $ninjaPath"
    }
    else {
        $makePath = Get-ToolPath 'mingw32-make'
        if (-not $makePath) { $makePath = Get-ToolPath 'make' }
        if ($makePath) {
            $generator = 'MinGW Makefiles'; Write-Ok "make  ->  $makePath"
        }
        else {
            Write-Bad 'the GCC path has no usable generator: ninja is unusable here and neither mingw32-make nor make was found'
            Write-Note 'MSYS2 UCRT64: pacman -S mingw-w64-ucrt-x86_64-ninja'
            $missing += 'ninja-or-make'
        }
    }
}
else {
    # MSVC also prefers Ninja. The Visual Studio generator drives MSBuild, and MSBuild
    # has a batch of problems under high parallelism: named semaphores (MSB4018),
    # shared-directory creation races (MSB3191), the file tracker failing to write its
    # tracking file (MSB6003), and linker temp files (LNK1104). Ninja uses atomic
    # directory creation and creates none of those kernel objects, sidestepping all of
    # them at once.
    if ($ninjaUsable) {
        $generator = 'Ninja'
        $useNinja = $true
        Write-Ok "ninja  ->  $ninjaPath"
    }
    else {
        $generator = $vsGenerator
        Write-Ok "Generator      ->  $vsGenerator (no usable ninja, staying on MSBuild)"
    }
}

# When Ninja drives MSVC, the Visual Studio developer environment must be imported first.
# The Visual Studio generator is driven by MSBuild, which brings the full environment
# (INCLUDE / LIB / PATH all pointing into the Windows SDK). Ninja only gets a bare cl.exe
# path from us, so the link step cannot find the resource compiler or the manifest tool:
#     RC Pass 1: command "rc /fo .../manifest.res ..." failed
#     no such file or directory
# vcvars64.bat exists precisely to set that environment up; import its result here.
if ($useNinja -and $use -ne 'gcc') {
    $vcvars = Join-Path $vsPath 'VC\Auxiliary\Build\vcvars64.bat'
    if (Test-Path -LiteralPath $vcvars) {
        $dump = & cmd /c "`"$vcvars`" >nul 2>&1 && set" 2>$null
        $imported = 0
        foreach ($line in $dump) {
            if ($line -match '^([^=]+)=(.*)$') {
                [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process')
                $imported++
            }
        }
        Write-Ok "vcvars64.bat  ->  imported $imported environment variables"
    }
    else {
        Write-Warn "vcvars64.bat not found; Ninja may fail to link for lack of rc.exe / mt.exe"
        Write-Note "Expected at: $vcvars"
    }
}

if ($missing.Count -gt 0) {
    Write-Log ''
    Write-Bad ("Missing required components: " + ($missing -join ', '))
    Write-Log '  Install them and run this script again.' -ForegroundColor Yellow
    exit 1
}

# ============================================================================
#  2. Pick the hardware backend
# ============================================================================
Write-Section '2/8 Hardware backend'

if (-not $Backend -or $Backend.Count -eq 0) {
    if ($NonInteractive) {
        $Backend = @('CPU')
        Write-Note '-NonInteractive without -Backend: assuming CPU'
    }
    else {
        Write-Log ''
        Write-Log "  availability shown for the selected toolchain ($use)" -ForegroundColor DarkGray
        for ($i = 0; $i -lt $MenuOrder.Count; $i++) {
            $n = $MenuOrder[$i]
            $d = $BackendDefs[$n]
            $state = Get-BackendState $n
            # need-sdk is shown as "not usable" here; 1/8 already reported what is missing
            $tag = switch ($state) { 'ok' { '[usable  ]' } 'warn' { '[unclear ]' } default { '[NOT USABLE]' } }
            $col = switch ($state) { 'ok' { 'Green' } 'warn' { 'Yellow' } default { 'DarkGray' } }
            $desc = $d.Desc
            if ($state -eq 'need-sdk') { $desc = "$desc (missing $($d.Need))" }
            Write-Log ("  {0,2}) {1,-8} {2}  {3}" -f ($i + 1), $n, $tag, $desc) -ForegroundColor $col
        }
        Write-Log ''
        while ($true) {
            $raw = Read-Host 'Enter number(s), space separated; default 1; press q to quit'
            if ($raw -and $raw.Trim() -eq 'q') { Write-Log ''; Write-Log '  Aborted by user.' -ForegroundColor Yellow; exit 0 }
            if ([string]::IsNullOrWhiteSpace($raw)) { $Backend = @('CPU'); break }
            $picked = @(); $bad = $false
            foreach ($tok in ($raw -split '\s+' | Where-Object { $_ })) {
                $num = 0
                if (-not [int]::TryParse($tok, [ref]$num) -or $num -lt 1 -or $num -gt $MenuOrder.Count) { $bad = $true; break }
                $picked += $MenuOrder[$num - 1]
            }
            if (-not $bad -and $picked.Count -gt 0) { $Backend = ($picked | Select-Object -Unique); break }
            Write-Warn 'Invalid input, try again'
        }
    }
}

Write-Ok ("Selected backend(s): " + ($Backend -join ', '))

# --- pre-flight gates: toolchain incompatibility, then missing external SDKs ---
$blocked = @()   # the selected toolchain cannot build it at all
$needSdk = @()   # needs an external SDK that is not installed

foreach ($b in $Backend) {
    $d = $BackendDefs[$b]
    if (-not $d) { Write-Bad "Unknown backend: $b"; exit 1 }
    $state = Get-BackendState $b
    if ($state -eq 'no') { $blocked += $b; continue }
    if ($state -eq 'need-sdk') { $needSdk += $b }
}

if ($blocked.Count -gt 0 -and -not $Force) {
    Write-Log ''
    Write-Bad ("These backends cannot be built with the selected toolchain ($use): " + ($blocked -join ', '))
    if ($use -eq 'gcc' -and ($blocked -contains 'CUDA')) {
        Write-Note 'Why CUDA fails under GCC: on Windows nvcc accepts only MSVC / clang as host compiler, not MinGW.'
        Write-Note 'Fix: re-run this script with  -Toolchain msvc  (MSVC can build the CUDA backend).'
    }
    if ($blocked -contains 'SYCL') {
        Write-Note 'Why SYCL fails: it needs the Intel oneAPI icpx (DPC++) compiler.'
        Write-Note 'GCC and MSVC have no SYCL support at all, so no flag can turn it on here.'
    }
    if ($blocked -contains 'CANN') { Write-Note 'CANN: Linux + Ascend NPU only; not available on Windows at all.' }
    if ($blocked -contains 'Metal') { Write-Note 'Metal: macOS only.' }
    Write-Note 'Alternatives:'
    Write-Note '  a) switch toolchain:  -Toolchain gcc   or   -Toolchain msvc'
    Write-Note '  b) move to WSL2 (Linux), where nvcc + GCC is the officially supported pair'
    Write-Note '  c) for GPU work without CUDA, try the Vulkan backend (needs the Vulkan SDK)'
    Write-Note 'To hand it to CMake anyway, add -Force'
    exit 1
}

if ($needSdk.Count -gt 0 -and -not $Force) {
    Write-Log ''
    Write-Bad ("These backends need an external SDK that is not installed: " + ($needSdk -join ', '))
    if ($needSdk -contains 'CUDA') {
        Write-Note 'CUDA needs the NVIDIA CUDA Toolkit, which provides nvcc:'
        Write-Note '  https://developer.nvidia.com/cuda-downloads'
        Write-Note 'A graphics driver is NOT the Toolkit: the driver runs games, it has no nvcc.'
        Write-Note 'CUDA also requires MSVC on Windows: add  -Toolchain msvc'
    }
    if ($needSdk -contains 'SYCL') {
        Write-Note 'SYCL needs the Intel oneAPI DPC++ compiler (icx / icpx):'
        Write-Note '  https://www.intel.com/content/www/us/en/developer/tools/oneapi/dpc-compiler.html'
    }
    if ($needSdk -contains 'OpenVINO') {
        Write-Note 'OpenVINO needs Intel''s OpenVINO Runtime (lets llama.cpp use the Intel NPU / GPU / CPU):'
        Write-Note '  https://docs.openvino.ai/'
        Write-Note 'After installing, run setupvars.bat, then pick a device with GGML_OPENVINO_DEVICE=NPU.'
    }
    if ($needSdk -contains 'Vulkan') {
        Write-Note 'Vulkan needs the LunarG Vulkan SDK (headers, libs and the glslc shader compiler):'
        Write-Note '  https://vulkan.lunarg.com/sdk/home'
        Write-Note 'The installer sets VULKAN_SDK and adds glslc to PATH; reopen the terminal afterwards.'
    }
    Write-Note 'To hand it to CMake anyway, add -Force'
    exit 1
}

# ============================================================================
#  3. Build options (interactive unless already given on the command line)
# ============================================================================
Write-Section '3/8 Build options'

if (-not $NonInteractive) {
    # --- build type ---
    if (-not $PSBoundParameters.ContainsKey('BuildType')) {
        Write-Log ''
        Write-Log '  Build type:' -ForegroundColor DarkGray
        Write-Log '    1) Release         optimized, no debug info (default)'
        Write-Log '    2) RelWithDebInfo  optimized + debug symbols (for GDB)'
        Write-Log '    3) Debug           no optimization + debug symbols (slow)'
        Write-Log '    4) MinSizeRel      smallest binaries'
        $map = [ordered]@{ '1' = 'Release'; '2' = 'RelWithDebInfo'; '3' = 'Debug'; '4' = 'MinSizeRel' }
        while ($true) {
            $raw = Read-Host 'Choose 1-4; default 1; press q to quit'
            if ($raw -and $raw.Trim() -eq 'q') { Write-Log ''; Write-Log '  Aborted by user.' -ForegroundColor Yellow; exit 0 }
            if ([string]::IsNullOrWhiteSpace($raw)) { $BuildType = 'Release'; break }
            $key = $raw.Trim()
            if ($map.Contains($key)) { $BuildType = $map[$key]; break }
            Write-Warn 'Invalid input, try again'
        }
    }

    # --- parallel jobs ---
    if (-not $PSBoundParameters.ContainsKey('Jobs') -or $Jobs -le 0) {
        $cores = [Environment]::ProcessorCount
        Write-Log ''
        while ($true) {
            $raw = Read-Host "Parallel build jobs; default all $cores cores; press q to quit"
            if ($raw -and $raw.Trim() -eq 'q') { Write-Log ''; Write-Log '  Aborted by user.' -ForegroundColor Yellow; exit 0 }
            if ([string]::IsNullOrWhiteSpace($raw)) { $Jobs = $cores; break }
            $n = 0
            if ([int]::TryParse($raw.Trim(), [ref]$n) -and $n -ge 1 -and $n -le 128) { $Jobs = $n; break }
            Write-Warn 'Enter a number between 1 and 128 (above the logical processor count it may be slower or run out of memory)'
        }
    }
}

if (-not $BuildType) { $BuildType = 'Release' }
if ($Jobs -le 0) { $Jobs = [Environment]::ProcessorCount }

Write-Ok "Build type    : $BuildType"
Write-Ok "Parallel jobs : $Jobs"

# ============================================================================
#  4. Clone the source (when missing)
# ============================================================================
Write-Section '4/8 Source'

if (Test-Path (Join-Path $SourceDir 'CMakeLists.txt')) {
    Write-Ok "Source already present, skipping clone: $SourceDir"
    $head = (& git -C $SourceDir log -1 --format='%h %ad %s' --date=short 2>$null)
    if ($head) { Write-Note "HEAD: $head" }
}
else {
    if (-not $gitPath) {
        Write-Bad 'git not found, and the source tree is missing'
        Write-Note 'winget install --id Git.Git -e'
        exit 1
    }
    $url = 'https://github.com/ggml-org/llama.cpp.git'
    Write-Note "Cloning $url  ->  $SourceDir"
    # [measured here] PortableGit's schannel backend fails with SEC_E_NO_CREDENTIALS;
    # forcing the openssl backend works around it. Harmless if your git is fine.
    Invoke-External { & git -c http.sslBackend=openssl clone --depth 1 $url $SourceDir }
    if ($LASTEXITCODE -ne 0) { Write-Bad "git clone failed (exit code $LASTEXITCODE)"; exit 1 }
    Write-Ok 'Clone finished'
}

# ============================================================================
#  5. Assemble the CMake arguments
# ============================================================================
Write-Section '5/8 Build arguments'

if (-not $BuildDir) {
    # Sort the backend names so the same set never ends up in two different directories
    $suffix = (($Backend | Sort-Object) -join '-').ToLower()
    # Single-configuration generators (Ninja / MinGW Makefiles) carry the build type in
    # the directory name, so switching mode does not mix caches in one tree. Visual
    # Studio is multi-configuration and keeps Debug/Release in one directory, so it
    # must not get a mode suffix.
    $modeTag = ''
    if ($useNinja -or $use -eq 'gcc') { $modeTag = '-' + $BuildType.ToLower() }
    # The build directory follows the current working directory as well
    $BuildDir = Join-Path (Get-Location).ProviderPath "build-$suffix-$use$modeTag"
}
$BuildDir = [System.IO.Path]::GetFullPath($BuildDir)

# The SYCL backend needs the oneAPI DPC++ compiler (icx/icpx), not gcc / cl.exe
# ggml-hip/CMakeLists.txt aborts on static linking, so turn it off when HIP is picked
if (($Backend -contains 'HIP') -and -not $NoStatic) {
    Write-Warn 'HIP/ROCm does not support static linking: -static disabled automatically'
    $NoStatic = $true
}
# Every accelerating backend (CUDA's cudart/cublas, OpenVINO Runtime, HIP, MUSA,
# SYCL...) ships DLLs built against the dynamic CRT. Linking them against a
# statically linked runtime corrupts the heap: inference dies instantly with
# 0xC0000409 (__fastfail) and no output. MSVC therefore uses the dynamic CRT.
if (($use -eq 'msvc') -and -not $NoStatic) {
    Write-Warn 'MSVC: static linking disabled (accelerating backends need the dynamic CRT)'
    $NoStatic = $true
}
$useOneApi = ($Backend -contains 'SYCL') -and $oneApiReady
# The oneAPI path needs Ninja too, but $useNinja must be set as well: changing only
# $generator leaves the build passing --config and MSBuild properties, which Ninja
# rejects.
if ($useOneApi -and $ninjaUsable) { $generator = 'Ninja'; $useNinja = $true }

# OpenVINO needs its environment sourced first (sets OpenVINO_DIR and PATH)
if (($Backend -contains 'OpenVINO') -and $ovSetup) {
    Write-Note "Initializing OpenVINO environment: $ovSetup"
    try { & $ovSetup 2>&1 | ForEach-Object { Write-Note "$_" } } catch { Write-Warn "setupvars.ps1 failed: $(($_.Exception.Message -split "`r?`n")[0])" }
}

# -Wno-dev suppresses CMake's developer warnings (for example CMP194 "MSVC is not an
# assembler for language ASM"). Real errors are unaffected.
$cmakeArgs = @('-S', $SourceDir, '-B', $BuildDir, '-G', $generator, '-Wno-dev')

# FindOpenCL does not search the CUDA Toolkit on its own, so pass what we found
if ($Backend -contains 'OpenVINO') {
    if ($openclInc) { $cmakeArgs += "-DOpenCL_INCLUDE_DIR=$openclInc" }
    if ($openclLib) { $cmakeArgs += "-DOpenCL_LIBRARY=$openclLib" }
}

if ($useOneApi) {
    $cmakeArgs += @(
        "-DCMAKE_BUILD_TYPE=$BuildType"
        '-DCMAKE_C_COMPILER=icx'
        '-DCMAKE_CXX_COMPILER=icpx'
    )
    if (-not $NoStatic) { $cmakeArgs += '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded' }
}
elseif ($use -eq 'gcc') {
    $cmakeArgs += @(
        "-DCMAKE_BUILD_TYPE=$BuildType"
        '-DCMAKE_C_COMPILER=gcc'
        '-DCMAKE_CXX_COMPILER=g++'
    )
    if (-not $NoStatic) {
        # Keeps the exe free of libstdc++-6.dll / libgcc_s_seh-1.dll / libwinpthread-1.dll
        $cmakeArgs += '-DCMAKE_EXE_LINKER_FLAGS=-static'
    }
}
else {
    if ($useNinja) {
        # Ninja is a single-configuration generator: the build type is given at
        # configure time and there is no --config at build time. cl.exe is not on
        # PATH, so both the compiler and ninja itself must be pointed at explicitly.
        #
        # The debug information format must be Embedded (/Z7). The default is
        # ProgramDatabase (/Zi), which has cl.exe write a .pdb - and that write is not
        # done by cl.exe itself but by the background service mspdbsrv.exe, over a
        # NAMED PIPE. This machine refuses to create that class of kernel object, so
        # the PDB can never be opened and it surfaces as:
        #   fatal error C1041: cannot open program database "...\vc140.pdb";
        #       if multiple CL.EXE write to the same .PDB, use /FS
        # Adding /FS does not help: it only serializes PDB writes, it does not remove
        # mspdbsrv.exe from the picture. With /Z7 the debug info goes straight into
        # each .obj, no .pdb is involved at all, and the problem disappears.
        $cmakeArgs += @(
            "-DCMAKE_BUILD_TYPE=$BuildType"
            "-DCMAKE_MAKE_PROGRAM=$ninjaPath"
            "-DCMAKE_C_COMPILER=$vsCl"
            "-DCMAKE_CXX_COMPILER=$vsCl"
            '-DCMAKE_MSVC_DEBUG_INFORMATION_FORMAT=Embedded'
        )
    }
    else {
        $cmakeArgs += @('-A', 'x64')
        # MSBuild's CL task writes a "tracking file" before compiling, recording which
        # headers it read. In some environments that write fails with an IOException and
        # surfaces as:
        #   error MSB6003: The specified task executable "CL.exe" could not be run.
        #     at Microsoft.Build.CPPTasks.TrackedVCToolTask...
        # Nothing in the message hints at the tracking file. So disable the tracker
        # unconditionally - the only cost is incremental-build dependency analysis, and
        # every build here is a full build.
        $cmakeArgs += '-DCMAKE_VS_GLOBALS=TrackFileAccess=false'
    }
    # MSVC parses sources in the system code page by default and llama.cpp is
    # UTF-8, which floods the log with C4819 warnings.
    # Use the CL environment variable, NOT -DCMAKE_CXX_FLAGS: setting that cache
    # variable replaces CMake's default flags and silently drops /EHsc, which
    # then raises C4530 in every translation unit that uses C++ exceptions.
    $env:CL = if ($env:CL) { "$env:CL /utf-8" } else { '/utf-8' }
    if ($Backend -contains 'CUDA') {
        $env:NVCC_PREPEND_FLAGS = if ($env:NVCC_PREPEND_FLAGS) { "$env:NVCC_PREPEND_FLAGS -Xcompiler=/utf-8" } else { '-Xcompiler=/utf-8' }
    }
    # MSVC and MSBuild print localized diagnostics in the system code page, which turns
    # into mojibake under a UTF-8 console. DOTNET_CLI_UI_LANGUAGE makes MSBuild switch
    # to English (measured working), and English output is pure ASCII so no mismatch is
    # possible. cl.exe does not read this variable; its Chinese diagnostics stay.
    if (-not $env:DOTNET_CLI_UI_LANGUAGE) { $env:DOTNET_CLI_UI_LANGUAGE = 'en-US' }
    if (-not $env:VSLANG) { $env:VSLANG = '1033' }
    # MSBuild contends on shared output paths when building in parallel (file locks,
    # directory creation denied). This switch makes it log fine-grained file locking
    # detail, which helps pinpoint the conflict. It produces no extra output when
    # nothing goes wrong and does not affect the build result.
    if (-not $env:MSBUILDDEBUGFILELOCKS) { $env:MSBUILDDEBUGFILELOCKS = '1' }
    if (-not $NoStatic) {
        # The MSVC equivalent of -static: link the C runtime statically
        $cmakeArgs += '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded'
    }
}

foreach ($b in $Backend) { $cmakeArgs += $BackendDefs[$b].Flags }

# nvcc is often not on PATH, so hand CMake the toolkit root we detected
if (($Backend -contains 'CUDA') -and $nvccPath) {
    $cudaRoot = Split-Path (Split-Path $nvccPath -Parent) -Parent
    $cmakeArgs += "-DCUDAToolkit_ROOT=$cudaRoot"

    # The VS/MSBuild CUDA integration reads the versioned CUDA_PATH_V<major>_<minor>,
    # not the generic CUDA_PATH. A freshly installed toolkit sets it machine-wide
    # only, so a session started before the install still sees nothing. Import it.
    foreach ($n in [Environment]::GetEnvironmentVariables('Machine').Keys) {
        if ($n -like 'CUDA_PATH*') {
            [Environment]::SetEnvironmentVariable($n, [Environment]::GetEnvironmentVariable($n, 'Machine'), 'Process')
        }
    }
    if (-not [Environment]::GetEnvironmentVariable('CUDA_PATH', 'Process')) {
        [Environment]::SetEnvironmentVariable('CUDA_PATH', $cudaRoot, 'Process')
    }
    if ((Split-Path $cudaRoot -Leaf) -match '^v(\d+)\.(\d+)$') {
        $vn = "CUDA_PATH_V$($Matches[1])_$($Matches[2])"
        if (-not [Environment]::GetEnvironmentVariable($vn, 'Process')) {
            [Environment]::SetEnvironmentVariable($vn, $cudaRoot, 'Process')
        }
    }

    # The built binaries need the CUDA runtime DLLs. CUDA 13 keeps them in
    # bin\x64, not bin, and the directory is missing from a session started
    # before the install - without it the exe dies with 0xC0000135.
    foreach ($sub in "$cudaRoot\bin\x64", "$cudaRoot\bin") {
        if ((Test-Path $sub) -and (($env:Path -split ';') -notcontains $sub)) {
            $env:Path = "$sub;$env:Path"
        }
    }
}

# AVX-VNNI: MSVC's /arch:AVX2 does not include VNNI, while GCC's -march=native
# already does, so this is added for the MSVC path only. The build machine has to
# really support it - running the result on a CPU without VNNI crashes with an
# illegal instruction - so when the check is unavailable the flag is left out.
$vnniOn = $false
if ($AvxVnni) { $vnniOn = $true }
elseif ($use -eq 'msvc' -and -not $useOneApi) {
    $vnniSupport = Get-IntrinsicSupported 'AvxVnni'
    if ($vnniSupport -eq $true) {
        $vnniOn = $true
        Write-Note 'AVX-VNNI detected on this machine; enabling -DGGML_AVX_VNNI=ON'
    }
    elseif ($null -eq $vnniSupport) {
        Write-Note 'Cannot detect AVX-VNNI from this PowerShell; add -AvxVnni if the CPU supports it'
    }
}
if ($vnniOn) { $cmakeArgs += '-DGGML_AVX_VNNI=ON' }
if ($Lto) { $cmakeArgs += '-DGGML_LTO=ON' }
if (-not $WithTests) { $cmakeArgs += '-DLLAMA_BUILD_TESTS=OFF' }

Write-Note "Toolchain : $use"
Write-Note "Build dir : $BuildDir"
Write-Note "Generator : $generator"
Write-Log ''
Write-Log '  Full command (copy-pasteable):' -ForegroundColor DarkGray
$printable = ($cmakeArgs | ForEach-Object { if ("$_" -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
Write-Log "  cmake $printable" -ForegroundColor DarkGray

# ============================================================================
#  6. CMake configure
# ============================================================================
Write-Section '6/8 CMake configure'

Invoke-External { & cmake @cmakeArgs }
if ($LASTEXITCODE -ne 0) { Write-Bad "CMake configure failed (exit code $LASTEXITCODE)"; exit 1 }
Write-Ok 'Configure done'

# ============================================================================
#  7. Build
# ============================================================================
Write-Section '7/8 Build'

$sw = [System.Diagnostics.Stopwatch]::StartNew()
# MSBuild's C++ task scheduler (MultiToolTask) uses a NAMED SEMAPHORE to count
# concurrent compiler processes. Some environments refuse to create such kernel
# objects, and the failure surfaces as MSB4018 with only "access to the port is
# denied" - no hint that parallelism is involved. These two properties turn off the
# scheduler's internal parallelism and the cross-build process counter;
# project-level parallelism is still governed by --parallel.
$msbProps = @('/p:UseMultiToolTask=false', '/p:EnforceProcessCountAcrossBuilds=false')

# The build always runs in parallel: --parallel works for every generator, and
# CMAKE_BUILD_PARALLEL_LEVEL is set as a fallback that third-party sub-builds
# (ExternalProject and friends) also honour.
$env:CMAKE_BUILD_PARALLEL_LEVEL = "$Jobs"

# Ninja and MinGW Makefiles are both single-configuration generators: the build type is
# already fixed at configure time, so no --config here, and their build tools do not
# accept MSBuild properties (anything after -- would be parsed by the tool itself and
# fail). Only the Visual Studio generator needs those properties.
if ($useNinja -or $use -eq 'gcc') {
    Invoke-External { & cmake --build $BuildDir --parallel $Jobs }
}
else {
    Invoke-External { & cmake --build $BuildDir --config $BuildType --parallel $Jobs -- @msbProps }
}
$code = $LASTEXITCODE

$sw.Stop()

if ($code -ne 0) { Write-Bad "Build failed (exit code $code)"; exit $code }
Write-Ok ("Build succeeded in {0:N1} minutes" -f $sw.Elapsed.TotalMinutes)

# ============================================================================
#  8. Verify
# ============================================================================
Write-Section '8/8 Verify'

$binDir = Join-Path $BuildDir 'bin'
# Multi-config generators put the binaries in a per-configuration subdirectory
if ((Test-Path (Join-Path $binDir $BuildType))) { $binDir = Join-Path $binDir $BuildType }

if (-not (Test-Path $binDir)) {
    Write-Bad "Artifact directory not found: $binDir"
    exit 1
}

$exes = Get-ChildItem $binDir -Filter '*.exe' | Sort-Object Name
if (-not $exes) { Write-Bad "No .exe found in $binDir"; exit 1 }

Write-Ok ("Artifacts in $binDir -- $($exes.Count) executable(s), full list:")
$totalKb = 0
foreach ($x in $exes) {
    $totalKb += $x.Length / 1KB
    Write-Note ("{0,-36} {1,10:N0} KB" -f $x.Name, ($x.Length / 1KB))
}
Write-Note ("{0,-36} {1,10:N0} KB" -f '--- TOTAL ---', $totalKb)

if (-not $NoVerify) {
    $cli = Join-Path $binDir 'llama-cli.exe'
    if (Test-Path $cli) {
        Write-Log ''
        Write-Note 'Running llama-cli --version:'
        Invoke-External { & $cli --version }
        if ($LASTEXITCODE -eq 0) { Write-Ok 'llama-cli starts normally' }
        else { Write-Warn "llama-cli --version exit code $LASTEXITCODE" }
    }

    if ($WithTests) {
        Write-Log ''
        Write-Note 'Running ctest:'
        # --test-dir needs CMake 3.20+, so change directory for compatibility
        Push-Location $BuildDir
        try { Invoke-External { & ctest -C $BuildType --output-on-failure --parallel $Jobs } }
        finally { Pop-Location }
        if ($LASTEXITCODE -eq 0) { Write-Ok 'ctest passed' } else { Write-Warn "ctest exit code $LASTEXITCODE" }
    }
}

# ============================================================================
#  Next steps
# ============================================================================
Write-Section 'Done -- next steps'

$rel = Resolve-Path -Relative $binDir -ErrorAction SilentlyContinue
if (-not $rel) { $rel = $binDir }

Write-Log @"
  # Download a model (GGUF) into models\ first; a browser works too.
  # Good small starter: Qwen2.5-1.5B-Instruct Q4_K_M, about 1 GB
  mkdir models -Force | Out-Null
  hf download Qwen/Qwen2.5-1.5B-Instruct-GGUF qwen2.5-1.5b-instruct-q4_k_m.gguf --local-dir models

  # Interactive chat (just run it; type /exit to quit)
  $rel\llama-cli.exe -m models\qwen2.5-1.5b-instruct-q4_k_m.gguf

  # One-shot question (no interactive session)
  $rel\llama-cli.exe -m models\qwen2.5-1.5b-instruct-q4_k_m.gguf -st -p "hello" -n 128

  # OpenAI-compatible server (any frontend can point at http://127.0.0.1:8080/v1)
  $rel\llama-server.exe -m models\qwen2.5-1.5b-instruct-q4_k_m.gguf --host 127.0.0.1 --port 8080

  # Benchmark (use this to compare CPU vs GPU)
  $rel\llama-bench.exe -m models\qwen2.5-1.5b-instruct-q4_k_m.gguf

  # GDB debugging (GCC toolchain, rebuild with -BuildType RelWithDebInfo or Debug first)
  gdb --args $rel\llama-cli.exe -m models\qwen2.5-1.5b-instruct-q4_k_m.gguf -p "hi" -n 16
"@ -ForegroundColor Gray

# Show the OpenVINO notes only when that backend was actually built
if ($Backend -contains 'OpenVINO') {
    Write-Log ''
    Write-Log '  -- OpenVINO backend notes -------------------------------------' -ForegroundColor DarkCyan
    Write-Log '  Initialize the environment first, or the binary exits immediately' -ForegroundColor Gray
    Write-Log '  because openvino.dll cannot be found:' -ForegroundColor Gray
    if ($ovSetup) {
        Write-Log "    1) Run once per new terminal:" -ForegroundColor Gray
        Write-Log "         & `"$ovSetup`"" -ForegroundColor Gray
    }
    else {
        Write-Log "    1) Run setupvars from your OpenVINO install (not located on this machine)" -ForegroundColor Gray
    }
    Write-Log '    2) Pick a device (CPU is the default when unset):' -ForegroundColor Gray
    Write-Log "         `$env:GGML_OPENVINO_DEVICE = 'NPU'      # or GPU.0 / GPU.1 / CPU" -ForegroundColor Gray
    Write-Log '    3) List the devices that are actually available:' -ForegroundColor Gray
    Write-Log "         $rel\llama-cli.exe --list-devices" -ForegroundColor Gray
    Write-Log '    4) Run(example):' -ForegroundColor Gray
    Write-Log "         $rel\llama-cli.exe -m models\qwen2.5-1.5b-instruct-q4_k_m.gguf -c 8192" -ForegroundColor Gray
}
# --- close the log file opened at the top ---
# nothing to close: no file handle is kept open
