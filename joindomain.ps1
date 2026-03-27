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

# ─── Transcript Safety ────────────────────────────────────────────────────────
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

# ─── Credentials ──────────────────────────────────────────────────────────────
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

# ─── Validate DC connectivity ─────────────────────────────────────────────────
Write-Host "Validating Domain Controller connectivity..." -ForegroundColor Cyan
try {
    $testSession = New-PSSession -VMName $DcVmName -Credential $domainAdminCred -ErrorAction Stop
    Remove-PSSession -Session $testSession -ErrorAction SilentlyContinue
    Write-Host "  [OK]  DC '$DcVmName' is reachable." -ForegroundColor Green
} catch {
    Write-Error "Cannot connect to DC '$DcVmName': $_"
    Exit-Script 1
}

# ─── Retrieve DC info ─────────────────────────────────────────────────────────
$dcInfo = Invoke-Command -VMName $DcVmName -Credential $domainAdminCred -ErrorAction Stop -ScriptBlock {
    $ip = Get-NetIPAddress -AddressFamily IPv4 |
          Where-Object { $_.IPAddress -notlike '169.*' -and $_.IPAddress -ne '127.0.0.1' } |
          Select-Object -First 1 -ExpandProperty IPAddress
    $domain = (Get-CimInstance Win32_ComputerSystem).Domain
    [PSCustomObject]@{ IP = $ip; Domain = $domain }
}

Write-Host "  DC IP     : $($dcInfo.IP)"
Write-Host "  DC Domain : $($dcInfo.Domain)"

# ─── Parse VM list ────────────────────────────────────────────────────────────
$vmNamesArray = $VmNames -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
if ($vmNamesArray.Count -eq 0) {
    Write-Error "No VM names were provided to join."
    Exit-Script 1
}

# ─── Initiate domain join on each VM ─────────────────────────────────────────
foreach ($vm in $vmNamesArray) {
    Write-Host "`nProcessing VM: $vm" -ForegroundColor Cyan
    try {
        $vmAdminCred = New-Object System.Management.Automation.PSCredential ("Administrator", $VmInitCode)
        # BUG FIX: The original used New-PSSession + Invoke-Command -Session, but never
        # explicitly closed the session on success. Using -VMName directly is cleaner.
        Invoke-Command -VMName $vm -Credential $vmAdminCred -ErrorAction Stop -ScriptBlock {
            param($dcIp, $domain, [pscredential]$domCred)
            # Point DNS at the DC so the domain can be resolved during join
            Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } |
                Set-DnsClientServerAddress -ServerAddresses $dcIp

            # BUG FIX: -Restart in Add-Computer inside PS Direct disconnects the
            # session immediately, which PowerShell misreads as an error. Use
            # Restart-Computer separately so the error surface is clean.
            Add-Computer -DomainName $domain -Credential $domCred -Force -ErrorAction Stop
            Start-Sleep -Seconds 2   # brief pause before reboot
            Restart-Computer -Force
        } -ArgumentList $dcInfo.IP, $DomainToJoin, $domainAdminCred
        Write-Host "  [OK]  Domain join initiated for '$vm'." -ForegroundColor Green
    } catch {
        # Restart-Computer inside PS Direct kills the pipe — that is expected.
        # Distinguish it from a genuine Add-Computer failure.
        $exType = $_.Exception.GetType().Name
        $exMsg  = $_.Exception.Message
        $isExpectedDisconnect =
            ($exType -match 'PSRemotingTransportException|PipelineStoppedException') -or
            ($exMsg  -match 'The pipeline has been stopped|connection.*closed|virtual machine.*turned off')
        if ($isExpectedDisconnect) {
            Write-Host "  [OK]  '$vm' is rebooting to complete domain join." -ForegroundColor Green
        } else {
            Write-Host "  [FAIL] Could not process '$vm': $_" -ForegroundColor Red
        }
    }
}

# ─── Verify domain join ───────────────────────────────────────────────────────
Write-Host "`nWaiting for VMs to reboot and confirm domain membership..." -ForegroundColor Cyan

$joinedState  = @{}
foreach ($vm in $vmNamesArray) { $joinedState[$vm] = $false }

# Build credentials for checking domain membership
$vmAdminCred = New-Object System.Management.Automation.PSCredential ("Administrator", $VmInitCode)
$domainVmCred = New-Object System.Management.Automation.PSCredential ("$DomainToJoin\Administrator", $DomainInitCode)

$timeout     = (Get-Date).AddMinutes(15)
$domainLabel = $DomainToJoin.Split('.')[0]   # e.g. "corp" from "corp.local"

while ($joinedState.Values -contains $false) {
    if ((Get-Date) -gt $timeout) {
        $pending = $joinedState.GetEnumerator() |
                   Where-Object { -not $_.Value } |
                   ForEach-Object { $_.Key }
        Write-Warning "15-minute timeout reached. VMs still not confirmed: $($pending -join ', ')"
        break
    }

    foreach ($vm in $vmNamesArray) {
        if ($joinedState[$vm]) { continue }   # skip already-confirmed VMs

        # Try both local and domain credentials (similar to createdc.ps1 logic)
        $currentCred = $vmAdminCred
        $domainChecked = $false

        try {
            $domainStatus = Invoke-Command -VMName $vm -Credential $currentCred `
                                           -ErrorAction Stop -ScriptBlock {
                (Get-CimInstance Win32_ComputerSystem).Domain
            }
            if ($domainStatus -match [regex]::Escape($domainLabel)) {
                Write-Host "  [OK]  '$vm' is now a member of '$domainStatus'." -ForegroundColor Green
                $joinedState[$vm] = $true
            } else {
                Write-Host "  -> '$vm' reports domain '$domainStatus'. Still waiting..." -ForegroundColor Yellow
            }
        } catch {
            # If local admin fails, try domain admin (VM might have rebooted into domain)
            if (-not $domainChecked) {
                try {
                    $currentCred = $domainVmCred
                    $domainChecked = $true
                    $domainStatus = Invoke-Command -VMName $vm -Credential $currentCred `
                                                   -ErrorAction Stop -ScriptBlock {
                        (Get-CimInstance Win32_ComputerSystem).Domain
                    }
                    if ($domainStatus -match [regex]::Escape($domainLabel)) {
                        Write-Host "  [OK]  '$vm' is now a member of '$domainStatus'." -ForegroundColor Green
                        $joinedState[$vm] = $true
                    } else {
                        Write-Host "  -> '$vm' reports domain '$domainStatus'. Still waiting..." -ForegroundColor Yellow
                    }
                } catch {
                    Write-Host "  -> '$vm' unreachable (still rebooting). Waiting..." -ForegroundColor Yellow
                }
            } else {
                Write-Host "  -> '$vm' unreachable (still rebooting). Waiting..." -ForegroundColor Yellow
            }
        }
    }

    if ($joinedState.Values -contains $false) { Start-Sleep -Seconds 15 }
}

$allJoined = -not ($joinedState.Values -contains $false)
if ($allJoined) {
    Write-Host "`nAll VMs have joined the domain." -ForegroundColor Green
    Exit-Script 0
} else {
    Write-Warning "Some VMs did not confirm domain membership within the timeout."
    Exit-Script 1
}
