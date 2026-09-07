<#
.SYNOPSIS
Builds and installs MTL-patched DPDK in a native MSVC environment.

.DESCRIPTION
This script is a standalone Windows-native DPDK build flow for MTL.
Run it from a Developer PowerShell or Developer Command Prompt where
cl.exe, link.exe, and lib.exe are available.

It reads DPDK_VER and DPDK_MTL_MINOR_VER from versions.env by default,
clones a clean DPDK source tree, applies MTL generic and Windows patches
in documented order, then configures/builds/installs with Meson + Ninja.

.PARAMETER Force
Recreate script-owned source/build/patch-stage directories.
Only directories under WorkspaceRoot are deleted.

.PARAMETER WorkspaceRoot
Script-owned workspace root (default: <repo>\build\windows-dpdk).

.PARAMETER InstallPrefix
DPDK installation prefix (default: <WorkspaceRoot>\install).

.PARAMETER DpdkVersion
DPDK version to build (default: DPDK_VER from versions.env).

.PARAMETER DpdkMtlMinorVersion
MTL DPDK patch minor version (default: DPDK_MTL_MINOR_VER from versions.env).

.EXAMPLE
.\script\build_dpdk_windows.ps1

.EXAMPLE
.\script\build_dpdk_windows.ps1 -Force
#>
[CmdletBinding()]
param(
  [switch]$Force,
  [string]$WorkspaceRoot,
  [string]$InstallPrefix,
  [string]$DpdkVersion,
  [string]$DpdkMtlMinorVersion
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

function Ensure-Directory {
  param([string]$PathToCreate)
  if (-not (Test-Path -LiteralPath $PathToCreate)) {
    New-Item -ItemType Directory -Path $PathToCreate | Out-Null
  }
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

function Resolve-PatchContent {
  param(
    [string]$PatchFile,
    [System.Collections.Generic.HashSet[string]]$Seen
  )

  $patchFullPath = (Resolve-Path -LiteralPath $PatchFile).Path
  if ($Seen.Contains($patchFullPath)) {
    throw "Patch reference cycle detected at: $patchFullPath"
  }
  $null = $Seen.Add($patchFullPath)

  $firstLine = (Get-Content -LiteralPath $patchFullPath -TotalCount 1)
  if ($firstLine -is [array]) {
    $firstLine = $firstLine[0]
  }
  if ($null -ne $firstLine -and $firstLine.Trim() -match '^\.\./.+\.patch$') {
    $targetPatch = Join-Path (Split-Path -Parent $patchFullPath) $firstLine.Trim()
    if (-not (Test-Path -LiteralPath $targetPatch)) {
      throw "Referenced patch does not exist: $targetPatch"
    }
    return Resolve-PatchContent -PatchFile $targetPatch -Seen $Seen
  }

  return Get-Content -LiteralPath $patchFullPath -Raw
}

function Stage-PatchFile {
  param([string]$InputPatch, [string]$OutputPatch)

  Ensure-Directory -PathToCreate (Split-Path -Parent $OutputPatch)
  $resolved = Resolve-PatchContent -PatchFile $InputPatch -Seen ([System.Collections.Generic.HashSet[string]]::new())
  Set-Content -LiteralPath $OutputPatch -Value $resolved
}

if (-not $IsWindows) {
  throw "This script is Windows-only. Use native PowerShell on Windows."
}

$repoRoot = Get-RepoRoot
$versions = Parse-VersionsEnv -FilePath (Join-Path $repoRoot 'versions.env')

if (-not $DpdkVersion) {
  if (-not $versions.ContainsKey('DPDK_VER')) {
    throw "DPDK_VER not found in versions.env"
  }
  $DpdkVersion = $versions['DPDK_VER']
}
if (-not $DpdkMtlMinorVersion) {
  if (-not $versions.ContainsKey('DPDK_MTL_MINOR_VER')) {
    throw "DPDK_MTL_MINOR_VER not found in versions.env"
  }
  $DpdkMtlMinorVersion = $versions['DPDK_MTL_MINOR_VER']
}

if (-not $WorkspaceRoot) {
  $WorkspaceRoot = Join-Path $repoRoot 'build\windows-dpdk'
}
if (-not $InstallPrefix) {
  $InstallPrefix = Join-Path $WorkspaceRoot 'install'
}

$WorkspaceRoot = [System.IO.Path]::GetFullPath($WorkspaceRoot)
$InstallPrefix = [System.IO.Path]::GetFullPath($InstallPrefix)
$sourceRoot = Join-Path $WorkspaceRoot 'src'
$sourceDir = Join-Path $sourceRoot "dpdk-$DpdkVersion"
$buildDir = Join-Path $WorkspaceRoot 'build'
$patchStageDir = Join-Path $WorkspaceRoot 'patches-staged'
$patchStamp = Join-Path $WorkspaceRoot ".patches_applied_${DpdkVersion}_${DpdkMtlMinorVersion}.stamp"

Write-Step "Checking prerequisites"
Assert-Tool -CommandName 'git' -Hint 'Install Git for Windows and ensure git.exe is in PATH.'
Assert-Tool -CommandName 'meson' -Hint 'Install Meson (for example: py -m pip install meson).'
Assert-Tool -CommandName 'ninja' -Hint 'Install Ninja and ensure ninja.exe is in PATH.'
Assert-Tool -CommandName 'cl.exe' -Hint 'Run from a Visual Studio Developer shell.'
Assert-Tool -CommandName 'link.exe' -Hint 'Run from a Visual Studio Developer shell.'
Assert-Tool -CommandName 'lib.exe' -Hint 'Run from a Visual Studio Developer shell.'
if (-not $env:VSCMD_VER -and -not $env:VisualStudioVersion) {
  Write-Info 'Visual Studio environment marker variables are not set. Continuing because MSVC tools are present.'
}

Write-Step "Preparing workspace"
Ensure-Directory -PathToCreate $WorkspaceRoot
if ($Force) {
  Remove-SafeDirectory -RootPath $WorkspaceRoot -TargetPath $sourceDir
  Remove-SafeDirectory -RootPath $WorkspaceRoot -TargetPath $buildDir
  Remove-SafeDirectory -RootPath $WorkspaceRoot -TargetPath $patchStageDir
  if (Test-Path -LiteralPath $InstallPrefix) {
    if ($InstallPrefix.StartsWith($WorkspaceRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
      Remove-SafeDirectory -RootPath $WorkspaceRoot -TargetPath $InstallPrefix
    } else {
      Write-Info "Not removing custom InstallPrefix outside WorkspaceRoot: $InstallPrefix"
    }
  }
  if (Test-Path -LiteralPath $patchStamp) {
    Remove-Item -LiteralPath $patchStamp -Force
  }
}

Write-Step "Preparing DPDK source tree"
$sourceCreated = $false
if (-not (Test-Path -LiteralPath $sourceDir)) {
  Ensure-Directory -PathToCreate $sourceRoot
  & git clone --branch "v$DpdkVersion" --depth 1 https://github.com/DPDK/dpdk.git $sourceDir
  $sourceCreated = $true
} else {
  Write-Info "Using existing source tree: $sourceDir"
}

if (-not (Test-Path -LiteralPath (Join-Path $sourceDir '.git'))) {
  throw "DPDK source directory is not a Git checkout: $sourceDir. Re-run with -Force."
}

$genericPatchRoot = Join-Path $repoRoot "patches\dpdk\$DpdkVersion"
$windowsPatchRoot = Join-Path $genericPatchRoot 'windows'
if (-not (Test-Path -LiteralPath $genericPatchRoot)) {
  throw "Patch directory not found: $genericPatchRoot"
}
if (-not (Test-Path -LiteralPath $windowsPatchRoot)) {
  throw "Windows patch directory not found: $windowsPatchRoot"
}

$genericPatchFiles = Get-ChildItem -LiteralPath $genericPatchRoot -File -Filter '*.patch' | Sort-Object Name
$windowsPatchFiles = Get-ChildItem -LiteralPath $windowsPatchRoot -File -Filter '*.patch' | Sort-Object Name
if ($genericPatchFiles.Count -eq 0) {
  throw "No generic DPDK patches found in: $genericPatchRoot"
}
if ($windowsPatchFiles.Count -eq 0) {
  throw "No Windows DPDK patches found in: $windowsPatchRoot"
}

if ($sourceCreated -and (Test-Path -LiteralPath $patchStamp)) {
  Remove-Item -LiteralPath $patchStamp -Force
}

if (-not (Test-Path -LiteralPath $patchStamp)) {
  Write-Step "Staging patches for robust Windows checkout handling"
  Remove-SafeDirectory -RootPath $WorkspaceRoot -TargetPath $patchStageDir
  $stagedGenericDir = Join-Path $patchStageDir 'generic'
  $stagedWindowsDir = Join-Path $patchStageDir 'windows'
  Ensure-Directory -PathToCreate $stagedGenericDir
  Ensure-Directory -PathToCreate $stagedWindowsDir

  foreach ($patchFile in $genericPatchFiles) {
    $outPatch = Join-Path $stagedGenericDir $patchFile.Name
    Stage-PatchFile -InputPatch $patchFile.FullName -OutputPatch $outPatch
  }
  foreach ($patchFile in $windowsPatchFiles) {
    $outPatch = Join-Path $stagedWindowsDir $patchFile.Name
    Stage-PatchFile -InputPatch $patchFile.FullName -OutputPatch $outPatch
  }

  Write-Step "Applying generic MTL patches with git am"
  foreach ($patchFile in (Get-ChildItem -LiteralPath $stagedGenericDir -File -Filter '*.patch' | Sort-Object Name)) {
    Write-Info "git am $($patchFile.Name)"
    & git -C $sourceDir am --keep-non-patch --whitespace=nowarn $patchFile.FullName
  }

  Write-Step "Applying Windows MTL patches with git apply"
  foreach ($patchFile in (Get-ChildItem -LiteralPath $stagedWindowsDir -File -Filter '*.patch' | Sort-Object Name)) {
    Write-Info "git apply $($patchFile.Name)"
    & git -C $sourceDir apply --whitespace=nowarn $patchFile.FullName
  }

  Set-Content -LiteralPath $patchStamp -Value "dpdk=$DpdkVersion mtl_minor=$DpdkMtlMinorVersion"
} else {
  Write-Info "Patch stamp found. Skipping patch application: $patchStamp"
}

Write-Step "Configuring DPDK build (MSVC)"
Ensure-Directory -PathToCreate $WorkspaceRoot
$mesonArgs = @(
  'setup'
  $buildDir
  $sourceDir
  "--prefix=$InstallPrefix"
  '-Dmax_lcores=256'
  '-Ddefault_library=both'
)
if (Test-Path -LiteralPath $buildDir) {
  $mesonArgs += '--reconfigure'
}
& meson @mesonArgs

Write-Step "Compiling and installing DPDK"
& meson compile -C $buildDir
& meson install -C $buildDir

Write-Step "Validating install layout"
$includeDir = Join-Path $InstallPrefix 'include'
$libDir = Join-Path $InstallPrefix 'lib'
$pkgConfigFile = Join-Path $libDir 'pkgconfig\libdpdk.pc'
if (-not (Test-Path -LiteralPath $includeDir)) {
  throw "Missing include directory in install prefix: $includeDir"
}
if (-not (Test-Path -LiteralPath $pkgConfigFile)) {
  throw "Missing libdpdk.pc: $pkgConfigFile"
}
$rteConfigHeader = Get-ChildItem -LiteralPath $includeDir -Recurse -File -Filter 'rte_config.h' | Select-Object -First 1
if (-not $rteConfigHeader) {
  throw "Missing generated rte_config.h under: $includeDir"
}
$staticArtifacts = @(Get-ChildItem -LiteralPath $InstallPrefix -Recurse -File | Where-Object {
    $_.Name -like '*rte_eal*.a' -or $_.Name -like '*rte_eal*.lib'
  })
if ($staticArtifacts.Count -eq 0) {
  throw "No static DPDK artifacts detected (expected *rte_eal*.a or *rte_eal*.lib)."
}
$sharedArtifacts = @(Get-ChildItem -LiteralPath $InstallPrefix -Recurse -File | Where-Object {
    $_.Name -like '*rte_eal*.dll'
  })
if ($sharedArtifacts.Count -eq 0) {
  Write-Info 'No rte_eal DLL was found in install prefix; static artifacts and libdpdk.pc are present for MTL static dependency.'
}

Write-Step "Done"
Write-Host "DPDK $DpdkVersion (MTL patch minor $DpdkMtlMinorVersion) was built and installed to:"
Write-Host "  $InstallPrefix"
Write-Host ''
Write-Host 'For future native MTL Meson setup, point pkg-config to this installation:'
Write-Host "  `$env:PKG_CONFIG_PATH = '$libDir\pkgconfig'"
Write-Host ''
Write-Host "This script only prepares DPDK. It does not build MTL."
