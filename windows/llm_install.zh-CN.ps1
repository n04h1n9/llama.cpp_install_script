<#
.SYNOPSIS
    llama.cpp 编译脚本 —— Windows / PowerShell 版

.DESCRIPTION
    本脚本只面向 Windows，工具链为 MSVC 或 GCC/G++ (MinGW-w64)，配合 CMake（优先 MSVC）。
    流程：工具链检查 -> 选后端 -> 选构建选项 -> 克隆源码 -> CMake 配置 -> 编译 -> 验证

.PARAMETER Toolchain
    auto（默认）= 优先 MSVC，没有则回退 GCC/G++ (MinGW-w64)
    gcc          = 必须使用 GCC/G++ (MinGW-w64)
    msvc         = 必须使用 MSVC（装了 C++ 工作负载的 Visual Studio）

.PARAMETER Backend
    硬件后端，可多选：CPU CUDA HIP SYCL Metal Vulkan MUSA ZenDNN CANN OpenVINO
    不指定时进入交互菜单。

.PARAMETER BuildType
    Release / RelWithDebInfo / Debug / MinSizeRel
    不指定且是交互运行时，会询问你选择。

.PARAMETER Jobs
    并行编译线程数。不指定且是交互运行时，会询问你输入（默认给本机逻辑核心数）。

.PARAMETER NoStatic
    关闭静态链接。默认开启：GCC 下加 -static，MSVC 下选用非 DLL 的 C 运行时
    （MultiThreaded）。

.PARAMETER AvxVnni
    额外开启 -DGGML_AVX_VNNI=ON（Intel 12 代及以后支持；收益因机器而异，需自己实测）。

.PARAMETER WithTests
    编译 tests 并运行 ctest（默认关闭，节省编译时间）。

.PARAMETER NoVerify
    跳过编译后验证。

.PARAMETER NonInteractive
    完全非交互：用默认值代替询问
    （后端 = CPU，构建模式 = Release，线程数 = 逻辑核心数）。

.PARAMETER Force
    忽略前置拦截（后端与工具链不兼容、缺少外部 SDK），强行交给 CMake 去试。

.EXAMPLE
    .\llm_install.zh-CN.ps1
    全交互：依次选择后端、构建模式、线程数，然后编译。

.EXAMPLE
    .\llm_install.zh-CN.ps1 -Backend CPU -Jobs 20 -BuildType Release
    传了参数的项就不再询问。

.EXAMPLE
    .\llm_install.zh-CN.ps1 -Toolchain msvc -Backend CUDA
    用 MSVC 编译（Windows 上唯一能编 CUDA 后端的工具链）。

.NOTES
    本脚本的完整编译流程尚未在每种工具链组合上端到端跑通。
    首次运行建议先跑：-Backend CPU。
    提示：如果直接运行该脚本请用 PowerShell 7 (pwsh) 运行；PowerShell 5.1 的默认执行策略会拒绝脚本。
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
    [switch]   $WithTests,
    [switch]   $NoVerify,
    [switch]   $NonInteractive,
    [switch]   $Force
)

$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 的 $OutputEncoding 默认是 US-ASCII，任何非 ASCII 文本
# 经管道传给原生程序都会变成 "?"。这里固定为 UTF-8。
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
# 本会话可能是在工具装好之前启动的，PATH 会是旧的。PATH 存在机器级和用户级两处，
# 必须都取，否则刚装的 gcc / cmake 会被漏检。
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')

# MSBuild 的 CL.exe 文件追踪器要写临时文件。若系统临时目录不可写，编译会以
# MSB6003 / UnauthorizedAccessException 失败，所以这里探测一次，不通就改用
# 可写的位置。
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
    Write-Warning "系统临时目录不可写，已改用 $altTmp"
}

# ============================================================================
#  后端定义表
#  GCC  : 在 Windows + GCC/G++ (MinGW-w64) 下
#  MSVC : 在 Windows + MSVC (Visual Studio) 下
#  取值：ok = 支持 | warn = 可能可行，需要外部 SDK | no = 拦截
# ============================================================================
$BackendDefs = [ordered]@{
    'CPU'    = @{ Flags = @('-DGGML_NATIVE=ON');                            Need = 'gcc/g++ 或 cl.exe';         GCC = 'ok';   MSVC = 'ok';   Desc = '所有 CPU，按本机优化' }
    'CUDA'   = @{ Flags = @('-DGGML_CUDA=ON');                              Need = 'CUDA Toolkit (nvcc)';       GCC = 'no';   MSVC = 'ok';   Desc = 'NVIDIA GPU（Windows 上必须用 MSVC）' }
    'HIP'    = @{ Flags = @('-DGGML_HIP=ON');                               Need = 'ROCm / HIP SDK';            GCC = 'no';   MSVC = 'warn'; Desc = 'AMD GPU' }
    'ZenDNN' = @{ Flags = @('-DGGML_ZENDNN=ON');                            Need = 'ZenDNN SDK';                GCC = 'warn'; MSVC = 'warn'; Desc = 'AMD CPU (Zen)' }
    'SYCL'   = @{ Flags = @('-DGGML_SYCL=ON');                              Need = 'Intel oneAPI (icpx)';       GCC = 'no';   MSVC = 'no';   Desc = 'Intel GPU / CPU（需要 oneAPI 的 icpx 编译器）' }
    'Metal'  = @{ Flags = @('-DGGML_METAL=ON');                             Need = 'macOS';                     GCC = 'no';   MSVC = 'no';   Desc = 'Apple GPU（仅 macOS）' }
    'CANN'   = @{ Flags = @('-DGGML_CANN=ON');                              Need = 'CANN Toolkit + 昇腾 NPU';   GCC = 'no';   MSVC = 'no';   Desc = '华为昇腾（后端仅支持 Linux）' }
    'MUSA'   = @{ Flags = @('-DGGML_MUSA=ON', '-DGGML_MUSA_MUDNN_COPY=ON'); Need = 'MUSA SDK';                  GCC = 'no';   MSVC = 'warn'; Desc = '摩尔线程 GPU' }
    'Vulkan' = @{ Flags = @('-DGGML_VULKAN=ON');                            Need = 'Vulkan SDK (glslc)';        GCC = 'ok';   MSVC = 'ok';   Desc = '任意 Vulkan GPU（NVIDIA/AMD/Intel）' }
    'OpenVINO' = @{ Flags = @('-DGGML_OPENVINO=ON');                        Need = 'OpenVINO Runtime + OpenCL'; GCC = 'warn'; MSVC = 'warn'; Desc = 'Intel CPU / GPU / NPU（AI Boost）' }
}

# 菜单编号顺序
$MenuOrder = @('CPU', 'CUDA', 'HIP', 'ZenDNN', 'SYCL', 'Metal', 'CANN', 'MUSA', 'Vulkan', 'OpenVINO')

# ============================================================================
#  输出小工具
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

# 定位带 C++ 工具集的 Visual Studio
# 定位 vswhere.exe。除两个标准位置外，也接受已经在 PATH 里的那份：
# Visual Studio 可能装在别处，其 Installer 的注册位置也可能不在默认路径。
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

function Get-VisualStudioPath {
    $vswhere = Get-VsWherePath
    if (-not $vswhere) { return $null }
    $p = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
    if ($p) { return ("$p").Trim() }
    # 回退：vswhere 本身属于 VS Installer，可能缺失（被卸载、精简、移动过）。
    # Visual Studio 会把每个实例记录在 ProgramData 下，直接读那里。
    # 注意：注册表不可用 —— 自 2017 的安装模型起，它根本不保存安装路径。
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

# 生成器名改用 vswhere 报告的版本号推导，不再从安装路径猜：
# Visual Studio 可以装在任意目录（C:\VS2022、D:\Tools\VS 等），
# 靠路径匹配在自定义安装位置下会失效。
function Get-VisualStudioGenerator {
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
#  日志同步：每一行都同时输出到终端和 llm_install.log，内容完全一致
# ============================================================================
$script:LogPath = $null
$script:LogEncoding = [System.Text.UTF8Encoding]::new($false)
if (-not $NoLog) {
    if (-not $LogFile) { $LogFile = Join-Path $PSScriptRoot 'llm_install.log' }
    $LogFile = [System.IO.Path]::GetFullPath($LogFile)
    try {
        # 每次运行覆盖写。这里不保留文件句柄，所以日志文件随时可以删除或移动，
        # 即使本脚本还在运行中。(保证脚本意外中断后不会继续占用日志文件)
        [System.IO.File]::WriteAllText($LogFile, '', $script:LogEncoding)
        $script:LogPath = $LogFile
    }
    catch {
        Write-Warning "无法打开日志文件 $LogFile ：$($_.Exception.Message)"
    }
}

# 同时输出到终端并追加到日志文件
function Write-Log ([string]$Text, [string]$ForegroundColor, [switch]$NoNewline) {
    if ($ForegroundColor) { Write-Host $Text -ForegroundColor $ForegroundColor -NoNewline:$NoNewline }
    else { Write-Host $Text -NoNewline:$NoNewline }
    if ($script:LogPath) {
        $chunk = if ($NoNewline) { $Text } else { $Text + [Environment]::NewLine }
        try { [System.IO.File]::AppendAllText($script:LogPath, $chunk, $script:LogEncoding) } catch { }
    }
}

# 原生工具常把正常的进度文字写到 stderr。在 $ErrorActionPreference = 'Stop' 下，
# Windows PowerShell 5.1 会把它变成终止性的 RemoteException，所以调用子进程期间
# 临时放宽这个偏好。
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
#  0. 参数默认值
# ============================================================================
if (-not $SourceDir) {
    # 以「当前工作目录」为基准：在哪个目录运行，源码就落在哪个目录
    $cwd = (Get-Location).ProviderPath
    if ((Test-Path (Join-Path $cwd 'CMakeLists.txt')) -and (Test-Path (Join-Path $cwd 'ggml'))) {
        # 当前目录本身就是 llama.cpp 源码树
        $SourceDir = $cwd
    }
    else {
        # 当前目录下的 llama.cpp-src；后面某一步会在缺失时自动 clone 到这里
        $SourceDir = Join-Path $cwd 'llama.cpp-src'
    }
}
$SourceDir = [System.IO.Path]::GetFullPath($SourceDir)

Write-Log ''
Write-Log '============================================================'  -ForegroundColor DarkCyan
Write-Log '  llama.cpp 编译脚本  --  Windows / PowerShell（中文版）'      -ForegroundColor DarkCyan
Write-Log '  工具链: GCC/G++ (MinGW-w64) 或 MSVC  +  CMake'              -ForegroundColor DarkCyan
Write-Log '============================================================'  -ForegroundColor DarkCyan
Write-Note "源码目录 : $SourceDir"
if ($script:LogPath) { Write-Note "日志文件 : $LogFile" }

# ============================================================================
#  1. 工具链检查
# ============================================================================
Write-Section '1/8 工具链检查'

# --- 无论走哪条路，CMake 都必须有 ---
$missing = @()
if (Get-ToolPath 'cmake') {
    Write-Ok "cmake  ->  $((Get-ToolPath 'cmake'))"
    $cv = Get-CMakeVersion
    if ($cv -and $cv -ge [version]'3.14') { Write-Ok "cmake 版本 $cv （>= 3.14 满足）" }
    else { Write-Bad "cmake 版本 $cv 过低，llama.cpp 要求 >= 3.14"; $missing += 'cmake-version' }
}
else {
    Write-Bad 'cmake 缺失'
    Write-Note 'winget install --id Kitware.CMake -e      （或用 VS 自带的 cmake）'
    $missing += 'cmake'
}
# git 只在需要自动克隆源码时用到；源码已存在时没有 git 也不影响编译
$gitPath = Get-ToolPath 'git'
if ($gitPath) { Write-Ok "git  ->  $gitPath" }
else { Write-Warn 'git 未找到（仅在需要自动克隆源码时用到）' }

# --- GCC 可用性 ---
$gccPath = Get-ToolPath 'gcc'
$gxxPath = Get-ToolPath 'g++'
$gdbPath = Get-ToolPath 'gdb'
$gccReady = [bool]($gccPath -and $gxxPath)

# --- MSVC 可用性 ---
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

# --- Intel oneAPI (SYCL) 可用性 ---
$oneApiCompiler = $null
foreach ($c in 'icpx', 'icx', 'dpcpp') {
    $p = Get-ToolPath $c
    if ($p) { $oneApiCompiler = $p; break }
}
$oneApiReady = [bool]$oneApiCompiler

# --- CUDA Toolkit (nvcc) 可用性 ---
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

# --- Vulkan SDK 可用性 ---
$glslcPath = Get-ToolPath 'glslc'
$vulkanReady = [bool]($env:VULKAN_SDK -or $glslcPath)

# --- Intel OpenVINO（CPU / GPU / NPU）可用性 ---
# ggml-openvino/CMakeLists.txt 要 find_package(OpenVINO ...) 和 find_package(OpenCL ...)。
# setupvars.ps1 会导出 INTEL_OPENVINO_DIR（包根目录）和 OpenVINO_DIR（指向 <根>/runtime/cmake），
# 并把运行库目录加进 PATH。CMake 必须先看到这些变量，所以这里把 setup 脚本的位置找出来。
$ovRoot = $env:INTEL_OPENVINO_DIR
if (-not $ovRoot -and $env:OpenVINO_DIR) {
    # OpenVINO_DIR 是 <根>/runtime/cmake，往回退两级
    $ovRoot = Split-Path (Split-Path $env:OpenVINO_DIR -Parent) -Parent
}
if (-not $ovRoot) {
    $cands = @()
    foreach ($c in 'C:\Intel\openvino', "$env:ProgramFiles\Intel", "${env:ProgramFiles(x86)}\Intel") {
        if (Test-Path $c) { $cands += @(Get-ChildItem $c -Directory -Filter 'openvino*' -ErrorAction SilentlyContinue) }
    }
    # winget / MSIX 安装会落在 WindowsApps
    $cands += @(Get-ChildItem 'C:\Program Files\WindowsApps' -Directory -Filter 'Intel.OpenVINOToolkit*' -ErrorAction SilentlyContinue)
    $hit = $cands | Where-Object { Test-Path (Join-Path $_.FullName 'setupvars.ps1') } | Sort-Object Name -Descending | Select-Object -First 1
    if ($hit) { $ovRoot = $hit.FullName }
}
$ovSetup = $null
if ($ovRoot -and (Test-Path (Join-Path $ovRoot 'setupvars.ps1'))) { $ovSetup = Join-Path $ovRoot 'setupvars.ps1' }
$openvinoReady = [bool]($ovRoot -and (Test-Path $ovRoot))
# ggml-openvino 依赖 OpenCL，而且 FindOpenCL 要的是头文件（CL/cl.h 以及 C++ 绑定用的
# CL/cl2.hpp）加导入库 OpenCL.lib，光有运行库 OpenCL.dll 不够。OpenVINO 本身不需要
# CUDA，所以优先用独立安装的 OpenCL（vcpkg，或 Khronos 头文件 + ICD loader）；
# CUDA 只作最后回退，因为它自带的头文件里没有 cl2.hpp。
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
# 只有 cl.h 没有 cl2.hpp 的头文件集，ggml-openvino 用不了
if ($openclInc -and -not (Test-Path (Join-Path $openclInc 'CL\cl2.hpp'))) { $openclInc = $null }
$openclReady = [bool]($openclInc -and $openclLib)

# --- Intel NPU（AI Boost）硬件 ---
# ggml-openvino 可以用 GGML_OPENVINO_DEVICE=NPU 把计算放到 NPU 上。这里用 pnputil
$npuPresent = $false
try {
    $npuOut = & pnputil /enum-devices /class ComputeAccelerator 2>$null | Out-String
    $npuPresent = [bool]($npuOut -match 'Intel\(R\) AI Boost')
} catch { }

# --- AMD GPU (HIP / ROCm) 可用性 ---
# 依据 ggml-hip/CMakeLists.txt：它只读 ROCM_PATH，且要求 ROCm/HIP >= 6.1
$hipRoot = $env:ROCM_PATH
$hipCompiler = Get-ToolPath 'hipcc'; if (-not $hipCompiler) { $hipCompiler = Get-ToolPath 'hipconfig' }
$hipDir = 'C:\Program Files\AMD\ROCm'
$hipReady = [bool]($hipRoot -or $hipCompiler -or (Test-Path $hipDir))

# --- AMD CPU (ZenDNN) 可用性 ---
$zendnnRoot = $env:ZENDNN_ROOT
$zendnnDir = 'C:\Program Files\AMD\ZenDNN'
$zendnnReady = [bool]($zendnnRoot -or (Test-Path $zendnnDir))

# --- 摩尔线程 GPU (MUSA) 可用性 ---
# ggml-musa/CMakeLists.txt 只读 MUSA_PATH，不能靠编译器名字猜：
# "mcc" 同时是 MATLAB 的编译器名，在没有摩尔线程硬件的机器上会误报。
$musaRoot = $env:MUSA_PATH
$musaReady = [bool]($musaRoot -and (Test-Path $musaRoot))

# 后端可用性由「实际装了什么」决定，而不是写死的表
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

# --- 二选一：优先 MSVC，其次 GCC ---
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

# --- 汇报 ---
Write-Log ''
Write-Log '  GCC/G++ (MinGW-w64)：' -ForegroundColor DarkGray
if ($gccPath) { Write-Ok "gcc  ->  $gccPath" } else { Write-Warn 'gcc  未找到' }
if ($gxxPath) { Write-Ok "g++  ->  $gxxPath" } else { Write-Warn 'g++  未找到' }
if ($gdbPath) { Write-Ok "gdb  ->  $gdbPath" } else { Write-Warn 'gdb  未找到（只有调试才需要）' }

Write-Log ''
Write-Log '  MSVC (Visual Studio)：' -ForegroundColor DarkGray
if ($vsPath)      { Write-Ok "Visual Studio  ->  $vsPath" } else { Write-Warn '未找到装了 C++ 工作负载的 Visual Studio' }
if ($vsGenerator) { Write-Ok "生成器         ->  $vsGenerator" }
if ($vsCl)        { Write-Ok "cl.exe         ->  $vsCl" }

Write-Log ''
Write-Log '  SDK / 加速库（后端依赖）：' -ForegroundColor DarkGray
if ($cudaReady)   { Write-Ok "CUDA Toolkit  ->  $nvccPath" }       else { Write-Warn 'CUDA Toolkit  未安装（CUDA 后端需要；显卡驱动不算）' }
if ($oneApiReady) { Write-Ok "Intel oneAPI  ->  $oneApiCompiler" } else { Write-Warn 'Intel oneAPI  未安装（SYCL 后端需要）' }
if ($vulkanReady) { Write-Ok "Vulkan SDK    ->  $(if ($env:VULKAN_SDK) { $env:VULKAN_SDK } else { $glslcPath })" } else { Write-Warn 'Vulkan SDK    未安装（Vulkan 后端需要）' }
if ($hipReady)    { Write-Ok "AMD ROCm/HIP  ->  $(if ($hipCompiler) { $hipCompiler } else { $hipRoot })" } else { Write-Warn 'AMD ROCm/HIP  未安装（HIP 后端需要；Windows 上支持有限）' }
if ($zendnnReady) { Write-Ok "AMD ZenDNN    ->  $zendnnRoot" }  else { Write-Warn 'AMD ZenDNN    未设 ZENDNN_ROOT（构建时会自动下载并编译，耗时较长）' }
if ($musaReady)   { Write-Ok "Moore Threads ->  $musaRoot" } else { Write-Warn 'Moore Threads 未安装（MUSA 后端需要）' }
if ($openvinoReady) { Write-Ok "Intel OpenVINO ->  $ovRoot"; if (-not $openclReady) { Write-Warn 'OpenCL 未找到；ggml-openvino 还要求 find_package(OpenCL)' } } else { Write-Warn 'Intel OpenVINO  未安装（OpenVINO 后端需要；它能让 llama.cpp 用上 Intel NPU）' }
if ($npuPresent)   { Write-Ok "Intel AI Boost ->  检测到 NPU 硬件（可配合 OpenVINO 后端使用）" }

Write-Log ''
switch ($use) {
    'gcc'  { Write-Ok '已选工具链: GCC/G++ (MinGW-w64)' }
    'msvc' { Write-Ok '已选工具链: MSVC (Visual Studio)' }
    default {
        Write-Bad '找不到可用工具链：GCC/G++ 与 MSVC 至少要有一个。'
        Write-Note '方案 A（GCC / MinGW-w64）：'
        Write-Note '  MSYS2 UCRT64: pacman -S mingw-w64-ucrt-x86_64-gcc mingw-w64-ucrt-x86_64-gdb'
        Write-Note '  或用便携版 w64devkit / WinLibs，把它的 bin 目录加进 PATH'
        Write-Note '方案 B（MSVC）：'
        Write-Note '  安装 Visual Studio（或 Build Tools），勾选"使用 C++ 的桌面开发"工作负载'
        Write-Log ''
        exit 1
    }
}

if ($use -eq 'gcc' -and -not $gdbPath) {
    Write-Warn 'gdb 缺失：不影响编译，但 -BuildType Debug/RelWithDebInfo 就没有东西可调了'
}

# --- GCC 路径需要生成器：ninja 优先，其次 mingw32-make / make ---
$generator = $null
if ($use -eq 'gcc') {
    if (Get-ToolPath 'ninja') {
        $generator = 'Ninja'; Write-Ok "ninja  ->  $((Get-ToolPath 'ninja'))"
    }
    elseif (Get-ToolPath 'mingw32-make') {
        $generator = 'MinGW Makefiles'; Write-Ok "mingw32-make  ->  $((Get-ToolPath 'mingw32-make'))"
    }
    elseif (Get-ToolPath 'make') {
        $generator = 'MinGW Makefiles'; Write-Ok "make  ->  $((Get-ToolPath 'make'))"
    }
    else {
        Write-Bad 'ninja / mingw32-make / make 都没有（GCC 路线需要其中之一）'
        Write-Note 'MSYS2 UCRT64: pacman -S mingw-w64-ucrt-x86_64-ninja'
        $missing += 'ninja-or-make'
    }
}
else {
    # Visual Studio 生成器自己驱动 MSBuild，不需要 ninja/make
    $generator = $vsGenerator
}

if ($missing.Count -gt 0) {
    Write-Log ''
    Write-Bad ("缺少必需组件: " + ($missing -join ', '))
    Write-Log '  装好之后重新运行本脚本。' -ForegroundColor Yellow
    exit 1
}

# ============================================================================
#  2. 选择硬件后端
# ============================================================================
Write-Section '2/8 选择硬件后端'

if (-not $Backend -or $Backend.Count -eq 0) {
    if ($NonInteractive) {
        $Backend = @('CPU')
        Write-Note '-NonInteractive 且未指定 -Backend，按 CPU 处理'
    }
    else {
        Write-Log ''
        Write-Log "  以下可用性按当前工具链（$use）显示" -ForegroundColor DarkGray
        for ($i = 0; $i -lt $MenuOrder.Count; $i++) {
            $n = $MenuOrder[$i]
            $d = $BackendDefs[$n]
            $state = Get-BackendState $n
            # need-sdk 在菜单里一律按「不可用」显示；缺什么由 1/8 单独报告
            $tag = switch ($state) { 'ok' { '[可用    ]' } 'warn' { '[存疑    ]' } default { '[不可用  ]' } }
            $col = switch ($state) { 'ok' { 'Green' } 'warn' { 'Yellow' } default { 'DarkGray' } }
            $desc = $d.Desc
            if ($state -eq 'need-sdk') { $desc = "$desc（缺 $($d.Need)）" }
            Write-Log ("  {0,2}) {1,-8} {2}  {3}" -f ($i + 1), $n, $tag, $desc) -ForegroundColor $col
        }
        Write-Log ''
        while ($true) {
            $raw = Read-Host '输入编号（可多选，空格分隔；默认选择 1 ；按 q 退出）'
            if ($raw -and $raw.Trim() -eq 'q') { Write-Log ''; Write-Log '  已按用户要求退出。' -ForegroundColor Yellow; exit 0 }
            if ([string]::IsNullOrWhiteSpace($raw)) { $Backend = @('CPU'); break }
            $picked = @(); $bad = $false
            foreach ($tok in ($raw -split '\s+' | Where-Object { $_ })) {
                $num = 0
                if (-not [int]::TryParse($tok, [ref]$num) -or $num -lt 1 -or $num -gt $MenuOrder.Count) { $bad = $true; break }
                $picked += $MenuOrder[$num - 1]
            }
            if (-not $bad -and $picked.Count -gt 0) { $Backend = ($picked | Select-Object -Unique); break }
            Write-Warn '输入无效，请重新输入'
        }
    }
}

Write-Ok ("已选后端: " + ($Backend -join ', '))

# --- 前置拦截：先看工具链是否根本不支持，再看是否缺外部 SDK ---
$blocked = @()   # 当前工具链完全编不了
$needSdk = @()   # 需要的外部 SDK 没装

foreach ($b in $Backend) {
    $d = $BackendDefs[$b]
    if (-not $d) { Write-Bad "未知后端: $b"; exit 1 }
    $state = Get-BackendState $b
    if ($state -eq 'no') { $blocked += $b; continue }
    if ($state -eq 'need-sdk') { $needSdk += $b }
}

if ($blocked.Count -gt 0 -and -not $Force) {
    Write-Log ''
    Write-Bad ("当前工具链（$use）无法构建这些后端: " + ($blocked -join ', '))
    if ($use -eq 'gcc' -and ($blocked -contains 'CUDA')) {
        Write-Note 'CUDA 在 GCC 下失败的原因：Windows 上 nvcc 只接受 MSVC / clang 作为 host compiler，不支持 MinGW。'
        Write-Note '解决办法：用  -Toolchain msvc  重新运行（MSVC 可以编 CUDA 后端）。'
    }
    if ($blocked -contains 'SYCL') {
        Write-Note 'SYCL 失败的原因：它需要 Intel oneAPI 的 icpx (DPC++) 编译器。'
        Write-Note 'GCC 与 MSVC 本身都没有 SYCL 支持，靠加参数是打不开的。'
    }
    if ($blocked -contains 'CANN') { Write-Note 'CANN：只支持 Linux + 昇腾 NPU，Windows 下完全不可用。' }
    if ($blocked -contains 'Metal') { Write-Note 'Metal：仅 macOS。' }
    Write-Note '可选替代：'
    Write-Note '  a) 换工具链：  -Toolchain gcc   或   -Toolchain msvc'
    Write-Note '  b) 转到 WSL2(Linux)，那里 nvcc 与 GCC 是官方组合'
    Write-Note '  c) 不走 CUDA 但要 GPU：试试 Vulkan 后端（需要 Vulkan SDK）'
    Write-Note '确实想强行交给 CMake 去试，请加 -Force'
    exit 1
}

if ($needSdk.Count -gt 0 -and -not $Force) {
    Write-Log ''
    Write-Bad ("这些后端需要的外部 SDK 尚未安装: " + ($needSdk -join ', '))
    if ($needSdk -contains 'CUDA') {
        Write-Note 'CUDA 需要 NVIDIA 的 CUDA Toolkit（它才提供 nvcc）：'
        Write-Note '  https://developer.nvidia.com/cuda-downloads'
        Write-Note '注意：装显卡驱动 ≠ 装 Toolkit。驱动能跑游戏，但里面没有 nvcc。'
        Write-Note '另外 Windows 上 CUDA 还必须配 MSVC：加上  -Toolchain msvc'
    }
    if ($needSdk -contains 'SYCL') {
        Write-Note 'SYCL 需要 Intel oneAPI 的 DPC++ 编译器（icx / icpx）：'
        Write-Note '  https://www.intel.com/content/www/us/en/developer/tools/oneapi/dpc-compiler.html'
    }
    if ($needSdk -contains 'OpenVINO') {
        Write-Note 'OpenVINO 需要 Intel 的 OpenVINO Runtime（它能让 llama.cpp 用上 Intel NPU / GPU / CPU）：'
        Write-Note '  https://docs.openvino.ai/'
        Write-Note '装完后先运行 setupvars.bat，再用 GGML_OPENVINO_DEVICE=NPU 指定设备。'
    }
    if ($needSdk -contains 'Vulkan') {
        Write-Note 'Vulkan 需要 LunarG 的 Vulkan SDK（头文件、库，以及着色器编译器 glslc）：'
        Write-Note '  https://vulkan.lunarg.com/sdk/home'
        Write-Note '安装器会设置 VULKAN_SDK 并把 glslc 加进 PATH；装完请重开终端。'
    }
    Write-Note '确实想强行交给 CMake 去试，请加 -Force'
    exit 1
}

# ============================================================================
#  3. 构建选项（命令行没给的话就在这里问）
# ============================================================================
Write-Section '3/8 构建选项'

if (-not $NonInteractive) {
    # --- 构建模式 ---
    if (-not $PSBoundParameters.ContainsKey('BuildType')) {
        Write-Log ''
        Write-Log '  构建模式：' -ForegroundColor DarkGray
        Write-Log '    1) Release         优化全开，无调试信息（默认）'
        Write-Log '    2) RelWithDebInfo  优化 + 调试符号（配 GDB 用）'
        Write-Log '    3) Debug           无优化 + 调试符号（慢，排查问题用）'
        Write-Log '    4) MinSizeRel      体积最小'
        $map = [ordered]@{ '1' = 'Release'; '2' = 'RelWithDebInfo'; '3' = 'Debug'; '4' = 'MinSizeRel' }
        while ($true) {
            $raw = Read-Host '输入 1-4（默认选择 1 ；按 q 退出）'
            if ($raw -and $raw.Trim() -eq 'q') { Write-Log ''; Write-Log '  已按用户要求退出。' -ForegroundColor Yellow; exit 0 }
            if ([string]::IsNullOrWhiteSpace($raw)) { $BuildType = 'Release'; break }
            $key = $raw.Trim()
            if ($map.Contains($key)) { $BuildType = $map[$key]; break }
            Write-Warn '输入无效，请重新输入'
        }
    }

    # --- 线程数 ---
    if (-not $PSBoundParameters.ContainsKey('Jobs') -or $Jobs -le 0) {
        $cores = [Environment]::ProcessorCount
        Write-Log ''
        while ($true) {
            $raw = Read-Host "并行编译线程数（默认全部 $cores 个核心 ；按 q 退出）"
            if ($raw -and $raw.Trim() -eq 'q') { Write-Log ''; Write-Log '  已按用户要求退出。' -ForegroundColor Yellow; exit 0 }
            if ([string]::IsNullOrWhiteSpace($raw)) { $Jobs = $cores; break }
            $n = 0
            if ([int]::TryParse($raw.Trim(), [ref]$n) -and $n -ge 1 -and $n -le 128) { $Jobs = $n; break }
            Write-Warn '请输入 1 到 128 之间的数字（超过本机逻辑处理器个数，可能变慢或者爆内存）'
        }
    }
}

if (-not $BuildType) { $BuildType = 'Release' }
if ($Jobs -le 0) { $Jobs = [Environment]::ProcessorCount }

Write-Ok "构建模式 : $BuildType"
Write-Ok "并行线程 : $Jobs"

# ============================================================================
#  4. 克隆源码（如不存在）
# ============================================================================
Write-Section '4/8 源码准备'

if (Test-Path (Join-Path $SourceDir 'CMakeLists.txt')) {
    Write-Ok "源码已存在，跳过克隆: $SourceDir"
    $head = (& git -C $SourceDir log -1 --format='%h %ad %s' --date=short 2>$null)
    if ($head) { Write-Note "当前提交: $head" }
}
else {
    if (-not $gitPath) {
        Write-Bad 'git 未找到，而源码目录也不存在'
        Write-Note 'winget install --id Git.Git -e'
        exit 1
    }
    $url = 'https://github.com/ggml-org/llama.cpp.git'
    Write-Note "克隆 $url  ->  $SourceDir"
    # [本机实测] PortableGit 的 schannel 后端会报 SEC_E_NO_CREDENTIALS，
    # 强制用 openssl 后端可绕过。若你的 git 正常，这一行也无副作用。
    Invoke-External { & git -c http.sslBackend=openssl clone --depth 1 $url $SourceDir }
    if ($LASTEXITCODE -ne 0) { Write-Bad "git clone 失败（退出码 $LASTEXITCODE）"; exit 1 }
    Write-Ok '克隆完成'
}

# ============================================================================
#  5. 组装 CMake 参数
# ============================================================================
Write-Section '5/8 组装构建参数'

if (-not $BuildDir) {
    $suffix = ($Backend -join '-').ToLower()
    # 构建目录同样跟着当前工作目录
    $BuildDir = Join-Path (Get-Location).ProviderPath "build-$suffix-$use"
}
$BuildDir = [System.IO.Path]::GetFullPath($BuildDir)

# SYCL 后端要用 oneAPI 的 DPC++ 编译器（icx/icpx），而不是 gcc / cl.exe
# ggml-hip/CMakeLists.txt 在静态链接时直接报错，所以选了 HIP 就自动关掉
if (($Backend -contains 'HIP') -and -not $NoStatic) {
    Write-Warn 'HIP/ROCm 不支持静态链接：已自动关闭 -static'
    $NoStatic = $true
}
# 所有加速后端（CUDA 的 cudart/cublas、OpenVINO Runtime、HIP、MUSA、SYCL……）带的
# 都是动态 CRT 编的 DLL。把它们和静态链接的运行时混在一起会破坏堆：推理一启动就以
# 0xC0000409（__fastfail）静默退出。因此 MSVC 一律使用动态 CRT。
if (($use -eq 'msvc') -and -not $NoStatic) {
    Write-Warn 'MSVC：已关闭静态链接（加速后端的第三方 DLL 需要动态 CRT）'
    $NoStatic = $true
}
$useOneApi = ($Backend -contains 'SYCL') -and $oneApiReady
if ($useOneApi -and (Get-ToolPath 'ninja')) { $generator = 'Ninja' }

# OpenVINO 需要先把它的环境引进本进程（设置 OpenVINO_DIR 和 PATH）
if (($Backend -contains 'OpenVINO') -and $ovSetup) {
    Write-Note "初始化 OpenVINO 环境: $ovSetup"
    try { & $ovSetup 2>&1 | ForEach-Object { Write-Note "$_" } } catch { Write-Warn "setupvars.ps1 执行失败：$(($_.Exception.Message -split "`r?`n")[0])" }
}

$cmakeArgs = @('-S', $SourceDir, '-B', $BuildDir, '-G', $generator)

# FindOpenCL 不会自动去 CUDA 目录里找，所以把找到的路径显式传过去
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
        # 避免 exe 依赖 libstdc++-6.dll / libgcc_s_seh-1.dll / libwinpthread-1.dll
        $cmakeArgs += '-DCMAKE_EXE_LINKER_FLAGS=-static'
    }
}
else {
    $cmakeArgs += @('-A', 'x64')
    # MSVC 默认按系统代码页解析源文件，而 llama.cpp 是 UTF-8，会刷 C4819 警告。
    # 这里用 CL 环境变量追加，而不是 -DCMAKE_CXX_FLAGS：后者会整体替换 CMake 的
    # 默认 flags，否则会把 /EHsc 一起丢掉，导致每个用到 C++ 异常的编译单元报 C4530。
    $env:CL = if ($env:CL) { "$env:CL /utf-8" } else { '/utf-8' }
    $noTracker = $false
    try {
        if ((& whoami /groups 2>$null | Out-String) -match 'S-1-16-4096') { $noTracker = $true }
    } catch { }
    if ($noTracker) {
        Write-Warn '已关闭 MSBuild 文件追踪（TrackFileAccess=false）'
        $cmakeArgs += '-DCMAKE_VS_GLOBALS=TrackFileAccess=false'
        # 注意：多进程构建可能因节点通信未能建立而瞬间失败且无输出。
        # 这里不擅自改写用户的并发设置，改为在编译阶段失败后自动降级重试。
    }
    if ($Backend -contains 'CUDA') {
        $env:NVCC_PREPEND_FLAGS = if ($env:NVCC_PREPEND_FLAGS) { "$env:NVCC_PREPEND_FLAGS -Xcompiler=/utf-8" } else { '-Xcompiler=/utf-8' }
    }
    # MSVC / MSBuild 的诊断消息是系统代码页编码的，在 UTF-8 控制台下会变成乱码，
    # 这里直接让它们输出英文。
    if (-not $env:VSLANG) { $env:VSLANG = '1033' }
    if (-not $NoStatic) {
        # MSVC 下 -static 的等价物：静态链接 C 运行时
        $cmakeArgs += '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded'
    }
}

foreach ($b in $Backend) { $cmakeArgs += $BackendDefs[$b].Flags }

# nvcc 通常不在 PATH 上，把检测到的 CUDA 根目录显式交给 CMake
if (($Backend -contains 'CUDA') -and $nvccPath) {
    $cudaRoot = Split-Path (Split-Path $nvccPath -Parent) -Parent
    $cmakeArgs += "-DCUDAToolkit_ROOT=$cudaRoot"

    # VS/MSBuild 的 CUDA 集成读的是版本化变量 CUDA_PATH_V<主>_<次>，不是通用的
    # CUDA_PATH。刚装好的 CUDA 只在机器级设置它，所以装之前就启动的会话里是空的，
    # 这里直接把它导入本进程。
    foreach ($n in @([Environment]::GetEnvironmentVariables('Machine').Keys)) {
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

    # 编译出的程序需要 CUDA 运行库 DLL。CUDA 13 把它们放在 bin\x64（不是 bin），
    # 而装 CUDA 之前启动的会话里没有这个路径，缺了就会以 0xC0000135 退出。
    foreach ($sub in "$cudaRoot\bin\x64", "$cudaRoot\bin") {
        if ((Test-Path $sub) -and (($env:Path -split ';') -notcontains $sub)) {
            $env:Path = "$sub;$env:Path"
        }
    }
}

if ($AvxVnni) { $cmakeArgs += '-DGGML_AVX_VNNI=ON' }
if (-not $WithTests) { $cmakeArgs += '-DLLAMA_BUILD_TESTS=OFF' }

Write-Note "工具链   : $use"
Write-Note "构建目录 : $BuildDir"
Write-Note "生成器   : $generator"
Write-Log ''
Write-Log '  完整命令（可复制）:' -ForegroundColor DarkGray
$printable = ($cmakeArgs | ForEach-Object { if ("$_" -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
Write-Log "  cmake $printable" -ForegroundColor DarkGray

# ============================================================================
#  6. CMake 配置
# ============================================================================
Write-Section '6/8 CMake 配置'

Invoke-External { & cmake @cmakeArgs }
if ($LASTEXITCODE -ne 0) { Write-Bad "CMake 配置失败（退出码 $LASTEXITCODE）"; exit 1 }
Write-Ok '配置完成'

# ============================================================================
#  7. 编译
# ============================================================================
Write-Section '7/8 编译'

$sw = [System.Diagnostics.Stopwatch]::StartNew()
if ($use -eq 'gcc') {
    Invoke-External { & cmake --build $BuildDir --parallel $Jobs }
}
else {
    # 多配置生成器：配置在构建时才指定
    Invoke-External { & cmake --build $BuildDir --config $BuildType --parallel $Jobs }
}
$code = $LASTEXITCODE

    # MSBuild 的多进程节点通信可能未能建立，表现为瞬间失败且无任何输出。
    # 这里改为失败后降为单线程重试，而不是事先篡改用户给的数值。
    if ($code -ne 0 -and $Jobs -gt 1 -and $noTracker) {
        Write-Warn "并发 $Jobs 构建失败，改用单线程重试"
        if ($use -eq 'gcc') { Invoke-External { & cmake --build $BuildDir --parallel 1 } }
        else { Invoke-External { & cmake --build $BuildDir --config $BuildType --parallel 1 } }
        $code = $LASTEXITCODE
    }
$sw.Stop()

if ($code -ne 0) { Write-Bad "编译失败（退出码 $code）"; exit $code }
Write-Ok ("编译成功，用时 {0:N1} 分钟" -f $sw.Elapsed.TotalMinutes)

# ============================================================================
#  8. 验证
# ============================================================================
Write-Section '8/8 验证'

$binDir = Join-Path $BuildDir 'bin'
# 多配置生成器会把产物放进按配置命名的子目录
if ((Test-Path (Join-Path $binDir $BuildType))) { $binDir = Join-Path $binDir $BuildType }

if (-not (Test-Path $binDir)) {
    Write-Bad "没有找到产物目录: $binDir"
    exit 1
}

$exes = Get-ChildItem $binDir -Filter '*.exe' | Sort-Object Name
if (-not $exes) { Write-Bad "$binDir 里没有任何 exe"; exit 1 }

Write-Ok ("产物位于 $binDir —— 共 $($exes.Count) 个可执行文件，完整列表如下：")
$totalKb = 0
foreach ($x in $exes) {
    $totalKb += $x.Length / 1KB
    Write-Note ("{0,-36} {1,10:N0} KB" -f $x.Name, ($x.Length / 1KB))
}
Write-Note ("{0,-36} {1,10:N0} KB" -f '--- 合计 ---', $totalKb)

if (-not $NoVerify) {
    $cli = Join-Path $binDir 'llama-cli.exe'
    if (Test-Path $cli) {
        Write-Log ''
        Write-Note '运行 llama-cli --version 验证：'
        Invoke-External { & $cli --version }
        if ($LASTEXITCODE -eq 0) { Write-Ok 'llama-cli 可正常启动' }
        else { Write-Warn "llama-cli --version 退出码 $LASTEXITCODE" }
    }

    if ($WithTests) {
        Write-Log ''
        Write-Note '运行 ctest：'
        # --test-dir 需要 CMake 3.20+，改用切换目录以兼容 3.14+
        Push-Location $BuildDir
        try { Invoke-External { & ctest -C $BuildType --output-on-failure --parallel $Jobs } }
        finally { Pop-Location }
        if ($LASTEXITCODE -eq 0) { Write-Ok 'ctest 全部通过' } else { Write-Warn "ctest 退出码 $LASTEXITCODE" }
    }
}

# ============================================================================
#  下一步提示
# ============================================================================
Write-Section '完成 —— 下一步'

$rel = Resolve-Path -Relative $binDir -ErrorAction SilentlyContinue
if (-not $rel) { $rel = $binDir }

Write-Log @"
  # 先下载一个模型（GGUF），放到 models\ 目录；也可以直接浏览器下
  # 小模型练手：Qwen2.5-1.5B-Instruct Q4_K_M 约 1 GB
  mkdir models -Force | Out-Null
  hf download Qwen/Qwen2.5-1.5B-Instruct-GGUF qwen2.5-1.5b-instruct-q4_k_m.gguf --local-dir models

  # 交互式对话（直接运行即进入对话，输入 /exit 退出）
  $rel\llama-cli.exe -m models\qwen2.5-1.5b-instruct-q4_k_m.gguf

  # 单轮提问（不进入交互）
  $rel\llama-cli.exe -m models\qwen2.5-1.5b-instruct-q4_k_m.gguf -st -p "你好" -n 128

  # 起 OpenAI 兼容服务（前端可直接连 http://127.0.0.1:8080/v1）
  $rel\llama-server.exe -m models\qwen2.5-1.5b-instruct-q4_k_m.gguf --host 127.0.0.1 --port 8080

  # 测速（CPU/GPU 对比时用它）
  $rel\llama-bench.exe -m models\qwen2.5-1.5b-instruct-q4_k_m.gguf

  # GDB 调试（GCC 工具链，需要 -BuildType RelWithDebInfo 或 Debug 重编）
  gdb --args $rel\llama-cli.exe -m models\qwen2.5-1.5b-instruct-q4_k_m.gguf -p "hi" -n 16
"@ -ForegroundColor Gray

# 只有真的编了 OpenVINO 后端才给这段提示
if ($Backend -contains 'OpenVINO') {
    Write-Log ''
    Write-Log '  ── OpenVINO 后端专用说明 ──────────────────────────────────' -ForegroundColor DarkCyan
    Write-Log '  运行前必须先初始化环境，否则会因为找不到 openvino.dll 直接退出：' -ForegroundColor Gray
    if ($ovSetup) {
        Write-Log "    1) 每个新终端执行一次：" -ForegroundColor Gray
        Write-Log "         & `"$ovSetup`"" -ForegroundColor Gray
    }
    else {
        Write-Log "    1) 先运行 OpenVINO 安装目录下的 setupvars（本机未定位到）" -ForegroundColor Gray
    }
    Write-Log '    2) 选择设备（不设则默认 CPU）：' -ForegroundColor Gray
    Write-Log "         `$env:GGML_OPENVINO_DEVICE = 'NPU'      # 或 GPU.0 / GPU.1 / CPU" -ForegroundColor Gray
    Write-Log '    3) 查看可用设备：' -ForegroundColor Gray
    Write-Log "         $rel\llama-cli.exe --list-devices" -ForegroundColor Gray
    Write-Log '    4) 运行（示例）：' -ForegroundColor Gray
    Write-Log "         $rel\llama-cli.exe -m models\qwen2.5-1.5b-instruct-q4_k_m.gguf -c 8192" -ForegroundColor Gray
}
# --- 关闭开头打开的日志文件 ---
# 无需关闭：日志文件不保留句柄
