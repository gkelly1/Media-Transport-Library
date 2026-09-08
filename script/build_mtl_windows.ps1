<#
.SYNOPSIS
Builds and installs MTL natively on Windows with MSVC, Meson, and Ninja.

.DESCRIPTION
Run this script from a Visual Studio Developer PowerShell or Developer
Command Prompt after DPDK has been prepared by script/build_dpdk_windows.ps1.

The script uses explicit source/build paths, builds projects in dependency
order (mtl -> app -> tests -> plugins -> RxTxApp), installs into a script-
owned prefix by default, and skips Linux-only components (ld_preload, manager).

.PARAMETER BuildType
Meson build type (release, debug, debugoptimized, plain).

.PARAMETER Force
Remove only script-owned MTL build directories before rebuilding.
If install prefix is under WorkspaceRoot, it is also removed.

.PARAMETER ValidateOnly
Validate prerequisites and print resolved layout without building.

.PARAMETER WorkspaceRoot
MTL native build workspace root (default: <repo>\build\windows-mtl).

.PARAMETER DpdkInstallPrefix
DPDK install prefix (default: <repo>\build\windows-dpdk\install).

.PARAMETER DpdkSourceDir
DPDK source root used by MTL's dpdk_root_dir Meson option
(default: <repo>\build\windows-dpdk\src\dpdk-${DPDK_VER}).

.PARAMETER MtlInstallPrefix
MTL install prefix (default: <WorkspaceRoot>\install).

.EXAMPLE
.\script\build_mtl_windows.ps1

.EXAMPLE
.\script\build_mtl_windows.ps1 -BuildType debug -Force

.EXAMPLE
.\script\build_mtl_windows.ps1 -ValidateOnly
#>
[CmdletBinding()]
param(
  [ValidateSet('release', 'debug', 'debugoptimized', 'plain')]
  [string]$BuildType = 'release',
  [switch]$Force,
  [switch]$ValidateOnly,
  [string]$WorkspaceRoot,
  [string]$DpdkInstallPrefix,
  [string]$DpdkSourceDir,
  [string]$MtlInstallPrefix
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Info {
  param([string]$Message)
  Write-Host "[INFO] $Message"
}

function Write-Step {
  param([string]$Message)
  Write-Host "`n==> $Message"
}

function Assert-Tool {
  param([string]$CommandName, [string]$Hint)
  if (-not (Get-Command -Name $CommandName -ErrorAction SilentlyContinue)) {
    throw "Missing required tool: $CommandName. $Hint"
  }
}

function Assert-PathExists {
  param([string]$PathToCheck, [string]$Hint)
  if (-not (Test-Path -LiteralPath $PathToCheck)) {
    throw "Required path not found: $PathToCheck. $Hint"
  }
}

function Ensure-Directory {
  param([string]$PathToCreate)
  if (-not (Test-Path -LiteralPath $PathToCreate)) {
    New-Item -ItemType Directory -Path $PathToCreate | Out-Null
  }
}

function Get-RepoRoot {
  return (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}

function Parse-VersionsEnv {
  param([string]$FilePath)

  if (-not (Test-Path -LiteralPath $FilePath)) {
    throw "versions.env not found at: $FilePath"
  }

  $result = @{}
  foreach ($line in Get-Content -LiteralPath $FilePath) {
    if ($line -match '^\s*#') { continue }
    if ($line -match '^\s*$') { continue }
    if ($line -match '^\s*([A-Za-z0-9_]+)\s*=\s*(.+?)\s*$') {
      $key = $Matches[1]
      $value = $Matches[2].Trim()
      if (($value.StartsWith('"') -and $value.EndsWith('"')) -or
          ($value.StartsWith("'") -and $value.EndsWith("'"))) {
        $value = $value.Substring(1, $value.Length - 2)
      }
      $result[$key] = $value
    }
  }
  return $result
}

function Assert-PathInside {
  param([string]$RootPath, [string]$CandidatePath)

  $root = [System.IO.Path]::GetFullPath($RootPath).TrimEnd('\', '/')
  $candidate = [System.IO.Path]::GetFullPath($CandidatePath).TrimEnd('\', '/')
  $prefix = $root + [System.IO.Path]::DirectorySeparatorChar
  if (-not ($candidate -eq $root -or $candidate.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase))) {
    throw "Refusing to remove path outside script-owned root: $CandidatePath"
  }
}

function Remove-SafeDirectory {
  param([string]$RootPath, [string]$TargetPath)

  if (-not (Test-Path -LiteralPath $TargetPath)) {
    return
  }
  Assert-PathInside -RootPath $RootPath -CandidatePath $TargetPath
  Write-Info "Removing: $TargetPath"
  Remove-Item -LiteralPath $TargetPath -Recurse -Force
}

function Invoke-CheckedCommand {
  param(
    [Parameter(Mandatory = $true)][string]$CommandName,
    [string[]]$Arguments,
    [string]$FailureMessage
  )

  if ($Arguments) {
    & $CommandName @Arguments
  } else {
    & $CommandName
  }
  if ($LASTEXITCODE -ne 0) {
    if (-not $FailureMessage) {
      $FailureMessage = "Command failed: $CommandName $($Arguments -join ' ')"
    }
    throw $FailureMessage
  }
}

function Add-PkgConfigPath {
  param([string[]]$PathsToAdd)

  $pathSeparator = [System.IO.Path]::PathSeparator
  $allPaths = [System.Collections.Generic.List[string]]::new()
  foreach ($p in $PathsToAdd) {
    if ($p) {
      $allPaths.Add([System.IO.Path]::GetFullPath($p))
    }
  }
  if ($env:PKG_CONFIG_PATH) {
    foreach ($p in $env:PKG_CONFIG_PATH.Split($pathSeparator, [System.StringSplitOptions]::RemoveEmptyEntries)) {
      $allPaths.Add($p)
    }
  }

  $unique = [System.Collections.Generic.List[string]]::new()
  $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($p in $allPaths) {
    if ($seen.Add($p)) {
      $unique.Add($p)
    }
  }
  $env:PKG_CONFIG_PATH = ($unique -join $pathSeparator)
}

function Build-MesonProject {
  param(
    [string]$ProjectName,
    [string]$SourceDir,
    [string]$BuildDir,
    [string]$InstallPrefix,
    [string]$BuildTypeValue,
    [string[]]$ExtraSetupArgs
  )

  Write-Step "Configuring $ProjectName"
  $setupArgs = @(
    'setup'
    $BuildDir
    $SourceDir
    "--prefix=$InstallPrefix"
    "--buildtype=$BuildTypeValue"
  )
  if ($ExtraSetupArgs) {
    $setupArgs += $ExtraSetupArgs
  }
  if (Test-Path -LiteralPath $BuildDir) {
    $setupArgs += '--reconfigure'
  }
  Invoke-CheckedCommand -CommandName 'meson' -Arguments $setupArgs -FailureMessage "Meson setup failed for $ProjectName."

  Write-Step "Compiling $ProjectName"
  Invoke-CheckedCommand -CommandName 'meson' -Arguments @('compile', '-C', $BuildDir) -FailureMessage "Meson compile failed for $ProjectName."

  Write-Step "Installing $ProjectName"
  Invoke-CheckedCommand -CommandName 'meson' -Arguments @('install', '-C', $BuildDir) -FailureMessage "Meson install failed for $ProjectName."
}

if (-not $IsWindows) {
  throw "This script is Windows-only. Run from native PowerShell on Windows."
}

$repoRoot = Get-RepoRoot
$versions = Parse-VersionsEnv -FilePath (Join-Path $repoRoot 'versions.env')
if (-not $versions.ContainsKey('DPDK_VER')) {
  throw "DPDK_VER not found in versions.env"
}
$dpdkVersion = $versions['DPDK_VER']

if (-not $WorkspaceRoot) {
  $WorkspaceRoot = Join-Path $repoRoot 'build\windows-mtl'
}
if (-not $DpdkInstallPrefix) {
  $DpdkInstallPrefix = Join-Path $repoRoot 'build\windows-dpdk\install'
}
if (-not $DpdkSourceDir) {
  $DpdkSourceDir = Join-Path $repoRoot "build\windows-dpdk\src\dpdk-$dpdkVersion"
}
if (-not $MtlInstallPrefix) {
  $MtlInstallPrefix = Join-Path $WorkspaceRoot 'install'
}

$WorkspaceRoot = [System.IO.Path]::GetFullPath($WorkspaceRoot)
$DpdkInstallPrefix = [System.IO.Path]::GetFullPath($DpdkInstallPrefix)
$DpdkSourceDir = [System.IO.Path]::GetFullPath($DpdkSourceDir)
$MtlInstallPrefix = [System.IO.Path]::GetFullPath($MtlInstallPrefix)

$mtlBuildDir = Join-Path $WorkspaceRoot 'lib'
$appBuildDir = Join-Path $WorkspaceRoot 'app'
$testsBuildDir = Join-Path $WorkspaceRoot 'tests'
$pluginsBuildDir = Join-Path $WorkspaceRoot 'plugins'
$rxTxAppBuildDir = Join-Path $WorkspaceRoot 'rxtxapp'

$repoPathsToCheck = @(
  (Join-Path $repoRoot 'meson.build'),
  (Join-Path $repoRoot 'lib\meson.build'),
  (Join-Path $repoRoot 'app\meson.build'),
  (Join-Path $repoRoot 'tests\meson.build'),
  (Join-Path $repoRoot 'plugins\meson.build'),
  (Join-Path $repoRoot 'tests\tools\RxTxApp\meson.build')
)

Write-Step "Checking prerequisites"
Assert-Tool -CommandName 'meson' -Hint 'Install Meson (for example: py -m pip install meson).'
Assert-Tool -CommandName 'ninja' -Hint 'Install Ninja and ensure ninja.exe is in PATH.'
Assert-Tool -CommandName 'cl.exe' -Hint 'Run from a Visual Studio Developer shell.'
Assert-Tool -CommandName 'link.exe' -Hint 'Run from a Visual Studio Developer shell.'
Assert-Tool -CommandName 'lib.exe' -Hint 'Run from a Visual Studio Developer shell.'
$pkgConfigTool = $null
if (Get-Command -Name 'pkg-config' -ErrorAction SilentlyContinue) {
  $pkgConfigTool = 'pkg-config'
} elseif (Get-Command -Name 'pkgconf' -ErrorAction SilentlyContinue) {
  $pkgConfigTool = 'pkgconf'
} else {
  throw 'Missing required tool: pkg-config (or pkgconf). Meson uses it to locate libdpdk and mtl dependencies.'
}

foreach ($path in $repoPathsToCheck) {
  Assert-PathExists -PathToCheck $path -Hint 'Verify the script is running inside a complete Media-Transport-Library checkout.'
}

if (-not $env:VSCMD_VER -and -not $env:VisualStudioVersion) {
  Write-Info 'Visual Studio environment marker variables are not set. Continuing because MSVC tools are present.'
}

$dpdkIncludeDir = Join-Path $DpdkInstallPrefix 'include'
$dpdkLibDir = Join-Path $DpdkInstallPrefix 'lib'
$dpdkPkgConfigDir = Join-Path $dpdkLibDir 'pkgconfig'
$dpdkPc = Join-Path $dpdkPkgConfigDir 'libdpdk.pc'
$dpdkWindowsIncludeDir = Join-Path $DpdkSourceDir 'lib\eal\windows\include'

Assert-PathExists -PathToCheck $DpdkInstallPrefix -Hint 'Build DPDK first: .\script\build_dpdk_windows.ps1'
Assert-PathExists -PathToCheck $DpdkIncludeDir -Hint 'DPDK install is incomplete; include directory is missing.'
Assert-PathExists -PathToCheck $dpdkLibDir -Hint 'DPDK install is incomplete; lib directory is missing.'
Assert-PathExists -PathToCheck $dpdkPkgConfigDir -Hint 'DPDK install is incomplete; pkgconfig directory is missing.'
Assert-PathExists -PathToCheck $dpdkPc -Hint 'DPDK install is incomplete; libdpdk.pc is missing.'
Assert-PathExists -PathToCheck $DpdkSourceDir -Hint 'Provide -DpdkSourceDir with the DPDK source used by build_dpdk_windows.ps1.'
Assert-PathExists -PathToCheck $dpdkWindowsIncludeDir -Hint 'dpdk_root_dir is invalid; expected lib\eal\windows\include under DPDK source.'
$dpdkArtifacts = @(Get-ChildItem -LiteralPath $dpdkLibDir -Recurse -File | Where-Object {
    $_.Name -like '*rte_eal*.lib' -or $_.Name -like '*rte_eal*.a' -or $_.Name -like '*rte_eal*.dll'
  })
if ($dpdkArtifacts.Count -eq 0) {
  throw "DPDK install validation failed: no rte_eal artifacts were found under $dpdkLibDir."
}

Ensure-Directory -PathToCreate $WorkspaceRoot
if ($Force) {
  Write-Step "Cleaning script-owned MTL build directories"
  Remove-SafeDirectory -RootPath $WorkspaceRoot -TargetPath $mtlBuildDir
  Remove-SafeDirectory -RootPath $WorkspaceRoot -TargetPath $appBuildDir
  Remove-SafeDirectory -RootPath $WorkspaceRoot -TargetPath $testsBuildDir
  Remove-SafeDirectory -RootPath $WorkspaceRoot -TargetPath $pluginsBuildDir
  Remove-SafeDirectory -RootPath $WorkspaceRoot -TargetPath $rxTxAppBuildDir
  if (Test-Path -LiteralPath $MtlInstallPrefix) {
    if ($MtlInstallPrefix.StartsWith($WorkspaceRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
      Remove-SafeDirectory -RootPath $WorkspaceRoot -TargetPath $MtlInstallPrefix
    } else {
      Write-Info "Not removing custom MtlInstallPrefix outside WorkspaceRoot: $MtlInstallPrefix"
    }
  }
}

Add-PkgConfigPath -PathsToAdd @($dpdkPkgConfigDir)
Invoke-CheckedCommand -CommandName $pkgConfigTool -Arguments @('--exists', 'libdpdk') -FailureMessage "Unable to resolve libdpdk via $pkgConfigTool. Check PKG_CONFIG_PATH and DPDK install prefix."

Write-Step "Native MSVC MTL layout"
Write-Host "  DPDK source:        $DpdkSourceDir"
Write-Host "  DPDK install:       $DpdkInstallPrefix"
Write-Host "  MTL workspace root: $WorkspaceRoot"
Write-Host "  MTL install:        $MtlInstallPrefix"
Write-Host "  Build type:         $BuildType"

if ($ValidateOnly) {
  Write-Step "Validation complete"
  Write-Host 'Validated prerequisites only; no build was performed.'
  exit 0
}

Build-MesonProject -ProjectName 'mtl' `
  -SourceDir $repoRoot `
  -BuildDir $mtlBuildDir `
  -InstallPrefix $MtlInstallPrefix `
  -BuildTypeValue $BuildType `
  -ExtraSetupArgs @("--pkg-config-path=$env:PKG_CONFIG_PATH", "-Ddpdk_root_dir=$DpdkSourceDir")

$mtlPkgConfigDir = Join-Path $MtlInstallPrefix 'lib\pkgconfig'
$mtlPc = Join-Path $mtlPkgConfigDir 'mtl.pc'
Assert-PathExists -PathToCheck $mtlPc -Hint 'MTL install failed to produce mtl.pc. Check Meson output.'
Add-PkgConfigPath -PathsToAdd @($mtlPkgConfigDir)
Invoke-CheckedCommand -CommandName $pkgConfigTool -Arguments @('--exists', 'mtl') -FailureMessage "Unable to resolve mtl via $pkgConfigTool after library install."

Build-MesonProject -ProjectName 'app' `
  -SourceDir (Join-Path $repoRoot 'app') `
  -BuildDir $appBuildDir `
  -InstallPrefix $MtlInstallPrefix `
  -BuildTypeValue $BuildType `
  -ExtraSetupArgs @("--pkg-config-path=$env:PKG_CONFIG_PATH")

Build-MesonProject -ProjectName 'tests' `
  -SourceDir (Join-Path $repoRoot 'tests') `
  -BuildDir $testsBuildDir `
  -InstallPrefix $MtlInstallPrefix `
  -BuildTypeValue $BuildType `
  -ExtraSetupArgs @("--pkg-config-path=$env:PKG_CONFIG_PATH")

Build-MesonProject -ProjectName 'plugins' `
  -SourceDir (Join-Path $repoRoot 'plugins') `
  -BuildDir $pluginsBuildDir `
  -InstallPrefix $MtlInstallPrefix `
  -BuildTypeValue $BuildType `
  -ExtraSetupArgs @("--pkg-config-path=$env:PKG_CONFIG_PATH")

Build-MesonProject -ProjectName 'RxTxApp' `
  -SourceDir (Join-Path $repoRoot 'tests\tools\RxTxApp') `
  -BuildDir $rxTxAppBuildDir `
  -InstallPrefix $MtlInstallPrefix `
  -BuildTypeValue $BuildType `
  -ExtraSetupArgs @("--pkg-config-path=$env:PKG_CONFIG_PATH")

Write-Step "Done"
Write-Host 'Built and installed native Windows MTL components:'
Write-Host '  - mtl (top-level library)'
Write-Host '  - app'
Write-Host '  - tests (build artifacts only; no test execution in this script)'
Write-Host '  - plugins'
Write-Host '  - tests/tools/RxTxApp'
Write-Host ''
Write-Host 'Intentionally skipped on Windows:'
Write-Host '  - ld_preload'
Write-Host '  - manager'
Write-Host ''
Write-Host "Install prefix: $MtlInstallPrefix"
