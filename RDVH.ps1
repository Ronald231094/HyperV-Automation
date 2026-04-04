#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Automated deployment of an RDS Virtual Desktop Infrastructure (VDI) farm.
.DESCRIPTION
    Chains DC creation, VM deployment, domain join, nested-virtualisation setup,
    Hyper-V role install inside RDVH guests, and RDS VDI role configuration.

    Parallel deployment uses Start-Job (not Start-Process) so that child
    jobs inherit the elevated token of the parent session â€” fixing the
    -196608 / #Requires -RunAsAdministrator failure that occurs when
    Start-Process spawns new windows without -Verb RunAs.
#>

param(
    [string]   $DCName         = $null,
    [string]   $DomainName     = $null,
    [string]   $DCOS           = $null,
    [string[]] $VMNames        = $null,
    [string]   $MemberOS       = $null,
    [string]   $CBName         = $null,
    [string[]] $VHNames        = $null,
    [string]   $WAName         = $null,
    [string[]] $LicNames       = $null,
    [string[]] $GWNames        = $null,
    [string]   $DomainAdmin    = "Administrator",
    [string]   $DomainInitCode = ""
)

# â”€â”€â”€ Transcript â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
$transcriptActive = $false
try { $transcriptActive = $null -ne (Get-Transcript -ErrorAction SilentlyContinue) } catch { }
if (-not $transcriptActive) {
    $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $logsDir   = Join-Path $PSScriptRoot "logs"
    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    Start-Transcript -Path (Join-Path $logsDir "RDS_VDI_$timestamp.txt") -Append
}

function Stop-Safe { if (-not $transcriptActive) { try { Stop-Transcript } catch { } } }
function Exit-Script ([int]$Code = 1) {
    Write-ReplayCommand
    Stop-Safe
    exit $Code
}

function Write-ReplayCommand {
    Write-Host "`n" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "  REPLAY COMMAND (copy-paste to rerun)"   -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan

    $vmNamesStr  = $VMNames  -join ','
    $vhNamesStr  = $VHNames  -join ','
    $licNamesStr = $LicNames -join ','
    $gwNamesStr  = $GWNames  -join ','

    $cmd  = "& '$($MyInvocation.ScriptName)'"
    $cmd += " -DCName '$DCName'"
    $cmd += " -DomainName '$DomainName'"
    $cmd += " -DCOS '$DCOS'"
    $cmd += " -VMNames '$vmNamesStr'"
    $cmd += " -MemberOS '$MemberOS'"
    $cmd += " -CBName '$CBName'"
    $cmd += " -VHNames '$vhNamesStr'"
    $cmd += " -WAName '$WAName'"
    $cmd += " -LicNames '$licNamesStr'"
    $cmd += " -GWNames '$gwNamesStr'"

    Write-Host $cmd -ForegroundColor Yellow
    Write-Host "`n" -ForegroundColor Cyan
}

$currentDir = $PSScriptRoot

# â”€â”€â”€ Prompt for missing parameters â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
if (-not $DCName)     { $DCName     = Read-Host "Enter Domain Controller VM Name" }
if (-not $DomainName) { $DomainName = Read-Host "Enter Domain Name (e.g., corp.local)" }
if (-not $DCOS)       { $DCOS       = Read-Host "Enter OS for Domain Controller" }

if ($null -eq $VMNames) {
    $VMNames = @((Read-Host "Enter all domain member VM names (comma-separated)") -split ',' |
                 ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
} else {
    $VMNames = @($VMNames -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}
if (-not $MemberOS) { $MemberOS = Read-Host "Enter OS for all member VMs" }

if (-not $CBName) { $CBName = Read-Host "Enter Connection Broker VM Name" }
if (-not ($VMNames -contains $CBName)) {
    Write-Host "Error: Connection Broker '$CBName' is not in the member VM list." -ForegroundColor Red
    Exit-Script 1
}

if ($null -eq $VHNames) {
    $VHNames = @((Read-Host "Enter RD Virtualization Host VM Names (comma-separated)") -split ',' |
                 ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
} else {
    $VHNames = @($VHNames -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}
foreach ($vh in $VHNames) {
    if (-not ($VMNames -contains $vh)) {
        Write-Host "Error: Virtualization Host '$vh' is not in the member VM list." -ForegroundColor Red
        Exit-Script 1
    }
}

if (-not $WAName) { $WAName = Read-Host "Enter RD Web Access VM Name" }
if (-not ($VMNames -contains $WAName)) {
    Write-Host "Error: Web Access VM '$WAName' is not in the member VM list." -ForegroundColor Red
    Exit-Script 1
}

if ($null -eq $LicNames) {
    $LicNames = @((Read-Host "Enter RD Licensing VM Names (comma-separated)") -split ',' |
                  ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
} else {
    $LicNames = @($LicNames -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}
foreach ($lic in $LicNames) {
    if (-not ($VMNames -contains $lic)) {
        Write-Host "Error: Licensing VM '$lic' is not in the member VM list." -ForegroundColor Red
        Exit-Script 1
    }
}

if ($null -eq $GWNames) {
    $GWNames = @((Read-Host "Enter RD Gateway VM Names (comma-separated)") -split ',' |
                 ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
} else {
    $GWNames = @($GWNames -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}
foreach ($gw in $GWNames) {
    if (-not ($VMNames -contains $gw)) {
        Write-Host "Error: Gateway VM '$gw' is not in the member VM list." -ForegroundColor Red
        Exit-Script 1
    }
}

# â”€â”€â”€ Credentials â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
$seedPath = Join-Path $currentDir "sys_bootstrap.ini"
if ([string]::IsNullOrWhiteSpace($DomainInitCode)) {
    if (-not (Test-Path $seedPath)) { Write-Error "sys_bootstrap.ini not found."; Exit-Script 1 }
    $DomainInitCode = (Get-Content -Path $seedPath | Select-Object -First 1).Trim()
    if ([string]::IsNullOrWhiteSpace($DomainInitCode)) {
        Write-Error "sys_bootstrap.ini is empty."
        Exit-Script 1
    }
}
$secureCode      = ConvertTo-SecureString $DomainInitCode -AsPlainText -Force
$domainAdminCred = New-Object System.Management.Automation.PSCredential ("$DomainName\$DomainAdmin", $secureCode)

# â”€â”€â”€ Step 1 & 2: Parallel DC and Member VM Deployment via Start-Job â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
# FIX: Start-Job inherits the parent's elevated token, so #Requires -RunAsAdministrator
# in the child scripts is satisfied without needing -Verb RunAs or UAC prompts.
# Start-Process without -Verb RunAs spawns a non-elevated child (exit code -196608).
Write-Host "`n=== Starting Parallel VM Deployment ===" -ForegroundColor Cyan
Write-Host "  [1] Domain Controller: $DCName (OS: $DCOS)" -ForegroundColor Yellow
Write-Host "  [2] Member VMs: $($VMNames -join ', ') (OS: $MemberOS)" -ForegroundColor Yellow

$dcScriptPath     = Join-Path $currentDir "createDC.ps1"
$deployScriptPath = Join-Path $currentDir "deploy.ps1"
$VMListString     = $VMNames -join ','

if (-not (Test-Path $dcScriptPath)) {
    Write-Error "Child script not found: $dcScriptPath"
    Exit-Script 1
}
if (-not (Test-Path $deployScriptPath)) {
    Write-Error "Child script not found: $deployScriptPath"
    Exit-Script 1
}

Write-Host "`nLaunching parallel deployment jobs..." -ForegroundColor Cyan
Write-Host "  -> Starting DC deployment job..." -ForegroundColor Gray
Write-Host "  -> Starting member VM deployment job..." -ForegroundColor Gray

# DC job â€” dot-sources createDC.ps1 inside the job runspace
$dcJob = Start-Job -Name "DCDeploy" -ScriptBlock {
    param($script, $os, $vmName, $domainName)
    & $script -OS $os -VMName $vmName -DomainName $domainName
    # Return the exit code as the last output value so the parent can inspect it
    $LASTEXITCODE
} -ArgumentList $dcScriptPath, $DCOS, $DCName, $DomainName

# Member VM job â€” dot-sources deploy.ps1 inside the job runspace
$deployJob = Start-Job -Name "MemberDeploy" -ScriptBlock {
    param($script, $vmList, $os)
    & $script -VMName $vmList -OS $os
    $LASTEXITCODE
} -ArgumentList $deployScriptPath, $VMListString, $MemberOS

# â”€â”€â”€ Stream job output live to the transcript â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
Write-Host "`nWaiting for deployment jobs to complete (streaming output below)..." -ForegroundColor Cyan

$pollInterval = 5   # seconds between output polls
while ($true) {
    # Flush any pending output from both jobs
    $dcJob     | Receive-Job | ForEach-Object { Write-Host "  [DC]     $_" }
    $deployJob | Receive-Job | ForEach-Object { Write-Host "  [MEMBER] $_" }

    $dcDone     = $dcJob.State     -in @('Completed','Failed','Stopped')
    $deployDone = $deployJob.State -in @('Completed','Failed','Stopped')

    if ($dcDone -and $deployDone) { break }

    Start-Sleep -Seconds $pollInterval
}

# Final flush after both jobs finish
$dcJob     | Receive-Job | ForEach-Object { Write-Host "  [DC]     $_" }
$deployJob | Receive-Job | ForEach-Object { Write-Host "  [MEMBER] $_" }

# â”€â”€â”€ Collect results â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
# The last value emitted by each job scriptblock is $LASTEXITCODE from the child script.
# Receive-Job was already flushed above, so inspect child info directly.
$dcJobInfo     = Get-Job -Name "DCDeploy"
$deployJobInfo = Get-Job -Name "MemberDeploy"

# A job that throws an unhandled terminating error lands in Failed state.
# Treat anything other than Completed as a failure.
$dcSuccess     = ($dcJobInfo.State     -eq 'Completed') -and ($dcJobInfo.ChildJobs[0].Error.Count -eq 0)
$deploySuccess = ($deployJobInfo.State -eq 'Completed') -and ($deployJobInfo.ChildJobs[0].Error.Count -eq 0)

Write-Host "`n=== Deployment Results ===" -ForegroundColor Cyan
if ($dcSuccess) {
    Write-Host "  [OK]   Domain Controller deployment completed" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] Domain Controller deployment failed (job state: $($dcJobInfo.State))" -ForegroundColor Red
    # Surface any terminating errors from the job
    $dcJobInfo.ChildJobs[0].Error | ForEach-Object { Write-Host "         Error: $_" -ForegroundColor Red }
}

if ($deploySuccess) {
    Write-Host "  [OK]   Member VM deployment completed" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] Member VM deployment failed (job state: $($deployJobInfo.State))" -ForegroundColor Red
    $deployJobInfo.ChildJobs[0].Error | ForEach-Object { Write-Host "         Error: $_" -ForegroundColor Red }
}

# Clean up job objects
Remove-Job -Name "DCDeploy","MemberDeploy" -Force -ErrorAction SilentlyContinue

if (-not $dcSuccess -or -not $deploySuccess) {
    Write-Error "One or more deployment jobs failed. Review the output above."
    Exit-Script 1
}

Write-Host "`nAll VMs deployed successfully via parallel jobs." -ForegroundColor Green

# â”€â”€â”€ Verify all VMs are reachable before domain join â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
Write-Host "`n=== Verifying VM Readiness ===" -ForegroundColor Cyan
$allVMs              = @($DCName) + $VMNames
$verificationTimeout = 300   # 5 minutes total
$verificationInterval = 10   # check every 10 seconds
$elapsed             = 0
$allReady            = $false

while (-not $allReady -and $elapsed -lt $verificationTimeout) {
    $allReady    = $true
    $readyCount  = 0

    foreach ($vmName in $allVMs) {
        try {
            $testResult = Invoke-Command -VMName $vmName -Credential $domainAdminCred `
                -ErrorAction Stop -ScriptBlock { "OK" }

            if ($testResult -eq "OK") {
                Write-Host "  [OK] $vmName - Ready" -ForegroundColor Green
                $readyCount++
            }
        } catch {
            $progressMsg = "${elapsed}/${verificationTimeout} seconds"
            Write-Host "  [X] $vmName - Not reachable yet ($progressMsg)" -ForegroundColor Yellow
            $allReady = $false
        }
    }

    if (-not $allReady) {
        $retryMsg = "Retrying in ${verificationInterval} s"
        Write-Host "  Progress: $readyCount/$($allVMs.Count) VMs ready. $retryMsg" -ForegroundColor Gray
        Start-Sleep -Seconds $verificationInterval
        $elapsed += $verificationInterval
    }
}

if ($allReady) {
    Write-Host "`n[OK] All $($allVMs.Count) VMs are ready for domain join." -ForegroundColor Green
} else {
    $timeoutMsg = "${verificationTimeout}s"
    Write-Error "VM verification timed out after $timeoutMsg. Some VMs may not be ready."
    Exit-Script 1
}

# â”€â”€â”€ Step 3: Domain Join â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
$allToJoin = ($VMNames + @($CBName) | Select-Object -Unique) -join ','
Write-Host "`nJoining all VMs to domain '$DomainName'..." -ForegroundColor Cyan
& (Join-Path $currentDir "joindomain.ps1") `
    -DcVmName $DCName -DomainToJoin $DomainName -VmNames $allToJoin
if ($LASTEXITCODE -ne 0) { Write-Error "joindomain.ps1 failed."; Exit-Script 1 }

# Allow AD services to stabilise before proceeding with nested-virt setup
Write-Host "`nWaiting 60 s for domain services to stabilise on all VMs..." -ForegroundColor Cyan
Start-Sleep -Seconds 60

# â”€â”€â”€ Step 4: Enable Nested Virtualisation on RDVH VMs (host-side) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
Write-Host "`n[Pre-RDS] Enabling nested virtualisation on RDVH VMs..." -ForegroundColor Cyan
foreach ($vh in $VHNames) {
    Write-Host "  -> Processing: '$vh'..." -ForegroundColor Cyan
    try {
        $vmObj     = Get-VM -Name $vh -ErrorAction Stop
        $wasRunning = $vmObj.State -eq 'Running'

        if ($wasRunning) {
            Write-Host "     Stopping '$vh' to apply processor setting..."
            Stop-VM -Name $vh -Force -ErrorAction Stop
            $stopTimeout = (Get-Date).AddMinutes(2)
            while ((Get-VM -Name $vh).State -ne 'Off') {
                if ((Get-Date) -gt $stopTimeout) { throw "Timed out waiting for '$vh' to stop." }
                Start-Sleep -Seconds 3
            }
        }

        Set-VMProcessor -VMName $vh -ExposeVirtualizationExtensions $true -ErrorAction Stop
        Write-Host "     Nested virtualisation enabled." -ForegroundColor Green

        if ($wasRunning) {
            Start-VM -Name $vh -ErrorAction Stop
            $startTimeout = (Get-Date).AddMinutes(2)
            while ((Get-VM -Name $vh).State -ne 'Running') {
                if ((Get-Date) -gt $startTimeout) { throw "Timed out waiting for '$vh' to start." }
                Start-Sleep -Seconds 3
            }
            Write-Host "     '$vh' is running again." -ForegroundColor Green
        }
    } catch {
        Write-Error "Failed to enable nested virtualisation on '$vh': $_"
        Exit-Script 1
    }
}

Write-Host "`n[Pre-RDS] Waiting 60 s for RDVH VMs to fully boot..." -ForegroundColor Cyan
Start-Sleep -Seconds 60

# â”€â”€â”€ Step 5: Install Hyper-V inside each RDVH guest â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
Write-Host "`n[Pre-RDS] Installing Hyper-V role inside RDVH guests..." -ForegroundColor Cyan
foreach ($vh in $VHNames) {
    Write-Host "  -> Installing Hyper-V on '$vh'..." -ForegroundColor Cyan
    try {
        Invoke-Command -VMName $vh -Credential $domainAdminCred -ErrorAction Stop -ScriptBlock {
            $feature = Get-WindowsFeature -Name Hyper-V
            if ($feature.InstallState -ne 'Installed') {
                $result = Install-WindowsFeature -Name Hyper-V -IncludeManagementTools `
                                                 -ErrorAction Stop
                if (-not $result.Success) { throw "Hyper-V feature install failed." }
                Restart-Computer -Force
            } else {
                Write-Host "     Hyper-V already installed."
            }
        }
    } catch {
        $exType = $_.Exception.GetType().Name
        $exMsg  = $_.Exception.Message
        $isExpectedDisconnect =
            ($exType -match 'PSRemotingTransportException|PipelineStoppedException') -or
            ($exMsg  -match 'The pipeline has been stopped|connection.*closed|virtual machine.*turned off')
        if (-not $isExpectedDisconnect) {
            Write-Error "Failed to install Hyper-V on '$vh': $_"
            Exit-Script 1
        }
        Write-Host "     '$vh' rebooting after Hyper-V install (expected)." -ForegroundColor Yellow
    }
}

Write-Host "`n[Pre-RDS] Waiting 90 s for RDVH guests to reboot..." -ForegroundColor Cyan
Start-Sleep -Seconds 90

# â”€â”€â”€ Step 6: RDS VDI Deployment â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
$CBFQDN  = "$CBName.$DomainName"
$WAFQDN  = "$WAName.$DomainName"
$VHFQDNs = $VHNames | ForEach-Object { "$_.$DomainName" }

Write-Host "`nCreating RDS Virtual Desktop Deployment..." -ForegroundColor Cyan
try {
    Invoke-Command -VMName $CBName -Credential $domainAdminCred -ErrorAction Stop -ScriptBlock {
        param($cb, $wa, $vhs)
        Import-Module RemoteDesktop -ErrorAction Stop
        New-RDVirtualDesktopDeployment `
            -ConnectionBroker   $cb  `
            -WebAccessServer    $wa  `
            -VirtualizationHost $vhs
    } -ArgumentList $CBFQDN, $WAFQDN, $VHFQDNs
} catch {
    Write-Error "New-RDVirtualDesktopDeployment failed: $_"
    Exit-Script 1
}

# â”€â”€â”€ Step 7: Gateway roles â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
foreach ($gw in $GWNames) {
    $gwFQDN = "$gw.$DomainName"
    Write-Host "`nAdding RD Gateway role: $gwFQDN..." -ForegroundColor Cyan
    try {
        Invoke-Command -VMName $CBName -Credential $domainAdminCred -ErrorAction Stop -ScriptBlock {
            param($fqdn)
            Import-Module RemoteDesktop -ErrorAction Stop
            Add-RDServer -Server $fqdn -Role 'RDS-GATEWAY' -GatewayExternalFqdn $fqdn
        } -ArgumentList $gwFQDN
    } catch { Write-Warning "Failed to add Gateway '$gwFQDN': $_" }
}

# â”€â”€â”€ Step 8: Licensing roles â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
foreach ($lic in $LicNames) {
    $licFQDN = "$lic.$DomainName"
    Write-Host "`nAdding RD Licensing role: $licFQDN..." -ForegroundColor Cyan
    try {
        Invoke-Command -VMName $CBName -Credential $domainAdminCred -ErrorAction Stop -ScriptBlock {
            param($fqdn)
            Import-Module RemoteDesktop -ErrorAction Stop
            Add-RDServer -Server $fqdn -Role 'RDS-LICENSING'
        } -ArgumentList $licFQDN
    } catch { Write-Warning "Failed to add Licensing '$licFQDN': $_" }
}

Write-Host "`nRDS VDI deployment completed successfully." -ForegroundColor Green
Exit-Script 0
