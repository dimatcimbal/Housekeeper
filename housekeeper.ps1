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
    [string]$Generator = "",
    [ValidateSet("Debug", "Release")][string]$Config = "Release"
)

# Configuration
$BuildDir = "build"
$ProjectName = "DXMiniApp"
$SourceExtensions = @("*.cpp", "*.c", "*.h", "*.hpp", "*.cc", "*.cxx", "*.hxx")

# Clang Format Configuration
$ClangFormatPath = (Get-Command clang-format -EA SilentlyContinue).Source
if (-not ("$ClangFormatPath")) {
    Error "clang-format not found. Ensure clang-format is installed and configured."
    return $false
}

# Vcpkg Configuration
$vcpkgCommand = Get-Command vcpkg.exe -EA SilentlyContinue
$VcpkgExe = $vcpkgCommand.Source
$vcpkgRoot = Split-Path "$VcpkgExe" -Parent
$VcpkgToolchainFile = Join-Path "$vcpkgRoot" "scripts\buildsystems\vcpkg.cmake"
$VcpkgManifestFile = Join-Path -Path "$PWD" -ChildPath "vcpkg.json" # Path to vcpkg.json

if (-not ("$VcpkgToolchainFile")) {
    Error "Vcpkg toolchain file not found. Ensure vcpkg is installed and configured."
    return $false
}

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

EXAMPLES:
    .\housekeeper.ps1                    # Clean and build
    .\housekeeper.ps1 -Build -Config Debug
    .\housekeeper.ps1 -Format
    .\housekeeper.ps1 -All
"@ -ForegroundColor Cyan
}

# ---
# Early Help Exit
# ---
if ($Help) {
    Show-Help
    exit 0
}

# ---
# Configuration
# ---
$BuildDir = "build"
$ProjectName = "DXMiniApp"
# Try to find clang-format automatically or fall back to a common path
$ClangFormatPath = (Get-Command clang-format -EA SilentlyContinue).Source
if (-not $ClangFormatPath) {
    # Fallback to common VS 2022 path if not found in PATH
    $ClangFormatPath = "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\Llvm\x64\bin\clang-format.exe"
}
$SourceExtensions = @("*.cpp", "*.c", "*.h", "*.hpp", "*.cc", "*.cxx", "*.hxx")

# ---
# Core Functions
# ---
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

    try {
        Push-Location $PSScriptRoot # Ensure we are in the project root where vcpkg.json resides
        Log "Running 'vcpkg install' from vcpkg.json..."
        # Use --recurse to ensure all dependencies are installed
        # Use --triplet for Windows (x64-windows is common default)
        & $VcpkgExe install --recurse --triplet x64-windows > $null 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Failed to install dependencies from vcpkg.json." }
        Pop-Location
        Success "Vcpkg dependencies installed successfully."
        return $true
    }
    catch {
        Error "Failed to install Vcpkg dependencies: $_"
        Pop-Location -ErrorAction SilentlyContinue # Ensure we pop if an error occurred
        return $false
    }
}

function Get-Generator {
    if ($Generator) { return $Generator }

    Log "Auto-detecting CMake generator..." "Cyan"

    # Prioritize Ninja if available
    if (Get-Command "ninja" -EA SilentlyContinue) {
        Log "Detected 'ninja'. Using 'Ninja' generator." "Green"
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
    Warn "No preferred generator (Ninja, VS 2022) auto-detected. CMake will choose default."
    return ""
}

function Invoke-Generate {
    Log "Generating project files..." "Cyan"

    if (-not (Test-Path $BuildDir)) {
        New-Item -ItemType Directory -Path $BuildDir | Out-Null
        Log "Created build directory: .$BuildDir"
    }

    Push-Location $BuildDir
    try {
        $gen = Get-Generator
        $args = @("..")
        if ($gen) { $args += @("-G", $gen) }
        # Add Vcpkg toolchain file to CMake arguments
        $args += @("-DCMAKE_TOOLCHAIN_FILE=`"$VcpkgToolchainFile`"")

        $output = & cmake $args 2>&1
        if ($LASTEXITCODE -ne 0) {
            Error "CMake configuration failed:"
            $output | ForEach-Object { Write-Host "  [CMAKE] $_" -ForegroundColor Red }
            throw "Configuration failed"
        }

        Success "Project files generated"
        return $true
    }
    catch { Error "Generation failed: $_"; return $false }
    finally { Pop-Location }
}

function Invoke-Build {
    Log "Building project ($Config)..." "Cyan"

    if (-not (Test-Path "$BuildDir/CMakeCache.txt")) {
        Warn "Project files not found, attempting to generate..."

        if (-not (Invoke-Generate)) {
            Error "Failed to generate project files. Cannot build."
            return $false
        }
    }

    Push-Location $BuildDir
    try {
        $output = & cmake --build . --config $Config 2>&1
        if ($LASTEXITCODE -ne 0) {
            Error "Build failed:"
            $output | ForEach-Object { Write-Host "  [CMAKE] $_" -ForegroundColor Red }
            throw "Build failed"
        }

        Success "Build completed"

        # Show executable location
        $exePath = Get-ChildItem -Path ".\bin", ".\$Config" -Filter "$ProjectName.exe" -Recurse -File | Select-Object -ExpandProperty FullName -First 1
        if ($exePath) { Log "Executable: $exePath" "Green" }
        return $true
    }
    catch { Error "Build failed: $_"; return $false }
    finally { Pop-Location }
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
        $badFiles | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
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
Log "🌿 housekeeper - Win32 Project Build Script" "Cyan"

$action = Get-Action
Log "Action: $action | Config: $Config"

# Check prerequisites for all actions except 'help'
if ($action -ne "help" -and -not (Test-Prerequisites)) { exit 1 }

$success = $false
switch ($action) {
    "clean" { $success = Invoke-Clean }
    "format" { $success = Invoke-Format }
    "check-format" { $success = Invoke-CheckFormat }
    "build" { $success = Invoke-Build }
    "rebuild" { $success = (Invoke-Clean) -and (Invoke-Build) }
    "generate" { $success = Invoke-Generate }
    "deps" { $success = Invoke-GetDependencies }
    "all" { $success = (Invoke-Format) -and (Invoke-Generate) -and (Invoke-Build) }
    default { Error "Unknown action: $action"; Show-Help; exit 1 }
}
