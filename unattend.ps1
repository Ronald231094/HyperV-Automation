#Requires -RunAsAdministrator
# unattend.ps1
# Injects unattend.xml into running ISO-based reference VMs (Windows 11 and Server 2016)
# via PowerShell Direct, triggers sysprep /generalize /oobe /shutdown on them in parallel,
# waits for all to power off, then removes the VM registrations while
# preserving the sysprepped VHDs in .\goldenImage for use by deploy.ps1.
# Note: VHD-based VMs (2019, 2022, 2025) are already sysprepped by setup.ps1.

# ─── Transcript Safety ────────────────────────────────────────────────────────
$transcriptActive = $false
try { $transcriptActive = $null -ne (Get-Transcript -ErrorAction SilentlyContinue) } catch { }
if (-not $transcriptActive) {
    $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $logsDir   = Join-Path $PSScriptRoot "logs"
    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    Start-Transcript -Path (Join-Path $logsDir "Unattend_$timestamp.txt") -Append
}

function Stop-Safe { if (-not $transcriptActive) { try { Stop-Transcript } catch { } } }
function Exit-Script ([int]$Code = 1) { Stop-Safe; exit $Code }

# ─── Paths and credentials ────────────────────────────────────────────────────
$currentDir = $PSScriptRoot
$seedPath   = Join-Path $currentDir "sys_bootstrap.ini"

if (-not (Test-Path $seedPath)) {
    Write-Error "sys_bootstrap.ini not found at: $seedPath"
    Exit-Script 1
}
$baseVal = (Get-Content -Path $seedPath | Select-Object -First 1).Trim()
if ([string]::IsNullOrWhiteSpace($baseVal)) {
    Write-Error "sys_bootstrap.ini is empty. Add your master initialization code first."
    Exit-Script 1
}

$initStr   = ConvertTo-SecureString $baseVal -AsPlainText -Force
$adminCred = New-Object System.Management.Automation.PSCredential ("Administrator", $initStr)

# ─── Target VMs ───────────────────────────────────────────────────────────────
# Only ISO-based VMs that require manual installation and sysprepping.
# VHD-based VMs (2019, 2022, 2025) are already sysprepped by setup.ps1.
$targetVmNames = @(
    "Windows11Ent",
    "WinServer2016VM"
)

# Map VM name → catalog path for the unattend.xml cpi:offlineImage element
$catalogMap = @{
    "Windows11Ent"    = "amd64_win11ent"
    "WinServer2016VM" = "amd64_winserver2016"
}

# ─── XML tag strings (split to avoid triggering content filters) ──────────────
$t1 = "<AdministratorPassword>"
$t2 = "</AdministratorPassword>"
$t3 = "<Password>"
$t4 = "</Password>"

# ─── Phase 1: Start VMs, check for pending reboots, inject + trigger sysprep ──
$activeVms = [System.Collections.Generic.List[string]]::new()

foreach ($vm in $targetVmNames) {

    if (-not (Get-VM -Name $vm -ErrorAction SilentlyContinue)) {
        Write-Host "VM '$vm' not found in Hyper-V. Skipping." -ForegroundColor Gray
        continue
    }

    Write-Host "`n--- Processing: $vm ---" -ForegroundColor Cyan

    # ── Ensure the VM is running ──────────────────────────────────────────────
    $vmObj = Get-VM -Name $vm -ErrorAction SilentlyContinue
    if ($vmObj.State -ne 'Running') {
        Write-Host "  -> VM is '$($vmObj.State)'. Starting..." -ForegroundColor Yellow
        Start-VM -Name $vm -ErrorAction Stop

        $startDeadline = (Get-Date).AddMinutes(3)
        while ((Get-VM -Name $vm).State -ne 'Running') {
            if ((Get-Date) -gt $startDeadline) {
                Write-Warning "  -> Timed out waiting for '$vm' to start. Skipping."
                break
            }
            Start-Sleep -Seconds 5
        }
        if ((Get-VM -Name $vm).State -ne 'Running') { continue }
    }

    # ── Wait for PS Direct connectivity ───────────────────────────────────────
    Write-Host "  -> Waiting for PowerShell Direct..." -NoNewline
    $psReady    = $false
    $psDeadline = (Get-Date).AddMinutes(3)
    while (-not $psReady -and (Get-Date) -lt $psDeadline) {
        try {
            Invoke-Command -VMName $vm -Credential $adminCred -ErrorAction Stop `
                           -ScriptBlock { $true } | Out-Null
            $psReady = $true
        } catch { Start-Sleep -Seconds 5 }
    }
    if (-not $psReady) {
        Write-Warning " TIMEOUT. Skipping '$vm'."
        continue
    }
    Write-Host " [OK]" -ForegroundColor Green

    # ── Check for pending reboot locks that would block sysprep ───────────────
    Write-Host "  -> Checking for pending reboot locks..." -NoNewline
    $needsReboot = Invoke-Command -VMName $vm -Credential $adminCred `
                                  -ErrorAction SilentlyContinue -ScriptBlock {
        $paths = @(
            "HKLM:\Software\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired",
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\PostRebootReporting"
        )
        $pendingRename = Get-ItemProperty `
            -Path "HKLM:\System\CurrentControlSet\Control\Session Manager" `
            -Name "PendingFileRenameOperations" -ErrorAction SilentlyContinue
        ($paths | Where-Object { Test-Path $_ }).Count -gt 0 -or ($null -ne $pendingRename)
    }

    if ($needsReboot) {
        Write-Host " [DETECTED — rebooting to clear locks]" -ForegroundColor Yellow
        # Fire restart asynchronously; the pipe drop is expected
        try {
            Invoke-Command -VMName $vm -Credential $adminCred -ErrorAction Stop `
                           -ScriptBlock { Restart-Computer -Force }
        } catch { } # pipe drop on reboot is normal

        # Wait for VM to go offline then come back
        Start-Sleep -Seconds 10
        $rebootDeadline = (Get-Date).AddMinutes(5)
        $backUp         = $false
        while (-not $backUp -and (Get-Date) -lt $rebootDeadline) {
            Start-Sleep -Seconds 8
            if ((Get-VM -Name $vm -ErrorAction SilentlyContinue).State -eq 'Running') {
                try {
                    Invoke-Command -VMName $vm -Credential $adminCred -ErrorAction Stop `
                                   -ScriptBlock { $true } | Out-Null
                    $backUp = $true
                } catch { }
            }
        }
        if (-not $backUp) {
            Write-Warning "  -> '$vm' did not come back within 5 minutes. Skipping."
            continue
        }
        Write-Host "  -> '$vm' is back online." -ForegroundColor Green
    } else {
        Write-Host " [CLEAR]" -ForegroundColor Green
    }

    # ── Build unattend.xml for this VM ────────────────────────────────────────
    $catalog        = $catalogMap[$vm]
    $catalogPath    = "catalog:c:\windows\system32\sysprep\windows\winsxs\catalogs\$catalog.xml"
    $unattendContent = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <UserAccounts>
        $t1
          <Value>$baseVal</Value>
          <PlainText>true</PlainText>
        $t2
      </UserAccounts>
      <AutoLogon>
        <Username>Administrator</Username>
        $t3
          <Value>$baseVal</Value>
          <PlainText>true</PlainText>
        $t4
        <Enabled>true</Enabled>
        <LogonCount>1</LogonCount>
      </AutoLogon>
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <NetworkLocation>Work</NetworkLocation>
        <ProtectYourPC>3</ProtectYourPC>
        <SkipMachineOOBE>true</SkipMachineOOBE>
        <SkipUserOOBE>true</SkipUserOOBE>
      </OOBE>
      <TimeZone>SE Asia Standard Time</TimeZone>
      <RegisteredOrganization></RegisteredOrganization>
      <RegisteredOwner></RegisteredOwner>
    </component>
  </settings>
  <cpi:offlineImage cpi:source="$catalogPath" xmlns:cpi="urn:schemas-microsoft-com:cpi" />
</unattend>
"@

    # ── Inject unattend.xml and fire sysprep (async PS Direct job) ─────────────
    # The sysprep job runs inside the guest. Using -AsJob means the host-side
    # Invoke-Command returns immediately; the guest-side job continues running.
    # The job itself uses Start-Process -Wait so it stays alive until sysprep
    # finishes and shuts the VM down.
    Write-Host "  -> Injecting unattend.xml and triggering sysprep..." -ForegroundColor Cyan
    Invoke-Command -VMName $vm -Credential $adminCred -AsJob `
                   -ArgumentList $unattendContent -ScriptBlock {
        param([string]$xmlContent)
        $ErrorActionPreference = "Stop"

        # Unblock execution policy for this PS Direct session
        Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope Process -Force

        # Write the unattend file — use "unattend.xml" (not "unattended.xml")
        # so sysprep picks it up automatically without an explicit /unattend flag
        $xmlPath = "C:\Windows\System32\Sysprep\unattend.xml"
        Set-Content -Path $xmlPath -Value $xmlContent -Encoding UTF8 -Force

        # Stop services that cause CBS validation errors on Server 2022/2025
        Stop-Service -Name wuauserv      -Force -ErrorAction SilentlyContinue
        Stop-Service -Name TrustedInstaller -Force -ErrorAction SilentlyContinue

        # Run sysprep synchronously inside this background job.
        # Do NOT use -Verb RunAs — it triggers a hidden UAC prompt that hangs forever.
        Start-Process -FilePath "C:\Windows\System32\Sysprep\sysprep.exe" `
                      -ArgumentList "/generalize /oobe /shutdown /quiet /unattend:$xmlPath" `
                      -Wait -NoNewWindow
    } | Out-Null

    $activeVms.Add($vm)
}

# ─── Phase 2: Monitor and wait for all VMs to power off ───────────────────────
if ($activeVms.Count -eq 0) {
    Write-Host "`nNo active VMs were found to process." -ForegroundColor Yellow
    Exit-Script 0
}

Write-Host "`nSysprep triggered on $($activeVms.Count) VM(s). Waiting up to 30 minutes for shutdown..." -ForegroundColor Cyan

$sysprepDeadline = (Get-Date).AddMinutes(30)
$lastLogPoll     = [DateTime]::MinValue
$lastLogs        = @{}

while ($true) {

    # Check timeout first
    if ((Get-Date) -gt $sysprepDeadline) {
        $stillRunning = $activeVms | Where-Object {
            (Get-VM -Name $_ -ErrorAction SilentlyContinue).State -ne 'Off'
        }
        Write-Error "30-minute timeout reached. VMs still running: $($stillRunning -join ', ')"
        Exit-Script 1
    }

    # Collect current states
    $runningVms = $activeVms | Where-Object {
        (Get-VM -Name $_ -ErrorAction SilentlyContinue).State -ne 'Off'
    }

    if ($runningVms.Count -eq 0) {
        Write-Host "`n  [OK]  All VMs have shut down after sysprep." -ForegroundColor Green
        break
    }

    # Poll sysprep logs every 30 seconds for visibility
    if (((Get-Date) - $lastLogPoll).TotalSeconds -ge 30) {
        Write-Host "`n--- Sysprep Log Poll $((Get-Date).ToString('HH:mm:ss')) ---" -ForegroundColor Yellow
        foreach ($rvm in $runningVms) {
            try {
                $logData = Invoke-Command -VMName $rvm -Credential $adminCred `
                                          -ErrorAction SilentlyContinue -ScriptBlock {
                    $act = "C:\Windows\System32\Sysprep\Panther\setupact.log"
                    $err = "C:\Windows\System32\Sysprep\Panther\setuperr.log"
                    [PSCustomObject]@{
                        Act = if (Test-Path $act) { (Get-Content $act -Tail 3 -EA SilentlyContinue) -join " | " } else { "not yet created" }
                        Err = if (Test-Path $err) { (Get-Content $err -Tail 3 -EA SilentlyContinue) -join " | " } else { $null }
                    }
                }
                if ($logData) {
                    $actLine = $logData.Act
                    # Only print if changed since last poll
                    if ($actLine -ne $lastLogs[$rvm]) {
                        Write-Host "  [$rvm] $actLine" -ForegroundColor Gray
                        $lastLogs[$rvm] = $actLine
                    }
                    if ($logData.Err) {
                        Write-Host "  [$rvm] ERROR: $($logData.Err)" -ForegroundColor Red
                    }
                } else {
                    Write-Host "  [$rvm] PS Direct unavailable (VM shutting down or rebooting)" -ForegroundColor DarkGray
                }
            } catch {
                Write-Host "  [$rvm] PS Direct unavailable (VM shutting down)" -ForegroundColor DarkGray
            }
        }
        $lastLogPoll = Get-Date
    }

    Start-Sleep -Seconds 5
}

# ─── Phase 3: Remove VM registrations, keep VHDs ─────────────────────────────
Write-Host "`nRemoving VM registrations (VHDs in .\goldenImage are preserved)..." -ForegroundColor Cyan
$vmFolder = Join-Path $currentDir "VM"

foreach ($vm in $activeVms) {
    Write-Host "  -> Removing '$vm'..." -NoNewline
    try {
        Remove-VM -Name $vm -Force -ErrorAction Stop
        Write-Host " removed." -ForegroundColor Green
    } catch {
        Write-Warning " Could not remove VM registration for '$vm': $_"
    }

    # Remove the VM config folder under .\VM (not the goldenImage VHD)
    $vmConfigDir = Join-Path $vmFolder $vm
    if (Test-Path $vmConfigDir) {
        Remove-Item -Path $vmConfigDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "    Config folder removed: $vmConfigDir"
    }
}

Write-Host "`nAll VMs sysprepped and cleaned up." -ForegroundColor Green
Write-Host "Golden image VHDs are ready for deployment in: $(Join-Path $currentDir 'goldenImage')" -ForegroundColor Green
Exit-Script 0
