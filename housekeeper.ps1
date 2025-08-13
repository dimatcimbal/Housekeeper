#!/usr/bin/env powershell

<#
.SYNOPSIS
    housekeeper - Build automation for Win32 project
.DESCRIPTION
    Clean, build, format, and manage Win32 application project
.EXAMPLE
    .\housekeeper.ps1           # Default: clean and build
    .\housekeeper.ps1 -Clean    # Clean only
    .\housekeeper.ps1 -Format   # Format source code
    .\housekeeper.ps1 -All      # Format, generate, and build
#>

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
    [switch]$Debug,
    [string]$Generator = "",
    [ValidateSet("Debug", "Release")][string]$Config = "Release"
)

# Output helpers
function Log($msg, $color = "White") { Write-Host "🌿 $msg" -ForegroundColor $color }
function Info($msg) { Write-Host "🌿 $msg" -ForegroundColor Cyan }
function Debug($msg) { Write-Host "🌿 $msg" -ForegroundColor Gray }
function Success($msg) { Write-Host "✅ $msg" -ForegroundColor Green }
function Error($msg) { Write-Host "❌ $msg" -ForegroundColor Red }
function Warn($msg) { Write-Host "⚠️  $msg" -ForegroundColor Yellow }

Info "housekeeper - Win32 Project Build Script"

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
    -Generator    CMake generator ("Visual Studio 17 2022", "Ninja", etc.)
    -Config       Debug or Release (default: Release)
    -Debug        Enable verbose debug output

EXAMPLES:
    .\housekeeper.ps1                    # Clean and build
    .\housekeeper.ps1 -Build -Config Debug
    .\housekeeper.ps1 -Format
    .\housekeeper.ps1 -All
"@ -ForegroundColor Cyan
}

# Global Configuration
$BuildDir = "build"
$ProjectName = "DXMiniApp"
$SourceExtensions = @("*.cpp", "*.c", "*.h", "*.hpp", "*.cc", "*.cxx", "*.hxx")

# Clang Format Configuration
$ClangFormatPath = (Get-Command clang-format -EA SilentlyContinue).Path
if (-not ("$ClangFormatPath")) {
    Error "clang-format not found. Ensure clang-format is installed and configured."
    return $false
}

# Vcpkg Configuration
$vcpkgRoot = $env:VCPKG_ROOT
$VcpkgToolchainFile = Join-Path "$vcpkgRoot" "scripts\buildsystems\vcpkg.cmake"
$VcpkgManifestFile = Join-Path -Path "$PWD" -ChildPath "vcpkg.json" # Path to vcpkg.json
$VcpkgExe = Join-Path -Path $VcpkgRoot -ChildPath "vcpkg.exe"

# Visual Studio Environment Setup
Info "Finding Visual Studio vcvarsall.bat..."
$vsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vsWhere)) {
    Error "vswhere.exe not found. Is Visual Studio installed?"
    return $false
}
    
$vsPath = & $vsWhere -latest -products Microsoft.VisualStudio.Product.Community -version "[17.0,)" -property installationPath
if (-not $vsPath) {
    $vsPath = & $vsWhere -latest -products Microsoft.VisualStudio.Product.Professional -version "[17.0,)" -property installationPath
    if (-not $vsPath) {
        $vsPath = & $vsWhere -latest -products Microsoft.VisualStudio.Product.Enterprise -version "[17.0,)" -property installationPath
    }
}
    
if (-not $vsPath) {
    Error "Could not find a valid Visual Studio 2022+ installation."
    return $false
}

Debug "Found Visual Studio at: $vsPath"
$vcvarsPath = Join-Path -Path "$vsPath" -ChildPath "VC\Auxiliary\Build\vcvarsall.bat"

# We will move the CL path check into the Read-VsVars function, as requested.
$clPath = "" 

if ($Debug) {
    Debug "--- Housekeeper Configuration Check ---"
    Debug "Build Directory: $BuildDir"
    Debug "ClangFormat Path: $ClangFormatPath"
    Debug "VCPKG_ROOT: $VcpkgRoot"
    Debug "Vcpkg Executable: $VcpkgExe"
    Debug "----------------------------------"
}

# ---
# Early Help Exit
# ---
if ($Help) {
    Show-Help
    exit 0
}

# ---
# Core Functions
# ---
function Read-VsVars {
    param(
        [string]$vcvarsPath,
        [string]$arch = "x64"
    )

    if (-not (Test-Path $vcvarsPath)) {
        Error "vcvarsall.bat not found at '$vcvarsPath'."
        return $false
    }
    
    Info "Setting up Visual Studio environment from '$vcvarsPath' for '$arch'..."

    # Run vcvarsall.bat and dump the environment variables
    $vsEnvOutput = & cmd.exe /c "`"$vcvarsPath`" $arch >NUL && set" 2>&1

    # Loop through the output and set the environment variables in the current session
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
    
    # Check if a critical variable like PATH or INCLUDE has been set
    if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
        Error "Failed to set Visual Studio environment variables."
        return $false
    }

    # Set the global clPath variable
    $script:clPath = (Get-Command "cl.exe" -EA SilentlyContinue).Path

    Success "Visual Studio environment configured successfully."
    return $true
}

function Get-SourceFiles {
    $files = @()
    foreach ($dir in @("src", "include")) {
        if (Test-Path $dir) {
            foreach ($ext in $SourceExtensions) {
                $files += Get-ChildItem -Path $dir -Filter $ext -Recurse -File
            }
        }
    }
    return $files
}

function Run-Clean {
    Info "Cleaning project..."
    if (Test-Path $BuildDir) {
        try {
            Remove-Item -Recurse -Force $BuildDir -ErrorAction Stop
            Success "Build directory cleaned"
            return $true
        }
        catch { Error "Failed to clean: $_"; return $false }
    }
    Warn "Build directory doesn't exist, nothing to clean."
    return $true
}

function Get-Dependencies {
    Info "Installing Vcpkg dependencies..."

    if (-not (Test-Path "$VcpkgManifestFile")) {
        Error "vcpkg.json not found at '$VcpkgManifestFile'. Cannot install dependencies."
        return $false
    }

    Push-Location $PSScriptRoot
    Info "Running 'vcpkg install' from vcpkg.json..."
    try {
        $vcpkgArgs = @("install", "--recurse", "--triplet", "x64-windows")

        if ($Debug) {
            $vcpkgArgs += "--debug"
        }

       $vcpkgOutput = & $VcpkgExe $vcpkgArgs 2>&1

        if ($LASTEXITCODE -ne 0) {
            Error "Vcpkg command failed with exit code $LASTEXITCODE."
            $vcpkgOutput | ForEach-Object {
                Error "  [VCPKG] $_"
            }
            return $false
        }

        if ($Debug) {
            $vcpkgOutput | ForEach-Object {
                Debug "  [VCPKG] $_"
            }
        }

        Success "Vcpkg dependencies installed successfully."
        return $true
    }
    finally {
        Pop-Location
    }
}

function Get-Generator {
    if ($Generator) { return $Generator }

    Info "Auto-detecting CMake generator..."

    # Prioritize Ninja if available
    $ninjaPath = (Get-Command "ninja" -EA SilentlyContinue).Path
    if ($ninjaPath) {
        $ninjaVersion = (& $ninjaPath --version | Out-String).Trim()
        Info "Detected 'ninja' (v$ninjaVersion) at $ninjaPath. Using 'Ninja' generator."
        return "Ninja"
    }
    
    # Prioritize Visual Studio 2022 if vswhere is found
    $vsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vsWhere) {
        $vs2022Path = & $vsWhere -latest -products Microsoft.VisualStudio.Product.Community -version "[17.0,18.0)" -property installationPath -EA SilentlyContinue
        if ($vs2022Path) {
            Info "Detected Visual Studio 2022. Using 'Visual Studio 17 2022' generator."
            return "Visual Studio 17 2022"
        }
    }

    # Fallback if no specific preference or detection
    Warn "No preferred generator (VS 2022, Ninja) auto-detected. CMake will choose default."
    return ""
}

# Helper function to handle CMake invocation.
function Run-CMake {
    param(
        [string]$command,
        [string[]]$arguments
    )

    Info "Running 'cmake $command'..."
    if ($Debug) {
        Debug "  Args: $($arguments -join ' ')"
    }

    $output = & cmake $arguments 2>&1

    if ($LASTEXITCODE -ne 0) {
        Error "CMake '$command' failed with exit code $LASTEXITCODE."
        $output | ForEach-Object { Error "  [CMAKE] $_" }
        return $false
    }
    
    if ($Debug) {
        $output | ForEach-Object { Debug "  [CMAKE] $_" }
    }
    
    Info "CMake '$command' command completed successfully."
    return $true
}

function Run-Generate {
    Info "Generating project files..."

    # Create build directory if it doesn't exist
    if (-not (Test-Path $BuildDir)) {
        New-Item -ItemType Directory -Path $BuildDir | Out-Null
        Info "Created build directory: ./$BuildDir"
    }
    
    # Do not re-run generation if cache exists
    if (Test-Path (Join-Path $BuildDir "CMakeCache.txt")) {
        Info "CMake cache found, skipping generation."
        return $true
    }

    $gen = Get-Generator
    
    $cmakeGenerateArgs = @("..")
    if ($gen) { $cmakeGenerateArgs += @("-G", $gen) }
    
    # Add the toolchain file dependency 
    if (-not ("$script:VcpkgToolchainFile")) {
        Error "Vcpkg toolchain file not found. Ensure vcpkg is installed and configured."
        return $false
    }
    $cmakeGenerateArgs += "-DCMAKE_TOOLCHAIN_FILE=$($script:VcpkgToolchainFile)"

    # Add CL compiler paths to CMake arguments
    if (-not ("$script:clPath")) {
        Error "cl.exe not found after setting environment. Ensure Visual Studio with C++ tools is installed and configured."
        return $false
    }
    $cmakeGenerateArgs += "-DCMAKE_C_COMPILER=$script:clPath"
    $cmakeGenerateArgs += "-DCMAKE_CXX_COMPILER=$script:clPath"

    if ($Debug) {
        $cmakeGenerateArgs += @("--trace-expand", "--debug-output", "--warn-uninitialized")
    }

    Push-Location $BuildDir
    try {
        if (-not (Run-CMake -command "generate" -arguments $cmakeGenerateArgs)) {
            return $false
        }
        Success "Project files generated."
        return $true
    }
    finally {
        Pop-Location
    }
}

# Refactored `Invoke-Build`
function Run-Build {
    Info "Building project ($Config)..."

    if (-not (Test-Path $BuildDir)) {
        Error "Build directory '.\$BuildDir' does not exist. Please run '.\housekeeper.ps1 -Generate' first."
        return $false
    }
    
    $cmakeBuildArgs = @("--build", ".", "--config", $Config)

    Push-Location $BuildDir
    try {
        if (-not (Run-CMake -command "build" -arguments $cmakeBuildArgs)) {
            return $false
        }
        Success "Build completed."
        $exePath = Get-ChildItem -Path ".\bin", ".\$Config" -Filter "$ProjectName.exe" -Recurse -File | Select-Object -ExpandProperty FullName -First 1
        if ($exePath) { Info "Executable: $exePath" }
        return $true
    }
    finally {
        Pop-Location
    }
}

function Run-Format {
    Info "Formatting source code..."

    $files = Get-SourceFiles
    if (-not $files) { Warn "No source files found to format."; return $true }

    $formattedCount = 0
    $failedCount = 0

    foreach ($file in $files) {
        try {
            & $ClangFormatPath -i $file.FullName > $null 2>&1
            if ($LASTEXITCODE -eq 0) {
                $formattedCount++
            } else {
                Warn "Failed to format: $($file.Name) (Exit Code: $LASTEXITCODE)"
                $failedCount++
            }
        }
        catch {
            Error "Error running clang-format on $($file.Name): $_"
            $failedCount++
        }
    }

    if ($failedCount -eq 0) {
        Success "Successfully formatted $formattedCount files."
        return $true
    } else {
        Error "Formatting completed with $failedCount failures out of $($files.Count) files."
        return $false
    }
}

function Check-Format {
    Info "Checking source code formatting..."

    $files = Get-SourceFiles
    if (-not $files) { Warn "No source files found to check formatting for."; return $true }

    $badFiles = @()
    foreach ($file in $files) {
        try {
            # --dry-run and --Werror will cause a non-zero exit code if file is not formatted
            & $ClangFormatPath --dry-run --Werror $file.FullName > $null 2>$null
            if ($LASTEXITCODE -ne 0) {
                $badFiles += $file.Name
            }
        }
        catch {
            Error "Error running clang-format dry-run on $($file.Name): $_"
            return $false
        }
    }

    if (-not $badFiles) {
        Success "All $($files.Count) files are correctly formatted."
        return $true
    } else {
        Error "The following files are incorrectly formatted:"
        $badFiles | ForEach-Object { Error "  - $_" }
        Warn "To fix, run: .\housekeeper.ps1 -Format"
        return $false
    }
}

# ---
# Action Orchestration
# ---
function Get-Action {
    # Check if Clean or Clear is provided, and treat them as the same action
    if ($Clean -or $Clear) {
        $Clean = $true # Ensure Clean is true if either is provided
        $Clear = $false # Reset Clear to avoid double counting
    }

    $actions = @($Clean, $Build, $Rebuild, $Generate, $Format, $CheckFormat, $Deps, $All)
    $actionNames = @("clean", "build", "rebuild", "generate", "format", "check-format", "deps", "all")

    # Filter out empty or false actions to count only truly active ones
    $activeFlags = $actions | Where-Object { $_ -eq $true }
    $activeCount = $activeFlags.Count

    if ($Help) {
        return "help"
    }

    # If no arguments were provided, show help by default
    if ($activeCount -eq 0) {
        Show-Help; exit 1
    }

    if ($activeCount -gt 1) {
        Error "Multiple actions specified. Please choose only one."
        Show-Help; exit 1
    }

    for ($i = 0; $i -lt $actions.Count; $i++) {
        if ($actions[$i]) { return $actionNames[$i] }
    }
    return "rebuild"  # Default action if no specific action is provided
}

function Test-Prerequisites {
    if (-not (Test-Path "CMakeLists.txt")) { Error "CMakeLists.txt not found in current directory."; return $false }
    if (-not (Test-Path "src")) { Error "src/ directory not found."; return $false }
    return $true
}

# ---
# Main Execution
# ---
$action = Get-Action
Info "Action: $action | Config: $Config"

# Check prerequisites for all actions except 'help'
if ($action -ne "help" -and -not (Test-Prerequisites)) { exit 1 }

# Set up the Visual Studio environment once
$nonVsActions = @("help", "format", "check-format", "clean")
if ($action -notin $nonVsActions) {
    if (-not (Read-VsVars -vcvarsPath $vcvarsPath -arch "x64")) {
        exit 1
    }
}

$success = $false
switch ($action) {
    "help" { Show-Help; exit 0 }
    "clean" { $success = Run-Clean }
    "format" { $success = Run-Format }
    "check-format" { $success = Check-Format }
    "build" {
        $success = (Run-Generate)
        if ($success) {
            $success = (Run-Build)
        }
    }
    "rebuild" { 
        $success = (Run-Clean)
        if ($success) {
            $success = (Run-Generate)
        }
        if ($success) {
            $success = (Run-Build)
        }
    }
    "generate" { $success = Run-Generate
    }
    "deps" { $success = Get-Dependencies }
    "all" { 
        $success = (Run-Format)
        if ($success) {
            $success = (Run-Generate)
        }
        if ($success) {
            $success = (Run-Build)
        }
    }
    default { Error "Unknown action: $action"; Show-Help; exit 1 }
}
