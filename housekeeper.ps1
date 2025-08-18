#!/usr/bin/env powershell

<#
.SYNOPSIS
    housekeeper - Build automation for Win32 project
.DESCRIPTION
    Clean, build, format, and manage a Win32 application project.
.EXAMPLE
    .\housekeeper.ps1           # Default: clean and build
    .\housekeeper.ps1 -Clean    # Clean only
    .\housekeeper.ps1 -Format   # Format source code
    .\housekeeper.ps1 -All      # Format, generate, and build
#>

# ---
# Script Parameters
# ---
param(
    [switch]$Help,
    [switch]$Clean,
    [switch]$Clear, # Keep Clear as an alias
    [switch]$Build,
    [switch]$Rebuild,
    [switch]$Generate,
    [switch]$Format,
    [switch]$CheckFormat,
    [switch]$All,
    [switch]$Deps,
    [switch]$Verbose,
    [ValidateSet("Debug", "Release")][string]$Config = "Release"
)

# ---
# Constants
# ---
$GEN_VS2022 = "Visual Studio 17 2022"
$GEN_NINJA = "Ninja"
$BUILD_DIR = "build"
$PROJECT_NAME = "DXMiniApp"
$SOURCE_EXTENSIONS = @("*.cpp", "*.c", "*.h", "*.hpp", "*.cc", "*.cxx", "*.hxx")

# ---
# Output helpers
# ---
function Log($msg, $color = "White") { Write-Host "🌿 $msg" -ForegroundColor $color }
function Info($msg) { Write-Host "🌿 $msg" -ForegroundColor Cyan }
function Debug($msg) { Write-Host "🌿 $msg" -ForegroundColor Gray }
function Success($msg) { Write-Host "✅ $msg" -ForegroundColor Green }
function Error($msg) { Write-Host "❌ $msg" -ForegroundColor Red }
function Warn($msg) { Write-Host "⚠️  $msg" -ForegroundColor Yellow }

function Show-Help {
    Write-Host @"
🌿 housekeeper - Win32 Project Build Script

USAGE: .\housekeeper.ps1 [action] [options]

ACTIONS:
    -Help         Show this help
    -Clean        Clean build directory
    -Build        Build project
    -Rebuild      Clean and build (default)
    -Generate     Generate project files only
    -Format       Format source code
    -CheckFormat  Check code formatting
    -All          Format + generate + build

OPTIONS:
    -Config       Debug or Release (default: Release)
    -Debug        Enable verbose debug output

EXAMPLES:
    .\housekeeper.ps1                    # Clean and build
    .\housekeeper.ps1 -Build -Config Debug
    .\housekeeper.ps1 -Format
    .\housekeeper.ps1 -All
"@ -ForegroundColor Cyan
}

function Get-Action {
    if ($Clean -or $Clear) { $Clean = $true; $Clear = $false }
    $actions = @($Clean, $Build, $Rebuild, $Generate, $Format, $CheckFormat, $Deps, $All)
    $actionNames = @("clean", "build", "rebuild", "generate", "format", "check-format", "deps", "all")

    $activeFlags = $actions | Where-Object { $_ -eq $true }
    $activeCount = $activeFlags.Count

    if ($Help) { return "help" }
    if ($activeCount -eq 0) { Show-Help; exit 1 }
    if ($activeCount -gt 1) { Error "Multiple actions specified. Please choose only one."; Show-Help; exit 1 }

    for ($i = 0; $i -lt $actions.Count; $i++) {
        if ($actions[$i]) { return $actionNames[$i] }
    }
    return "rebuild"
}

function Test-Prerequisites {
    if (-not (Test-Path "CMakeLists.txt")) { Error "CMakeLists.txt not found in current directory."; return $false }
    if (-not (Test-Path "src")) { Error "src/ directory not found."; return $false }
    return $true
}

# ---
# Core Functionality
# ---
function Get-SourceFiles {
    $files = @()
    foreach ($dir in @("src", "include")) {
        if (Test-Path $dir) {
            foreach ($ext in $SOURCE_EXTENSIONS) {
                $files += Get-ChildItem -Path $dir -Filter $ext -Recurse -File
            }
        }
    }
    return $files
}

function Read-VsVars {
    param(
        [string]$vcvarsPath,
        [string]$arch = "x64"
    )

    if (-not (Test-Path $vcvarsPath)) { Error "vcvarsall.bat not found at '$vcvarsPath'."; return $false }
    
    Info "Setting up Visual Studio environment from '$vcvarsPath' for '$arch'..."
    $vsEnvOutput = & cmd.exe /c "`"$vcvarsPath`" $arch >NUL && set" 2>&1
    foreach ($line in $vsEnvOutput) {
        if ($line -match "^(.+?)=(.*)$") {
            $name = $matches[1]
            $value = $matches[2]
            if ($name -eq 'PATH') {
                $env:PATH = $env:PATH + ';' + $value
            } else {
                Set-Item -Path "env:$name" -Value $value -Force
            }
        }
    }
    
    if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) { Error "Failed to set Visual Studio environment variables."; return $false }
    $script:clPath = (Get-Command "cl.exe" -EA SilentlyContinue).Path
    Success "Visual Studio environment configured successfully."
    return $true
}

function Get-Dependencies {
    Info "Installing Vcpkg dependencies..."

    if (-not (Test-Path "$VcpkgManifestFile")) { Error "vcpkg.json not found at '$VcpkgManifestFile'. Cannot install dependencies."; return $false }

    Push-Location $PSScriptRoot
    Info "Running 'vcpkg install' from vcpkg.json..."
    try {
        $vcpkgArgs = @("install", "--recurse", "--triplet", "x64-windows")
        if ($Verbose) { $vcpkgArgs += "--debug" }
        $vcpkgOutput = & $VcpkgExe $vcpkgArgs 2>&1

        if ($LASTEXITCODE -ne 0) {
            Error "Vcpkg command failed with exit code $LASTEXITCODE."
            $vcpkgOutput | ForEach-Object { Error "  [VCPKG] $_" }
            return $false
        }
        if ($Verbose) { $vcpkgOutput | ForEach-Object { Debug "  [VCPKG] $_" } }
        Success "Vcpkg dependencies installed successfully."
        return $true
    }
    finally { Pop-Location }
}

function Get-Generator {
    Info "Auto-detecting CMake generator..."
    
    $vsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vsWhere) {
        $vs2022Path = & $vsWhere -latest -products Microsoft.VisualStudio.Product.Community -version "[17.0,18.0)" -property installationPath -EA SilentlyContinue
        if ($vs2022Path) {
            Info "Detected Visual Studio 2022. Using '$GEN_VS2022' generator."
            return $GEN_VS2022
        }
    }
    
    $ninjaPath = (Get-Command "ninja" -EA SilentlyContinue).Path
    if ($ninjaPath) {
        $ninjaVersion = (& $ninjaPath --version | Out-String).Trim()
        Info "Detected 'ninja' (v$ninjaVersion) at $ninjaPath. Using '$GEN_NINJA' generator."
        return $GEN_NINJA
    }
    
    Warn "No preferred generator (VS 2022, Ninja) auto-detected. CMake will choose default."
    return ""
}

function Invoke-CMake {
    param(
        [string]$command,
        [string[]]$arguments
    )

    Info "Running 'cmake $command'..."
    if ($Verbose) { Debug "  Args: $($arguments -join ' ')" }

    $output = & cmake $arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        Error "CMake '$command' failed with exit code $LASTEXITCODE."
        $output | ForEach-Object { Error "  [CMAKE] $_" }
        return $false
    }
    
    if ($Verbose) { $output | ForEach-Object { Debug "  [CMAKE] $_" } }
    Info "CMake '$command' command completed successfully."
    return $true
}

function Run-Clean {
    Info "Cleaning project..."
    if (Test-Path $BUILD_DIR) {
        try {
            Remove-Item -Recurse -Force $BUILD_DIR -ErrorAction Stop
            Success "Build directory cleaned"
            return $true
        }
        catch { Error "Failed to clean: $_"; return $false }
    }
    Warn "Build directory doesn't exist, nothing to clean."
    return $true
}

function Run-Generate {
    Info "Generating project files..."
    if (-not (Test-Path $BUILD_DIR)) {
        New-Item -ItemType Directory -Path $BUILD_DIR | Out-Null
        Info "Created build directory: ./$BUILD_DIR"
    }
    
    if (Test-Path (Join-Path $BUILD_DIR "CMakeCache.txt")) { Info "CMake cache found, skipping generation."; return $true }

    $gen = Get-Generator
    $cmakeGenerateArgs = @("..")
    if ($gen) { $cmakeGenerateArgs += @("-G", $gen) }
    
    if (-not ("$script:VcpkgToolchainFile")) { Error "Vcpkg toolchain file not found."; return $false }
    $cmakeGenerateArgs += "-DCMAKE_TOOLCHAIN_FILE=$($script:VcpkgToolchainFile)"

    if (-not ("$script:clPath")) { Error "cl.exe not found after setting environment."; return $false }
    $cmakeGenerateArgs += "-DCMAKE_C_COMPILER=$script:clPath"
    $cmakeGenerateArgs += "-DCMAKE_CXX_COMPILER=$script:clPath"

    if ($Verbose) { $cmakeGenerateArgs += @("--trace-expand", "--debug-output", "--warn-uninitialized") }

    Push-Location $BUILD_DIR
    try {
        if (-not (Invoke-CMake -command "generate" -arguments $cmakeGenerateArgs)) { return $false }
        Success "Project files generated."
        return $true
    }
    finally { Pop-Location }
}

function Run-Build {
    Info "Building project ($Config)..."
    if (-not (Test-Path $BUILD_DIR)) { Error "Build directory '.\$BUILD_DIR' does not exist. Please run '.\housekeeper.ps1 -Generate' first."; return $false }
    
    $cmakeBuildArgs = @("--build", ".", "--config", $Config)

    Push-Location $BUILD_DIR
    try {
        if (-not (Invoke-CMake -command "build" -arguments $cmakeBuildArgs)) { return $false }
        Success "Build completed."
        $exePath = Get-ChildItem -Path ".\bin", ".\$Config" -Filter "$PROJECT_NAME.exe" -Recurse -File | Select-Object -ExpandProperty FullName -First 1
        if ($exePath) { Info "Executable: $exePath" }
        return $true
    }
    finally { Pop-Location }
}

function Run-Format {
    Info "Formatting source code..."
    $files = Get-SourceFiles
    if (-not $files) { Warn "No source files found to format."; return $true }
    $formattedCount = 0; $failedCount = 0
    foreach ($file in $files) {
        try {
            & $ClangFormatPath -i $file.FullName > $null 2>&1
            if ($LASTEXITCODE -eq 0) { $formattedCount++ } else { Warn "Failed to format: $($file.Name) (Exit Code: $LASTEXITCODE)"; $failedCount++ }
        }
        catch { Error "Error running clang-format on $($file.Name): $_"; $failedCount++ }
    }
    if ($failedCount -eq 0) { Success "Successfully formatted $formattedCount files."; return $true }
    Error "Formatting completed with $failedCount failures out of $($files.Count) files."
    return $false
}

function Check-Format {
    Info "Checking source code formatting..."
    $files = Get-SourceFiles
    if (-not $files) { Warn "No source files found to check formatting for."; return $true }
    $badFiles = @()
    foreach ($file in $files) {
        try {
            & $ClangFormatPath --dry-run --Werror $file.FullName > $null 2>$null
            if ($LASTEXITCODE -ne 0) { $badFiles += $file.Name }
        }
        catch { Error "Error running clang-format dry-run on $($file.Name): $_"; return $false }
    }
    if (-not $badFiles) { Success "All $($files.Count) files are correctly formatted."; return $true }
    Error "The following files are incorrectly formatted:"; $badFiles | ForEach-Object { Error "  - $_" }
    Warn "To fix, run: .\housekeeper.ps1 -Format"
    return $false
}

# ---
# Main Execution
# ---

# Global Configuration
$ClangFormatPath = (Get-Command clang-format -EA SilentlyContinue).Path
if (-not $ClangFormatPath) { Error "clang-format not found."; exit 1 }
$vcpkgRoot = $env:VCPKG_ROOT
$VcpkgToolchainFile = Join-Path "$vcpkgRoot" "scripts\buildsystems\vcpkg.cmake"
$VcpkgManifestFile = Join-Path -Path "$PWD" -ChildPath "vcpkg.json"
$VcpkgExe = Join-Path -Path $vcpkgRoot -ChildPath "vcpkg.exe"
$vsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsPath = & $vsWhere -latest -products Microsoft.VisualStudio.Product.Community -version "[17.0,)" -property installationPath
if (-not $vsPath) { $vsPath = & $vsWhere -latest -products Microsoft.VisualStudio.Product.Professional -version "[17.0,)" -property installationPath }
if (-not $vsPath) { $vsPath = & $vsWhere -latest -products Microsoft.VisualStudio.Product.Enterprise -version "[17.0,)" -property installationPath }
if (-not $vsPath) { Error "Could not find a valid Visual Studio 2022+ installation."; exit 1 }
Debug "Found Visual Studio at: $vsPath"
$vcvarsPath = Join-Path -Path "$vsPath" -ChildPath "VC\Auxiliary\Build\vcvarsall.bat"
$clPath = ""

Info "housekeeper - Win32 Project Build Script"

$action = Get-Action
Info "Action: $action | Config: $Config"

if ($action -ne "help" -and -not (Test-Prerequisites)) { exit 1 }
$nonVsActions = @("help", "format", "check-format", "clean")
if ($action -notin $nonVsActions) {
    if (-not (Read-VsVars -vcvarsPath $vcvarsPath -arch "x64")) { exit 1 }
}

$success = $false
switch ($action) {
    "help" { Show-Help; exit 0 }
    "clean" { $success = Run-Clean }
    "format" { $success = Run-Format }
    "check-format" { $success = Check-Format }
    "build" {
        $success = (Run-Generate)
        if ($success) { $success = (Run-Build) }
    }
    "rebuild" { 
        $success = (Run-Clean)
        if ($success) { $success = (Run-Generate) }
        if ($success) { $success = (Run-Build) }
    }
    "generate" { $success = Run-Generate }
    "deps" { $success = Get-Dependencies }
    "all" { 
        $success = (Run-Format)
        if ($success) { $success = (Run-Generate) }
        if ($success) { $success = (Run-Build) }
    }
    default { Error "Unknown action: $action"; Show-Help; exit 1 }
}

exit ($success -eq $false)