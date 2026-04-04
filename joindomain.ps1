#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Joins multiple VMs to a domain using PowerShell Direct.
.PARAMETER DcVmName
    Mandatory. The name of the Domain Controller VM.
.PARAMETER DomainToJoin
    Mandatory. The domain name (e.g., corp.local).
.PARAMETER DomainAdminUser
    Optional. Defaults to "<DomainToJoin>\Administrator".
.PARAMETER DomainInitCode
    Optional. SecureString. Read from sys_bootstrap.ini if omitted.
.PARAMETER VmInitCode
    Optional. SecureString for local Admin on member VMs. Defaults to DomainInitCode.
.PARAMETER VmNames
    Mandatory. Comma-separated list of VM names to join.
.EXAMPLE
    .\joindomain.ps1 -DcVmName DC01 -DomainToJoin corp.local -VmNames "VM1,VM2"
#>

param (
    [Parameter(Mandatory = $true)]  [string]$DcVmName,
    [Parameter(Mandatory = $true)]  [string]$DomainToJoin,
    [Parameter(Mandatory = $false)] [string]$DomainAdminUser,
    [Parameter(Mandatory = $false)] [System.Security.SecureString]$DomainInitCode,
    [Parameter(Mandatory = $false)] [System.Security.SecureString]$VmInitCode,
    [Parameter(Mandatory = $true)]  [string]$VmNames
)

# â”€â”€â”€ Transcript Safety â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
$transcriptActive = $false
try { $transcriptActive = $null -ne (Get-Transcript -ErrorAction SilentlyContinue) } catch { }
if (-not $transcriptActive) {
    $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $logsDir   = Join-Path $PSScriptRoot "logs"
    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    Start-Transcript -Path (Join-Path $logsDir "joindomain_$timestamp.txt") -Append
}

function Stop-Safe { if (-not $transcriptActive) { try { Stop-Transcript } catch { } } }
function Exit-Script ([int]$Code = 1) { Stop-Safe; exit $Code }

# â”€â”€â”€ Credentials â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
$currentDir = $PSScriptRoot
$seedPath   = Join-Path $currentDir "sys_bootstrap.ini"

# BUG FIX: The original read sys_bootstrap.ini unconditionally at the top, then
# checked whether codes were needed. If the file was missing this threw a
# terminating error before the check. Now only read the file when actually needed.
if (-not $DomainInitCode -or -not $VmInitCode) {
    if (-not (Test-Path $seedPath)) {
        Write-Error "sys_bootstrap.ini not found and no InitCode parameters were supplied."
        Exit-Script 1
    }
    $baseVal = (Get-Content -Path $seedPath | Select-Object -First 1).Trim()
    if ([string]::IsNullOrWhiteSpace($baseVal)) {
        Write-Error "sys_bootstrap.ini is empty."
        Exit-Script 1
    }
    $fallback = ConvertTo-SecureString $baseVal -AsPlainText -Force
    if (-not $DomainInitCode) { $DomainInitCode = $fallback }
    if (-not $VmInitCode)     { $VmInitCode     = $fallback }
}

if (-not $DomainAdminUser) { $DomainAdminUser = "$DomainToJoin\Administrator" }
$domainAdminCred = New-Object System.Management.Automation.PSCredential ($DomainAdminUser, $DomainInitCode)

# â”€â”€â”€ Validate DC connectivity â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
Write-Host "Validating Domain Controller connectivity..." -ForegroundColor Cyan
try {
    $testSession = New-PSSession -VMName $DcVmName -Credential $domainAdminCred -ErrorAction Stop
    Remove-PSSession -Session $testSession -ErrorAction SilentlyContinue
    Write-Host "  [OK]  DC '$DcVmName' is reachable." -ForegroundColor Green
} catch {
    Write-Error "Cannot connect to DC '$DcVmName': $_"
    Exit-Script 1
}

# â”€â”€â”€ Retrieve DC info â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
$dcInfo = Invoke-Command -VMName $DcVmName -Credential $domainAdminCred -ErrorAction Stop -ScriptBlock {
    $ip = Get-NetIPAddress -AddressFamily IPv4 |
          Where-Object { $_.IPAddress -notlike '169.*' -and $_.IPAddress -ne '127.0.0.1' } |
          Select-Object -First 1 -ExpandProperty IPAddress
    $domain = (Get-CimInstance Win32_ComputerSystem).Domain
    [PSCustomObject]@{ IP = $ip; Domain = $domain }
}

Write-Host "  DC IP     : $($dcInfo.IP)"
Write-Host "  DC Domain : $($dcInfo.Domain)"

# â”€â”€â”€ Parse VM list â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
$vmNamesArray = $VmNames -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
if ($vmNamesArray.Count -eq 0) {
    Write-Error "No VM names were provided to join."
    Exit-Script 1
}

# â”€â”€â”€ Helper: Invoke-DomainJoin â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
# Encapsulates the full join sequence for a single VM so it can be called both
# on first attempt and on retry from inside the verify loop.
function Invoke-DomainJoin {
    param(
        [string]$VmName,
        [string]$DcIp,
        [string]$Domain,
        [pscredential]$LocalCred,
        [pscredential]$DomainCred
    )

    try {
        Invoke-Command -VMName $VmName -Credential $LocalCred -ErrorAction Stop -ScriptBlock {
            param($dcIp, $domain, [pscredential]$domCred)

            # Step 1: Point DNS at the DC so the domain name resolves during join.
            $upAdapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }
            $upAdapters | Set-DnsClientServerAddress -ServerAddresses $dcIp

            # Step 2: Switch network profile from Public to Private.
            # FIX: Windows 11 defaults to Public firewall profile on first boot.
            # Public mode blocks Kerberos (TCP 88), LDAP (TCP 389), SMB (TCP 445)
            # which are all required by Add-Computer. DNS/ping still work because
            # UDP 53 is permitted â€” which is why nslookup succeeds but the join
            # fails with "domain does not exist or could not be contacted".
            foreach ($adapter in $upAdapters) {
                try {
                    Set-NetConnectionProfile -InterfaceAlias $adapter.Name `
                                             -NetworkCategory Private -ErrorAction Stop
                } catch {
                    Write-Warning "  -> Could not set Private profile on '$($adapter.Name)': $_"
                }
            }

            # BUG FIX: -Restart in Add-Computer inside PS Direct disconnects the
            # session immediately, which PowerShell misreads as an error. Use
            # Restart-Computer separately so the error surface is clean.
            Add-Computer -DomainName $domain -Credential $domCred -Force -ErrorAction Stop
            Start-Sleep -Seconds 2
            Restart-Computer -Force

        } -ArgumentList $DcIp, $Domain, $DomainCred

        # If Invoke-Command returned without throwing, join + reboot fired cleanly.
        Write-Host "  [OK]  Domain join initiated for '$VmName'." -ForegroundColor Green
        return 'initiated'

    } catch {
        $exType = $_.Exception.GetType().Name
        $exMsg  = $_.Exception.Message
        $isExpectedDisconnect =
            ($exType -match 'PSRemotingTransportException|PipelineStoppedException') -or
            ($exMsg  -match 'The pipeline has been stopped|connection.*closed|virtual machine.*turned off')

        if ($isExpectedDisconnect) {
            # Restart-Computer dropping the pipe is normal â€” join succeeded.
            Write-Host "  [OK]  '$VmName' is rebooting to complete domain join." -ForegroundColor Green
            return 'initiated'
        } else {
            Write-Host "  [FAIL] Join attempt failed for '$VmName': $_" -ForegroundColor Red
            return 'failed'
        }
    }
}

# â”€â”€â”€ Helper: Wait-DCReady â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
# Blocks until the DC responds to PS Direct AND ADWS (AD Web Services, port 9389)
# is running inside the guest. ADWS is the last AD service to start after reboot
# and is required for Add-Computer to succeed. Waiting only for PS Direct
# reachability is not sufficient â€” the DC can accept a shell session while AD
# services are still initialising, causing the join to fail with "domain could
# not be contacted" even though DNS and ping are working.
function Wait-DCReady {
    param(
        [string]$DcVmName,
        [pscredential]$Cred,
        [int]$TimeoutSeconds = 300
    )

    Write-Host "  -> Waiting for DC '$DcVmName' AD services to be fully ready..." -ForegroundColor Cyan
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        try {
            $adwsRunning = Invoke-Command -VMName $DcVmName -Credential $Cred `
                                          -ErrorAction Stop -ScriptBlock {
                $svc = Get-Service -Name ADWS -ErrorAction SilentlyContinue
                $svc -and $svc.Status -eq 'Running'
            }
            if ($adwsRunning) {
                Write-Host "  [OK]  DC AD services are ready." -ForegroundColor Green
                return $true
            }
            Write-Host "  -> DC reachable but ADWS not running yet. Retrying in 10s..." -ForegroundColor Yellow
        } catch {
            Write-Host "  -> DC not yet reachable via PS Direct. Retrying in 10s..." -ForegroundColor Yellow
        }
        Start-Sleep -Seconds 10
    }

    Write-Warning "DC did not become fully ready within $TimeoutSeconds seconds."
    return $false
}

# â”€â”€â”€ Build shared credentials â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
$vmAdminCred  = New-Object System.Management.Automation.PSCredential ("Administrator", $VmInitCode)
$domainAdminCred = New-Object System.Management.Automation.PSCredential ($DomainAdminUser, $DomainInitCode)

# â”€â”€â”€ Wait for DC to be fully ready before attempting any joins â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
$dcReady = Wait-DCReady -DcVmName $DcVmName -Cred $domainAdminCred -TimeoutSeconds 300
if (-not $dcReady) {
    Write-Host ""
    Write-Host "  [FAIL] DC did not become ready in time. Cannot proceed with domain join." -ForegroundColor Red
    Exit-Script 1
}

# â”€â”€â”€ Initiate domain join on each VM â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
# joinAttemptState tracks whether a join was ever successfully *initiated*
# (meaning Add-Computer ran without error). A VM that never got a clean join
# attempt needs a retry in the verify loop â€” not just polling.
$joinAttemptState = @{}
foreach ($vm in $vmNamesArray) {
    Write-Host "`nProcessing VM: $vm" -ForegroundColor Cyan
    $joinAttemptState[$vm] = Invoke-DomainJoin `
        -VmName    $vm `
        -DcIp      $dcInfo.IP `
        -Domain    $DomainToJoin `
        -LocalCred $vmAdminCred `
        -DomainCred $domainAdminCred
}

# â”€â”€â”€ Verify domain join â€” with automatic retry on stalled VMs â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
Write-Host "`nWaiting for VMs to reboot and confirm domain membership..." -ForegroundColor Cyan

$joinedState   = @{}
$stalledCount  = @{}   # consecutive verify-cycles where VM is still WORKGROUP
foreach ($vm in $vmNamesArray) {
    $joinedState[$vm]  = $false
    $stalledCount[$vm] = 0
}

$domainVmCred = New-Object System.Management.Automation.PSCredential ("$DomainToJoin\Administrator", $DomainInitCode)
$domainLabel  = $DomainToJoin.Split('.')[0]   # e.g. "testdaidai" from "testdaidai.lab"

# No hard timeout â€” loop until every VM confirms membership.
# Each VM gets an automatic re-join attempt after 5 consecutive stalled cycles
# (5 x 15s = 75s), which handles the case where the DC was rebooting during the
# first attempt and Add-Computer errored out silently.
while ($joinedState.Values -contains $false) {

    foreach ($vm in $vmNamesArray) {
        if ($joinedState[$vm]) { continue }

        $domainStatus  = $null
        $vmReachable   = $false

        # Try local creds first, fall back to domain creds
        foreach ($cred in @($vmAdminCred, $domainVmCred)) {
            try {
                $domainStatus = Invoke-Command -VMName $vm -Credential $cred `
                                               -ErrorAction Stop -ScriptBlock {
                    (Get-CimInstance Win32_ComputerSystem).Domain
                }
                $vmReachable = $true
                break
            } catch { }
        }

        if (-not $vmReachable) {
            Write-Host "  -> '$vm' unreachable (still rebooting). Waiting..." -ForegroundColor Yellow
            # Don't increment stalled count while unreachable â€” VM may just be mid-reboot.
            continue
        }

        if ($domainStatus -match [regex]::Escape($domainLabel)) {
            Write-Host "  [OK]  '$vm' is now a member of '$domainStatus'." -ForegroundColor Green
            $joinedState[$vm]  = $true
            $stalledCount[$vm] = 0
            continue
        }

        # VM is reachable but still reports WORKGROUP.
        $stalledCount[$vm]++
        Write-Host "  -> '$vm' reports '$domainStatus' (stall $($stalledCount[$vm])/5). Still waiting..." -ForegroundColor Yellow

        # After 5 consecutive stalled cycles, re-attempt the join.
        # This fires when the original attempt failed because the DC was mid-reboot,
        # or when the Add-Computer silently failed and the VM never rebooted.
        if ($stalledCount[$vm] -ge 5) {
            Write-Host "  -> '$vm' stalled too long. Verifying DC is ready then re-attempting join..." -ForegroundColor Yellow

            $dcStillReady = Wait-DCReady -DcVmName $DcVmName -Cred $domainAdminCred -TimeoutSeconds 120
            if ($dcStillReady) {
                $retryResult = Invoke-DomainJoin `
                    -VmName     $vm `
                    -DcIp       $dcInfo.IP `
                    -Domain     $DomainToJoin `
                    -LocalCred  $vmAdminCred `
                    -DomainCred $domainAdminCred

                if ($retryResult -eq 'initiated') {
                    Write-Host "  -> '$vm' join re-initiated. Resetting stall counter." -ForegroundColor Cyan
                    $stalledCount[$vm] = 0
                } else {
                    Write-Host "  -> '$vm' re-join attempt failed. Will retry in next cycle." -ForegroundColor Yellow
                    $stalledCount[$vm] = 0   # reset so we try again after another 5 cycles
                }
            } else {
                Write-Host "  -> DC not ready for retry. Will try again in next cycle." -ForegroundColor Yellow
                $stalledCount[$vm] = 0
            }
        }
    }

    if ($joinedState.Values -contains $false) { Start-Sleep -Seconds 15 }
}

Write-Host "`nAll VMs have joined the domain." -ForegroundColor Green
Exit-Script 0
