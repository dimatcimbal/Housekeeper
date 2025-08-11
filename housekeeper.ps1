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
if (-not ("$VcpkgToolchainFile")) {
    Error "Vcpkg toolchain file not found. Ensure vcpkg is installed and configured."
    return $false
}

# Visual Studio Environment Setup
Log "Finding Visual Studio vcvarsall.bat..." "Cyan"
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
    
Log "Found Visual Studio at: $vsPath" "Green"
$vcvarsPath = Join-Path -Path "$vsPath" -ChildPath "VC\Auxiliary\Build\vcvarsall.bat"


if ($Debug) {
    Log "--- Housekeeper Configuration Check ---"
    Log "Build Directory: $BuildDir"
    Log "ClangFormat Path: $ClangFormatPath"
    Log "CL compiler Path: $clPath"
    Log "CMAKE_TOOLCHAIN_FILE: $VcpkgToolchainFile"
    Log "VCPKG_ROOT: $VcpkgRoot"
    Log "Vcpkg Executable: $VcpkgExe"
    Log "----------------------------------"
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
function Invoke-VsVars {
    param(
        [string]$vcvarsPath,
        [string]$arch = "x64"
    )

    if (-not (Test-Path $vcvarsPath)) {
        Error "vcvarsall.bat not found at '$vcvarsPath'."
        return $false
    }
    
    Log "Setting up Visual Studio environment from '$vcvarsPath' for '$arch'..." "Cyan"

    # Run vcvarsall.bat and dump the environment variables
    $vsEnvOutput = & cmd.exe /c "`"$vcvarsPath`" $arch >NUL && set" 2>&1

    # Loop through the output and set the environment variables in the current session
    foreach ($line in $vsEnvOutput) {
        if ($line -match "^(.+?)=(.*)$") {
            $name = $matches[1]
            $value = $matches[2]
            
            # Special handling for PATH to append instead of replace
            if ($name -eq 'PATH') {
                $env:PATH = $value + ';' + $env:PATH
            } else {
                Set-Item -Path "env:$name" -Value $value -Force
            }
        }
    }
    
    # Check if a critical variable like PATH or INCLUDE has been set
    if ($env:PATH -notlike "*VC\Tools*") {
        Error "Failed to set Visual Studio environment variables."
        return $false
    }

    Success "Visual Studio environment configured successfully."
    return $true
}


function Test-Prerequisites {
    if (-not (Test-Path "CMakeLists.txt")) { Error "CMakeLists.txt not found in current directory."; return $false }
    if (-not (Test-Path "src")) { Error "src/ directory not found."; return $false }
    return $true
}

function Test-ClangFormat {
    if (-not (Test-Path $ClangFormatPath)) {
        Error "clang-format not found at: $ClangFormatPath"
        Warn "Ensure Visual Studio with C++ tools is installed or clang-format is in your PATH."
        return $false
    }
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

function Invoke-Clean {
    Log "Cleaning project..." "Cyan"
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

function Invoke-GetDependencies {
    Log "Installing Vcpkg dependencies..." "Cyan"

    if (-not (Test-Path "$VcpkgManifestFile")) {
        Error "vcpkg.json not found at '$VcpkgManifestFile'. Cannot install dependencies."
        return $false
    }

    Push-Location $PSScriptRoot
    Log "Running 'vcpkg install' from vcpkg.json..."
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
                Log "  [VCPKG] $_" "Green"
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

    Log "Auto-detecting CMake generator..." "Cyan"

    # Prioritize Ninja if available
    $ninjaPath = (Get-Command "ninja" -EA SilentlyContinue).Path
    if ($ninjaPath) {
        $ninjaVersion = (& $ninjaPath --version | Out-String).Trim()
        Log "Detected 'ninja' (v$ninjaVersion) at $ninjaPath. Using 'Ninja' generator." "Green"
        return "Ninja"
    }
    
    # Prioritize Visual Studio 2022 if vswhere is found
    $vsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vsWhere) {
        $vs2022Path = & $vsWhere -latest -products Microsoft.VisualStudio.Product.Community -version "[17.0,18.0)" -property installationPath -EA SilentlyContinue
        if ($vs2022Path) {
            Log "Detected Visual Studio 2022. Using 'Visual Studio 17 2022' generator." "Green"
            return "Visual Studio 17 2022"
        }
    }

    # Fallback if no specific preference or detection
    Warn "No preferred generator (VS 2022, Ninja) auto-detected. CMake will choose default."
    return ""
}

# The optimized core function to handle both CMake generation and building
function Invoke-CMake {
    param(
        [switch]$GenerateOnly = $false,
        [switch]$BuildOnly = $false
    )
    
    # Create build directory if it doesn't exist
    if (-not (Test-Path $BuildDir)) {
        New-Item -ItemType Directory -Path $BuildDir | Out-Null
        Log "Created build directory: .$BuildDir"
    }

    $gen = Get-Generator
    
    $cmakeGenerateArgs = @("..")
    if ($gen) { $cmakeGenerateArgs += @("-G", $gen) }
    $cmakeGenerateArgs += "-DCMAKE_TOOLCHAIN_FILE=$($VcpkgToolchainFile)"

    if ($Debug) {
        $cmakeGenerateArgs += @("--trace-expand", "--debug-output", "--warn-uninitialized")
    }

    $cmakeBuildArgs = @("--build", ".", "--config", $Config)

    Push-Location $BuildDir
    try {
        # --- CMake Generation Step ---
        if (-not $BuildOnly) {
            if (-not (Test-Path "CMakeCache.txt")) {
                Log "Running CMake generation..." "Cyan"
                $buildOutput = & cmake $cmakeGenerateArgs 2>&1
                if ($LASTEXITCODE -ne 0) {
                    Error "CMake generation failed."
                    $buildOutput | ForEach-Object { Error "  [BUILD] $_" }
                    return $false
                }
                Success "Project files generated"
            } else {
                Log "CMake cache found, skipping generation." "Green"
            }
        }
        
        # --- CMake Build Step ---
        if (-not $GenerateOnly) {
            Log "Running CMake build..." "Cyan"
            $buildOutput = & cmake $cmakeBuildArgs 2>&1
            if ($LASTEXITCODE -ne 0) {
                Error "Build failed."
                $buildOutput | ForEach-Object { Error "  [BUILD] $_" }
                return $false
            }
            Success "Build completed"
            $exePath = Get-ChildItem -Path ".\bin", ".\$Config" -Filter "$ProjectName.exe" -Recurse -File | Select-Object -ExpandProperty FullName -First 1
            if ($exePath) { Log "Executable: $exePath" "Green" }
        }
        return $true
    }
    finally {
        Pop-Location
    }
}

function Invoke-Generate {
    Log "Generating project files..." "Cyan"
    return Invoke-CMake -GenerateOnly
}

function Invoke-Build {
    Log "Building project ($Config)..." "Cyan"
    return Invoke-CMake -BuildOnly
}

function Invoke-Format {
    Log "Formatting source code..." "Cyan"
    if (-not (Test-ClangFormat)) { return $false }

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

function Invoke-CheckFormat {
    Log "Checking source code formatting..." "Cyan"
    if (-not (Test-ClangFormat)) { return $false }

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

    if ($activeCount -gt 1) {
        Error "Multiple actions specified. Please choose only one."
        Show-Help; exit 1
    }

    for ($i = 0; $i -lt $actions.Count; $i++) {
        if ($actions[$i]) { return $actionNames[$i] }
    }
    return "rebuild"  # Default action if no specific action is provided
}

# ---
# Main Execution
# ---
Log "housekeeper - Win32 Project Build Script" "Cyan"

$action = Get-Action
Log "Action: $action | Config: $Config"

# Check prerequisites for all actions except 'help'
if ($action -ne "help" -and -not (Test-Prerequisites)) { exit 1 }

# Set up the Visual Studio environment once
if ($action -ne "help") {
    if (-not (Invoke-VsVars -vcvarsPath $vcvarsPath -arch "x64")) {
        exit 1
    }
}

$success = $false
switch ($action) {
    "clean" { $success = Invoke-Clean }
    "format" { $success = Invoke-Format }
    "check-format" { $success = Invoke-CheckFormat }
    "build" { $success = (Invoke-Generate) -and (Invoke-Build) }
    "rebuild" { $success = (Invoke-Clean) -and (Invoke-Generate) -and (Invoke-Build) }
    "generate" { $success = Invoke-Generate }
    "deps" { $success = Invoke-GetDependencies }
    "all" { $success = (Invoke-Format) -and (Invoke-Generate) -and (Invoke-Build) }
    default { Error "Unknown action: $action"; Show-Help; exit 1 }
}
