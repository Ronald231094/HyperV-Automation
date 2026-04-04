#Requires -RunAsAdministrator
# â”€â”€â”€ Transcript Safety â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
$transcriptActive = $false
try { $transcriptActive = $null -ne (Get-Transcript -ErrorAction SilentlyContinue) } catch { }
if (-not $transcriptActive) {
    $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $logsDir   = Join-Path $PSScriptRoot "logs"
    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    Start-Transcript -Path (Join-Path $logsDir "cleanup_$timestamp.txt") -Append
}

function Stop-Safe { if (-not $transcriptActive) { try { Stop-Transcript } catch { } } }

# â”€â”€â”€ Fetch registered VM names safely â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
try {
    $vmNames = @(Get-VM -ErrorAction Stop | Select-Object -ExpandProperty Name)
} catch {
    Write-Warning "Failed to query Hyper-V VMs. Aborting to prevent accidental data loss."
    Write-Warning "Error: $_"
    Stop-Safe; exit 1
}

if ($vmNames.Count -eq 0) {
    Write-Warning "No VMs found in Hyper-V. Skipping cleanup to avoid deleting all VM folders."
    Stop-Safe; exit 0
}

# â”€â”€â”€ Check each storage path â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
# Resolve paths relative to the script's own location, not the caller's CWD.
$basePaths = @(
    (Join-Path $PSScriptRoot "hyperv"),
    (Join-Path $PSScriptRoot "VM")
)

foreach ($basePath in $basePaths) {
    Write-Host "`nChecking: $basePath" -ForegroundColor Cyan

    if (-not (Test-Path $basePath)) {
        Write-Host "  -> Path does not exist. Skipping." -ForegroundColor Gray
        continue
    }

    $folders = @(Get-ChildItem -Path $basePath -Directory -ErrorAction SilentlyContinue |
                 Select-Object -ExpandProperty Name)

    if ($folders.Count -eq 0) {
        Write-Host "  -> No subfolders found." -ForegroundColor Gray
        continue
    }

    $orphaned = $folders | Where-Object { $vmNames -notcontains $_ }

    if ($orphaned.Count -eq 0) {
        Write-Host "  -> No orphaned folders found." -ForegroundColor Green
        continue
    }

    foreach ($folder in $orphaned) {
        $fullPath = Join-Path $basePath $folder
        Write-Host "  -> Removing orphaned folder: $fullPath" -ForegroundColor Yellow
        try {
            Remove-Item -Path $fullPath -Recurse -Force -ErrorAction Stop
            Write-Host "     Removed." -ForegroundColor DarkGray
        } catch {
            Write-Warning "  Could not remove '$fullPath': $_ (may be in use)"
        }
    }
}

Write-Host "`nCleanup complete." -ForegroundColor Green
Stop-Safe; exit 0
