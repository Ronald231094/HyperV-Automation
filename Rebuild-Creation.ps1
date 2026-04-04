#Requires -Version 5.1
<#
.SYNOPSIS
    Regenerates Creation.ps1 by embedding the current content of every specified
    file in the workspace - a single-command refresh after any script update.

.DESCRIPTION
    Reads each file listed in -Files (or the built-in default manifest if -Files
    is omitted), embeds their live content as PowerShell here-strings, and writes
    a fresh Creation.ps1 to the same directory as this script.

    Typical workflow:
        1. Edit joindomain.ps1 (or any other suite file).
        2. Run .\Rebuild-Creation.ps1
        3. Distribute the new Creation.ps1.

.PARAMETER Files
    Optional. Comma-separated list of filenames to embed, relative to the script
    directory. Overrides the default manifest entirely.

    Example - embed everything:
        .\Rebuild-Creation.ps1

    Example - embed a custom subset:
        .\Rebuild-Creation.ps1 -Files "deploy.ps1,joindomain.ps1,readme.txt"

    Example - add new files not in the default manifest:
        .\Rebuild-Creation.ps1 -Files "cleanup.ps1,MyNewScript.ps1,Notes.md"

.PARAMETER OutputFile
    Optional. Path for the generated file.
    Defaults to 'Creation.ps1' in the same directory as this script.

.PARAMETER Force
    Optional switch. If Creation.ps1 already exists, overwrite it without
    prompting. Without -Force the script asks for confirmation before overwriting.

.EXAMPLE
    .\Rebuild-Creation.ps1
    # Rebuilds Creation.ps1 using the default file manifest.

.EXAMPLE
    .\Rebuild-Creation.ps1 -Files "deploy.ps1,joindomain.ps1" -Force
    # Rebuilds with only two files, no overwrite prompt.

.EXAMPLE
    .\Rebuild-Creation.ps1 -OutputFile "C:\Dist\Creation.ps1"
    # Writes output to a custom path.

.NOTES
    Version : 3.0
    Build   : 2026.04.02
    Encoding: UTF-8 (no BOM)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$Files,

    [Parameter(Mandatory = $false)]
    [string]$OutputFile,

    [Parameter(Mandatory = $false)]
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }

# --- Default file manifest ----------------------------------------------------
# Edit this list to change what gets embedded when -Files is not specified.
# Order here is the order they appear in Creation.ps1.
$defaultManifest = @(
    'cleanup.ps1'
    'createDC.ps1'
    'deploy.ps1'
    'DHCP.ps1'
    'Domainsetup.ps1'
    'InitPassword.ps1'
    'joindomain.ps1'
    'RDS.ps1'
    'RDVH.ps1'
    'switch.ps1'
    'Guidance.txt'
    'readme.txt'
    'Walkthrough.md'
)

# --- Resolve file list --------------------------------------------------------
if ($Files) {
    $fileList = $Files -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
} else {
    $fileList = $defaultManifest
}

# --- Resolve output path -----------------------------------------------------
if (-not $OutputFile) {
    $OutputFile = Join-Path $scriptDir 'Creation.ps1'
}

# --- Banner -------------------------------------------------------------------
Write-Host ''
Write-Host '=============================================' -ForegroundColor Cyan
Write-Host '  Rebuild-Creation.ps1  -  Creation Builder  ' -ForegroundColor Cyan
Write-Host '=============================================' -ForegroundColor Cyan
Write-Host ''
Write-Host "  Source directory : $scriptDir"
Write-Host "  Output file      : $OutputFile"
Write-Host "  Files to embed   : $($fileList.Count)"
Write-Host ''

# --- Pre-scan: verify all files exist before writing anything -----------------
Write-Host '  Scanning files...' -ForegroundColor Cyan
$missing  = [System.Collections.Generic.List[string]]::new()
$included = [System.Collections.Generic.List[string]]::new()

foreach ($f in $fileList) {
    $fullPath = Join-Path $scriptDir $f

    # Don't embed Creation.ps1 into itself - that would be recursive nonsense.
    if ($f -eq 'Creation.ps1' -or $fullPath -eq $OutputFile) {
        Write-Host "  [SKIP]  $f  (cannot embed Creation.ps1 into itself)" -ForegroundColor Yellow
        continue
    }

    if (Test-Path $fullPath) {
        Write-Host "  [OK]    $f" -ForegroundColor Green
        $included.Add($f)
    } else {
        Write-Host "  [MISS]  $f  (not found - will be skipped)" -ForegroundColor Yellow
        $missing.Add($f)
    }
}

Write-Host ''

if ($included.Count -eq 0) {
    Write-Host '  [FAIL] No files found to embed. Nothing written.' -ForegroundColor Red
    exit 1
}

if ($missing.Count -gt 0) {
    Write-Host "  Warning: $($missing.Count) file(s) not found and will be excluded:" -ForegroundColor Yellow
    $missing | ForEach-Object { Write-Host "           - $_" -ForegroundColor Yellow }
    Write-Host ''
}

# --- Overwrite guard ----------------------------------------------------------
if ((Test-Path $OutputFile) -and -not $Force) {
    Write-Host "  '$([System.IO.Path]::GetFileName($OutputFile))' already exists." -ForegroundColor Yellow
    $confirm = Read-Host '  Overwrite it? (Y/N)'
    if ($confirm -notmatch '^[Yy]$') {
        Write-Host '  Aborted. No files were changed.' -ForegroundColor Yellow
        exit 0
    }
    Write-Host ''
}

# --- Build Creation.ps1 content -----------------------------------------------
Write-Host '  Building Creation.ps1...' -ForegroundColor Cyan

# Resolve the human-readable file list for the .DESCRIPTION block
$fileListForDescription = ($included | ForEach-Object { $_ }) -join ', '
$buildDate  = Get-Date -Format 'yyyy.MM.dd'
$buildStamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

# -- Header --------------------------------------------------------------------
$lines = [System.Text.StringBuilder]::new()

[void]$lines.AppendLine(@"
#Requires -Version 5.1
<#
.SYNOPSIS
    Hyper-V Automation Lab Suite v3.0 "Enterprise-Ready" - Self-Extracting Installer

.DESCRIPTION
    Run this single script to write every file in the Hyper-V Lab Suite into the
    current directory, just like a ``git clone`` / GitHub pull experience.

    Files written:
      $fileListForDescription

.EXAMPLE
    .\Creation.ps1
    # All suite files are extracted to the current folder.

.NOTES
    Version : 3.0
    Build   : $buildDate
    Rebuilt : $buildStamp
    Encoding: UTF-8 (no BOM) - compatible with all PowerShell consoles
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'

`$targetDir = `$PSScriptRoot
if (-not `$targetDir) { `$targetDir = (Get-Location).Path }

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  Hyper-V Lab Suite v3.0 - Self-Extractor  " -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  Target directory: `$targetDir"
Write-Host ""

`$written  = 0
`$skipped  = 0
`$errors   = 0

function Write-SuiteFile {
    param(
        [string]`$FileName,
        [string]`$Content
    )

    `$dest = Join-Path `$targetDir `$FileName
    `$exists = Test-Path `$dest

    try {
        # Write with UTF-8 encoding, no BOM (overwrites if already present)
        [System.IO.File]::WriteAllText(`$dest, `$Content, [System.Text.UTF8Encoding]::new(`$false))
        if (`$exists) {
            Write-Host "  [OVER]  `$FileName  (overwritten)" -ForegroundColor Cyan
            `$script:skipped++
        } else {
            Write-Host "  [NEW]   `$FileName" -ForegroundColor Green
        }
        `$script:written++
    }
    catch {
        Write-Host "  [ERR]   `$FileName  -> `$_" -ForegroundColor Red
        `$script:errors++
    }
}
"@)

# -- One section per file ------------------------------------------------------
foreach ($f in $included) {
    $fullPath = Join-Path $scriptDir $f

    # Read raw bytes and decode as UTF-8 to preserve exact content
    $rawBytes   = [System.IO.File]::ReadAllBytes($fullPath)
    $rawContent = [System.Text.UTF8Encoding]::new($false).GetString($rawBytes)

    # PowerShell here-string @' ... '@ is fully literal EXCEPT that '@ must not
    # appear at the start of a line (that would close the here-string early).
    # Escape any such occurrence by indenting it one space.
    $safeContent = $rawContent -replace "(?m)^'@", " '@"

    [void]$lines.AppendLine(@"

# ---------------------------------------------------------------------------
# FILE: $f
# ---------------------------------------------------------------------------
Write-SuiteFile -FileName '$f' -Content @'
$safeContent
'@
"@)
}

# -- Footer --------------------------------------------------------------------
[void]$lines.AppendLine(@"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "---------------------------------------------" -ForegroundColor Cyan
Write-Host "  Extraction complete" -ForegroundColor Cyan
Write-Host "  Written : `$written" -ForegroundColor Green
if (`$skipped -gt 0) {
    Write-Host "  Overwrote : `$skipped  (files overwritten)" -ForegroundColor Yellow
}
if (`$errors -gt 0) {
    Write-Host "  Errors  : `$errors" -ForegroundColor Red
}
Write-Host "---------------------------------------------" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next step:  Run .\setup.ps1 to begin lab initialization." -ForegroundColor White
Write-Host ""
"@)

# --- Write output -------------------------------------------------------------
$outputContent = $lines.ToString()

try {
    [System.IO.File]::WriteAllText(
        $OutputFile,
        $outputContent,
        [System.Text.UTF8Encoding]::new($false)   # UTF-8 no BOM
    )
} catch {
    Write-Host "  [FAIL] Could not write output file: $_" -ForegroundColor Red
    exit 1
}

$sizeKB = [math]::Round((Get-Item $OutputFile).Length / 1KB, 1)
$lines_n = ($outputContent -split "`n").Count

# --- Summary ------------------------------------------------------------------
Write-Host ''
Write-Host '  Done.' -ForegroundColor Green
Write-Host ''
Write-Host "  Output   : $OutputFile" -ForegroundColor White
Write-Host "  Size     : $sizeKB KB  ($lines_n lines)" -ForegroundColor White
Write-Host "  Embedded : $($included.Count) file(s)" -ForegroundColor White
if ($missing.Count -gt 0) {
    Write-Host "  Skipped  : $($missing.Count) file(s) not found" -ForegroundColor Yellow
}
Write-Host ''
