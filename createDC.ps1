#Requires -RunAsAdministrator
# -----------------------------------------------------------------------------
#  Domain Controller Provisioning Engine
# -----------------------------------------------------------------------------

param (
    [Parameter(Mandatory = $true)]
    [ValidateSet("2016","2019","2022","2025")]
    [string]$OS,

    [Parameter(Mandatory = $true)]
    [string]$VMName,

    [Parameter(Mandatory = $true)]
    [string]$DomainName,

    [Parameter(Mandatory = $false)]
    [System.Security.SecureString]$InitCode
)

# â”€â”€â”€ Transcript Safety â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
$transcriptActive = $false
try { $transcriptActive = $null -ne (Get-Transcript -ErrorAction SilentlyContinue) } catch { }
if (-not $transcriptActive) {
    $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $logsDir   = Join-Path $PSScriptRoot "logs"
    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    Start-Transcript -Path (Join-Path $logsDir "CreateDC_$timestamp.txt") -Append
}

function Stop-Safe { if (-not $transcriptActive) { try { Stop-Transcript } catch { } } }
function Exit-Script ([int]$Code = 1) { Stop-Safe; exit $Code }

Write-Host "`n=============================================" -ForegroundColor Cyan
Write-Host "  Domain Controller Provisioning"              -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan

# â”€â”€â”€ Credentials â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
$currentDir = $PSScriptRoot
$seedPath   = Join-Path $currentDir "sys_bootstrap.ini"

if (-not $InitCode) {
    if (-not (Test-Path $seedPath)) {
        Write-Error "sys_bootstrap.ini not found at: $seedPath"
        Exit-Script 1
    }
    $baseVal = (Get-Content -Path $seedPath | Select-Object -First 1).Trim()
    if ([string]::IsNullOrWhiteSpace($baseVal)) {
        Write-Error "sys_bootstrap.ini is empty. Add your master initialization code first."
        Exit-Script 1
    }
    $InitCode = ConvertTo-SecureString $baseVal -AsPlainText -Force
}
$adminCred = New-Object System.Management.Automation.PSCredential ("Administrator", $InitCode)

# â”€â”€â”€ Step 1: Deploy base VM â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
Write-Host "`nStep 1: Deploying base VM..." -ForegroundColor Cyan
& (Join-Path $currentDir "deploy.ps1") -VMName $VMName -OS $OS -InitCode $InitCode
if ($LASTEXITCODE -ne 0) {
    Write-Error "deploy.ps1 failed with exit code $LASTEXITCODE."
    Exit-Script 1
}

# â”€â”€â”€ Step 2: Wait for guest IP â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
Write-Host "`nStep 2: Waiting for guest IP address (up to 2 minutes)..." -ForegroundColor Cyan
$ip         = $null
$maxRetries = 24   # 24 x 5 s = 2 minutes
$attempt    = 0

while (-not $ip -and $attempt -lt $maxRetries) {
    $attempt++
    try {
        $ip = Invoke-Command -VMName $VMName -Credential $adminCred -ErrorAction Stop -ScriptBlock {
            Get-NetIPAddress -AddressFamily IPv4 |
                Where-Object { $_.IPAddress -notlike '169.*' -and $_.IPAddress -ne '127.0.0.1' } |
                Select-Object -First 1 -ExpandProperty IPAddress
        }
    } catch {
        Write-Host "  -> Attempt $attempt/$maxRetries guest not ready yet. Retrying in 5 s..." -ForegroundColor Yellow
        Start-Sleep -Seconds 5
    }
}

if (-not $ip) {
    Write-Error "Guest did not return a valid IP after 2 minutes. Check integration services and network."
    Exit-Script 1
}
Write-Host "  [OK]  Guest IP: $ip" -ForegroundColor Green

# â”€â”€â”€ Step 3: Promote to Domain Controller â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
Write-Host "`nStep 3: Promoting to Domain Controller (domain: $DomainName)..." -ForegroundColor Cyan

# BUG FIX: Install-ADDSForest triggers an automatic reboot. The original code
# had no error handling here â€” any failure (e.g. feature install issue) would
# silently continue. Added try/catch and checked that the command ran at all.
# Also, Install-ADDSForest must be called AFTER Install-WindowsFeature completes
# and the feature is fully available; the original had no intermediate check.
try {
    Invoke-Command -VMName $VMName -Credential $adminCred -ErrorAction Stop -ScriptBlock {
        param($domainName, [System.Security.SecureString]$safeModePassword)

        $feat = Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools
        if (-not $feat.Success) {
            throw "Failed to install AD-Domain-Services. Feature install result: $($feat.ExitCode)"
        }

        # Import the module explicitly â€” it may not auto-load inside PS Direct
        Import-Module ADDSDeployment -ErrorAction Stop

        Install-ADDSForest `
            -DomainName                    $domainName `
            -SafeModeAdministratorPassword $safeModePassword `
            -InstallDns                    `
            -Force                         `
            -NoRebootOnCompletion:$false   # allow the automatic reboot
    } -ArgumentList $DomainName, $InitCode
} catch {
    # After Install-ADDSForest the DC reboots, which breaks the PS Direct pipe.
    # PSRemotingTransportException / pipeline-stopped errors are expected here.
    $exType = $_.Exception.GetType().Name
    $exMsg  = $_.Exception.Message
    $isExpectedDisconnect = ($exType -match 'PSRemotingTransportException|PipelineStoppedException') -or
                            ($exMsg  -match 'The pipeline has been stopped|connection.*closed|virtual machine.*turned off')
    if (-not $isExpectedDisconnect) {
        Write-Error "DC promotion failed unexpectedly: $_"
        Exit-Script 1
    }
    Write-Host "  -> DC is rebooting as part of domain promotion (expected)." -ForegroundColor Yellow
}

# â”€â”€â”€ Step 4: Wait for DC to come back up and be AD-ready â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
# After Install-ADDSForest the DC reboots. We must wait until:
#   (a) PS Direct can reconnect (guest OS is up), AND
#   (b) the ADWS / Netlogon services are running (AD is functional)
# Without this wait, callers would immediately try to create AD objects or join
# the domain and fail because the DC is still mid-boot.
Write-Host "`nStep 4: Waiting for DC to finish booting and AD services to start..." -ForegroundColor Cyan

# The DC credential after promotion uses the DOMAIN\Administrator account.
# However immediately after reboot the local Administrator account is also valid
# (domain DB is still loading). Start with local then fall back to domain creds.
$domainAdminCred = New-Object System.Management.Automation.PSCredential ("$DomainName\Administrator", $InitCode)
$currentCred = $adminCred

$dcReadyTimeout = (Get-Date).AddMinutes(15)
$dcReady        = $false

while (-not $dcReady -and (Get-Date) -lt $dcReadyTimeout) {
    try {
        $svcStatus = Invoke-Command -VMName $VMName -Credential $currentCred -ErrorAction Stop -ScriptBlock {
            $adws    = Get-Service -Name ADWS -ErrorAction SilentlyContinue
            $netlogon = Get-Service -Name Netlogon -ErrorAction SilentlyContinue
            [PSCustomObject]@{
                ADWSRunning     = ($adws     -and $adws.Status     -eq 'Running')
                NetlogonRunning = ($netlogon -and $netlogon.Status -eq 'Running')
            }
        }

        if ($svcStatus.ADWSRunning -and $svcStatus.NetlogonRunning) {
            $dcReady = $true
            break
        }

        Write-Host "  -> AD services not yet running (ADWS=$($svcStatus.ADWSRunning), Netlogon=$($svcStatus.NetlogonRunning)). Waiting..." -ForegroundColor Yellow
        Start-Sleep -Seconds 15
    } catch {
        if ($currentCred -eq $adminCred) {
            Write-Host "  -> Local admin access not ready, switching to domain credentials and retrying..." -ForegroundColor Yellow
            $currentCred = $domainAdminCred
        } else {
            Write-Host "  -> DC not yet reachable via PS Direct using domain creds. Retrying in 15 s... ($((Get-Date).ToString('HH:mm:ss')) )" -ForegroundColor Yellow
            Start-Sleep -Seconds 15
        }
    }
}

if (-not $dcReady) {
    Write-Error "DC did not become AD-ready within 10 minutes. Check the VM manually."
    Exit-Script 1
}
Write-Host "  [OK]  DC is up and AD services are running." -ForegroundColor Green

Write-Host "`n[SUCCESS] Domain '$DomainName' is live on VM '$VMName'." -ForegroundColor Green
Exit-Script 0
