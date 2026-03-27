#Requires -RunAsAdministrator
# ─── Transcript Safety ────────────────────────────────────────────────────────
$transcriptActive = $false
try { $transcriptActive = $null -ne (Get-Transcript -ErrorAction SilentlyContinue) } catch { }
if (-not $transcriptActive) {
    $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $logsDir   = Join-Path $PSScriptRoot "logs"
    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    Start-Transcript -Path (Join-Path $logsDir "DHCP_$timestamp.txt") -Append
}

function Stop-Safe { if (-not $transcriptActive) { try { Stop-Transcript } catch { } } }
function Exit-Script ([int]$Code = 1) { Stop-Safe; exit $Code }

$currentDir = $PSScriptRoot

# ─── Read network config from switch.txt ──────────────────────────────────────
$switchFile = Join-Path $currentDir "switch.txt"
if (Test-Path $switchFile) {
    $switchMap = @{}
    Get-Content -Path $switchFile | Where-Object { $_ -match '=' } | ForEach-Object {
        $kv = $_ -split '=', 2
        $switchMap[$kv[0].Trim()] = $kv[1].Trim()
    }
    $switchName   = $switchMap["SwitchName"]
    $gateway      = $switchMap["Gateway"]
    $networkAddr  = $switchMap["NetworkAddress"]
    $subnetMask   = $switchMap["SubnetMask"]
    $prefixLength = [int]$switchMap["PrefixLength"]
    $dhcpStart    = $switchMap["DHCPStart"]
    $dhcpEnd      = $switchMap["DHCPEnd"]
    Write-Host "Loaded network config: Network=$networkAddr, Gateway=$gateway"
} else {
    Write-Host "No switch.txt found. Using default network values." -ForegroundColor Yellow
    $switchName   = "NATSwitch"
    $gateway      = "192.168.1.1"
    $networkAddr  = "192.168.1.0"
    $subnetMask   = "255.255.255.0"
    $prefixLength = 24
    $dhcpStart    = "192.168.1.2"
    $dhcpEnd      = "192.168.1.254"
}

# ─── Detect host OS type ──────────────────────────────────────────────────────
$osInfo    = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
$isServer  = $osInfo.ProductType -ne 1   # 1 = Workstation; 2 = DC; 3 = Server
$installOnHost = $false

if ($isServer) {
    Write-Host ""
    Write-Host "=========================================="
    Write-Host "  Windows Server detected: $($osInfo.Caption)"
    Write-Host "=========================================="
    Write-Host ""
    Write-Host "  DHCP Scope : $dhcpStart - $dhcpEnd"
    Write-Host "  Gateway    : $gateway"
    Write-Host "  Subnet     : $subnetMask"
    Write-Host ""
    $response = Read-Host "Install DHCP role directly on this host? (Y/N)"
    if ($response -match '^[Yy]$') { $installOnHost = $true }
}

# ─── Option A: Install DHCP on host ───────────────────────────────────────────
if ($installOnHost) {
    Write-Host "`nInstalling DHCP role on local host..." -ForegroundColor Cyan

    try {
        $featResult = Install-WindowsFeature -Name DHCP -IncludeManagementTools -ErrorAction Stop
        if (-not $featResult.Success) {
            Write-Error "DHCP feature install failed."
            Exit-Script 1
        }

        Add-DhcpServerSecurityGroup -ErrorAction SilentlyContinue

        # BUG FIX: "netsh dhcp server init" is deprecated and unreliable on Server 2019+.
        # Use Set-DhcpServerv4Binding to bind the DHCP service to the lab adapter instead.
        $labAdapter = Get-NetIPAddress -IPAddress $gateway -ErrorAction SilentlyContinue
        if ($labAdapter) {
            Set-DhcpServerv4Binding -InterfaceAlias $labAdapter.InterfaceAlias -BindingState $true -ErrorAction SilentlyContinue
        }

        # BUG FIX: Add-DhcpServerv4Scope will throw if the scope already exists.
        # Check first to make this idempotent.
        $existingScope = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue |
                         Where-Object { $_.StartRange.ToString() -eq $dhcpStart }
        if (-not $existingScope) {
            Add-DhcpServerv4Scope -Name "LabScope" `
                                  -StartRange $dhcpStart `
                                  -EndRange   $dhcpEnd `
                                  -SubnetMask $subnetMask `
                                  -State Active -ErrorAction Stop
        } else {
            Write-Host "  -> DHCP scope already exists. Skipping creation." -ForegroundColor Yellow
        }

        Set-DhcpServerv4OptionValue -ScopeId $networkAddr -Router    @($gateway)  -ErrorAction Stop
        Set-DhcpServerv4OptionValue -ScopeId $networkAddr -DnsServer @("8.8.8.8") -ErrorAction Stop

        # Suppress Server Manager post-install notification
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12" `
                         -Name "ConfigurationState" -Value 2 -ErrorAction SilentlyContinue

        Write-Host ""
        Write-Host "  [OK]  DHCP role installed on host." -ForegroundColor Green
        Write-Host "        Scope  : $dhcpStart - $dhcpEnd"
        Write-Host "        Router : $gateway"
        Write-Host "        DNS    : 8.8.8.8"
    } catch {
        Write-Error "DHCP host installation failed: $_"
        Exit-Script 1
    }

# ─── Option B: Deploy DHCP as a standalone VM ─────────────────────────────────
} else {
    $vmName = "DHCP"

    $osYear = Read-Host "Enter OS year for the DHCP VM (2016, 2019, 2022, 2025)"
    if ($osYear -notin @("2016","2019","2022","2025")) {
        Write-Error "Invalid OS year: $osYear"
        Exit-Script 1
    }

    $seedPath = Join-Path $currentDir "sys_bootstrap.ini"
    if (-not (Test-Path $seedPath)) {
        Write-Error "sys_bootstrap.ini not found."
        Exit-Script 1
    }
    $baseVal = (Get-Content -Path $seedPath | Select-Object -First 1).Trim()
    if ([string]::IsNullOrWhiteSpace($baseVal)) {
        Write-Error "sys_bootstrap.ini is empty."
        Exit-Script 1
    }
    $initStr   = ConvertTo-SecureString $baseVal -AsPlainText -Force
    $adminCred = New-Object System.Management.Automation.PSCredential ("Administrator", $initStr)

    Write-Host "`nDeploying DHCP VM..." -ForegroundColor Cyan
    & (Join-Path $currentDir "deploy.ps1") -VMName $vmName -OS $osYear -InitCode $initStr
    if ($LASTEXITCODE -ne 0) {
        Write-Error "deploy.ps1 failed for DHCP VM."
        Exit-Script 1
    }

    # BUG FIX: The original script fired Invoke-Command immediately after deploy.ps1
    # without waiting for the VM to be reachable. Added a boot-wait loop.
    Write-Host "Waiting for DHCP VM to become reachable (up to 2 minutes)..." -ForegroundColor Cyan
    $ready   = $false
    $timeout = (Get-Date).AddMinutes(2)
    while (-not $ready -and (Get-Date) -lt $timeout) {
        try {
            Invoke-Command -VMName $vmName -Credential $adminCred -ErrorAction Stop `
                           -ScriptBlock { $true } | Out-Null
            $ready = $true   # success — exit loop immediately
        } catch {
            Start-Sleep -Seconds 5   # only sleep on genuine failure
        }
    }
    if (-not $ready) {
        Write-Error "DHCP VM did not become reachable within 2 minutes."
        Exit-Script 1
    }

    Write-Host "Configuring DHCP role inside VM..." -ForegroundColor Cyan
    try {
        Invoke-Command -VMName $vmName -Credential $adminCred -ErrorAction Stop -ScriptBlock {
            param($gw, $netAddr, $mask, $start, $end, $prefix)

            $feat = Install-WindowsFeature -Name DHCP -IncludeManagementTools -ErrorAction Stop
            if (-not $feat.Success) { throw "DHCP feature install failed." }

            Add-DhcpServerSecurityGroup -ErrorAction SilentlyContinue

            # BUG FIX: Same as host path — avoid netsh; use Set-DhcpServerv4Binding.
            Set-DhcpServerv4Binding -InterfaceAlias "Ethernet" -BindingState $true -ErrorAction SilentlyContinue

            $existing = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue |
                        Where-Object { $_.StartRange.ToString() -eq $start }
            if (-not $existing) {
                Add-DhcpServerv4Scope -Name "DefaultScope" `
                                      -StartRange $start `
                                      -EndRange   $end `
                                      -SubnetMask $mask `
                                      -State Active -ErrorAction Stop
            }

            Set-DhcpServerv4OptionValue -ScopeId $netAddr -Router    @($gw)       -ErrorAction Stop
            Set-DhcpServerv4OptionValue -ScopeId $netAddr -DnsServer @("8.8.8.8") -ErrorAction Stop

            # BUG FIX: $dhcpStart is 192.168.x.2 — assigning that as the VM's own static
            # IP means the first DHCP lease would collide with the server's own address.
            # The server should use .1 + 1 = the gateway? No — the gateway is the Hyper-V
            # host adapter. Use a distinct static IP outside the DHCP pool (e.g., .253).
            # We derive it from the start address by replacing last octet with 253.
            $staticIp = ($start -replace '\.\d+$', '.253')
            $existing = Get-NetIPAddress -InterfaceAlias "Ethernet" -AddressFamily IPv4 `
                                         -ErrorAction SilentlyContinue |
                        Where-Object { $_.IPAddress -eq $staticIp }
            if (-not $existing) {
                New-NetIPAddress -InterfaceAlias "Ethernet" `
                                 -IPAddress      $staticIp `
                                 -PrefixLength   $prefix `
                                 -DefaultGateway $gw `
                                 -ErrorAction Stop
            }

            Write-Host "DHCP configured: $start - $end, Gateway: $gw, Static IP: $staticIp"
            Restart-Computer -Force
        } -ArgumentList $gateway, $networkAddr, $subnetMask, $dhcpStart, $dhcpEnd, $prefixLength
    } catch {
        $exType = $_.Exception.GetType().Name
        $exMsg  = $_.Exception.Message
        $isExpectedDisconnect = ($exType -match 'PSRemotingTransportException|PipelineStoppedException') -or
                                ($exMsg  -match 'The pipeline has been stopped|connection.*closed|virtual machine.*turned off')
        if (-not $isExpectedDisconnect) {
            Write-Error "DHCP VM configuration failed: $_"
            Exit-Script 1
        }
        Write-Host "  -> DHCP VM rebooting after configuration (expected)." -ForegroundColor Yellow
    }
}

Write-Host "`nDHCP setup complete." -ForegroundColor Green
Exit-Script 0
