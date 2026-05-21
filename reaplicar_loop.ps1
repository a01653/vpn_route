param(
  [string]$LogPath = 'C:\temp\vpn\reaplicar.log',
  [string]$StatePath = 'C:\temp\vpn\reaplicar_state.json',
  [string]$RuntimePath = 'C:\temp\vpn\reaplicar_runtime.json',
  [string]$StopSignalPath = 'C:\temp\vpn\reaplicar_loop.stop',
  [string]$StopTime = '16:00',
  [int]$Interval = 3,
  [int]$LogRetentionDays = 7,
  [int]$LanRouteMetric = 25,
  [int]$VpnRouteMetric = 100
)

$VpnInternalPrefixes = @(
  '10.136.0.0/16',
  '172.28.0.0/16',
  '10.143.0.0/16',
  '10.142.0.0/16',
  '10.141.0.0/16',
  '10.140.0.0/16'
)

function Rotate-Log {
    param([string]$Path, [int]$Days)
    try {
        if (Test-Path $Path) {
            $tmp = "$Path.tmp"
            $limit = (Get-Date).AddDays(-$Days)
            Get-Content $Path | ForEach-Object {
                if ($_ -match '^\[(\d{4}-\d{2}-\d{2})' ) {
                    $date = Get-Date $Matches[1]
                    if ($date -ge $limit) { $_ }
                } else {
                    $_
                }
            } | Set-Content $tmp -Encoding UTF8
            Move-Item -Force $tmp $Path
        }
    } catch {}
}

function Write-Log([string]$Text) {
    Add-Content -Path $LogPath -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Text"
}

function Write-RuntimeState {
    param(
      [string]$Path,
      [string]$StopTimeValue,
      [string]$StateFilePath,
      [string]$StopFilePath
    )

    $payload = [pscustomobject]@{
        Pid            = $PID
        StartedAt      = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        StopTime       = $StopTimeValue
        StatePath      = $StateFilePath
        StopSignalPath = $StopFilePath
    }

    $payload | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Remove-RuntimeState {
    param(
      [string]$Path,
      [int]$ExpectedPid
    )

    if (-not (Test-Path $Path)) {
        return
    }

    try {
        $runtime = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([int]$runtime.Pid -eq $ExpectedPid) {
            Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        }
    } catch {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-RouteCmd([string]$Cmd) {
    $p = Start-Process -FilePath 'cmd.exe' -ArgumentList "/c $Cmd" -WindowStyle Hidden -PassThru -Wait
    return $p.ExitCode
}

function Get-MaskFromPrefix($prefixLen) {
    $p = [int]$prefixLen
    if ($p -lt 0 -or $p -gt 32) { throw "Prefijo /$prefixLen no válido" }
    $maskInt = [uint32](([math]::Pow(2, 32) - 1) -bxor ([math]::Pow(2, (32 - $p)) - 1))
    $maskBytes = [BitConverter]::GetBytes([uint32]$maskInt)
    [Array]::Reverse($maskBytes)
    return [IPAddress]::new($maskBytes).ToString()
}

function Format-StringArray([string[]]$Values) {
    $items = @($Values | Where-Object { $_ })
    if (-not $items) {
        return '(vacío)'
    }
    return ($items -join ', ')
}

function Get-NormalizedIpv4DnsServers {
    param([int]$InterfaceIndex)

    try {
        return @(
            (Get-DnsClientServerAddress -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop).ServerAddresses |
            Where-Object { $_ } |
            ForEach-Object { $_.Trim().ToLowerInvariant() }
        )
    } catch {
        return @()
    }
}

function Read-StateFile {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return $null
    }

    try {
        $state = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        return [pscustomobject]@{
            SelectedLanIfIndex    = if ($state.SelectedLanIfIndex) { [int]$state.SelectedLanIfIndex } else { 0 }
            SelectedLanName       = [string]$state.SelectedLanName
            ManageVpnDns          = [bool]$state.ManageVpnDns
            DesiredDnsServersIPv4 = @($state.DesiredDnsServersIPv4 | Where-Object { $_ } | ForEach-Object { $_.Trim().ToLowerInvariant() })
        }
    } catch {
        Write-Log "ERROR leyendo estado DNS ($Path): $($_.Exception.Message)"
        return $null
    }
}

function Get-DnsState {
    param(
      [int]$LanIfIndex,
      [int]$VpnIfIndex,
      [string[]]$ExpectedDnsServers
    )

    $expected = @($ExpectedDnsServers | Where-Object { $_ } | ForEach-Object { $_.Trim().ToLowerInvariant() })
    if (-not $expected) {
        return [pscustomobject]@{
            Ok = $true
            Repairable = $false
            Reason = 'No hay DNS objetivo guardados'
            LanIfIndex = $LanIfIndex
            VpnIfIndex = $VpnIfIndex
            ExpectedDnsServers = @()
        }
    }

    $lanCurrent = if ($LanIfIndex) { Get-NormalizedIpv4DnsServers -InterfaceIndex $LanIfIndex } else { @() }
    $vpnCurrent = if ($VpnIfIndex) { Get-NormalizedIpv4DnsServers -InterfaceIndex $VpnIfIndex } else { @() }

    $vpnOk = if ($VpnIfIndex) {
        ((@($vpnCurrent) -join ',') -eq (@($expected) -join ','))
    } else {
        $false
    }

    $reason = @(
      "DNS esperados=$(Format-StringArray $expected)",
      "LAN ref if=$LanIfIndex",
      "LAN actual=$(Format-StringArray $lanCurrent)",
      "VPN if=$VpnIfIndex",
      "VPN dns=$(Format-StringArray $vpnCurrent)"
    ) -join ', '

    return [pscustomobject]@{
        Ok = $vpnOk
        Repairable = [bool]($VpnIfIndex -and $expected)
        Reason = $reason
        LanIfIndex = $LanIfIndex
        VpnIfIndex = $VpnIfIndex
        ExpectedDnsServers = $expected
    }
}

function Get-InterfaceMetricValue([int]$IfIndex) {
    try {
        $ifObj = Get-NetIPInterface -InterfaceIndex $IfIndex -AddressFamily IPv4 -ErrorAction Stop |
          Sort-Object InterfaceMetric |
          Select-Object -First 1
        if ($ifObj) {
            return [int]$ifObj.InterfaceMetric
        }
    } catch {}
    return 0
}

function Get-BestRouteWithTotalMetric {
    param(
      [string]$DestinationPrefix,
      [scriptblock]$FilterScript
    )

    $routes = Get-NetRoute -DestinationPrefix $DestinationPrefix -AddressFamily IPv4 -ErrorAction SilentlyContinue |
      Where-Object $FilterScript |
      ForEach-Object {
        $ifMetric = Get-InterfaceMetricValue -IfIndex $_.InterfaceIndex
        [pscustomobject]@{
            Route       = $_
            IfMetric    = $ifMetric
            TotalMetric = ([int]$_.RouteMetric + [int]$ifMetric)
        }
      } |
      Sort-Object TotalMetric, @{Expression = { $_.Route.RouteMetric }}, @{Expression = { $_.Route.InterfaceIndex }}

    return ($routes | Select-Object -First 1)
}

function Get-RouteState {
    $vpn = Get-NetAdapter |
      Where-Object { $_.InterfaceDescription -like '*PANGP*' -and $_.Status -eq 'Up' } |
      Select-Object -First 1

    if (-not $vpn) {
        return [pscustomobject]@{
            Ok = $false
            Repairable = $false
            Reason = 'VPN no conectada'
        }
    }

    $vpnIdx = $vpn.IfIndex

    $lanDefInfo = Get-BestRouteWithTotalMetric -DestinationPrefix '0.0.0.0/0' -FilterScript {
        $_.NextHop -and
        $_.NextHop -ne '0.0.0.0' -and
        $_.InterfaceIndex -ne $vpnIdx
    }

    if (-not $lanDefInfo) {
        return [pscustomobject]@{
            Ok = $false
            Repairable = $false
            Reason = 'No hay ruta LAN por defecto válida'
            VpnIfIndex = $vpnIdx
        }
    }

    $vpnDefInfo = Get-BestRouteWithTotalMetric -DestinationPrefix '0.0.0.0/0' -FilterScript {
        $_.InterfaceIndex -eq $vpnIdx -and (
            $_.NextHop -eq '0.0.0.0' -or
            $_.NextHop -eq '::'
        )
    }

    $lanDef = $lanDefInfo.Route
    $vpnDef = if ($vpnDefInfo) { $vpnDefInfo.Route } else { $null }

    $lanRouteMetric = [int]$lanDef.RouteMetric
    $lanIfMetric    = [int]$lanDefInfo.IfMetric
    $lanTotalMetric = [int]$lanDefInfo.TotalMetric

    $vpnRouteMetric = if ($vpnDef) { [int]$vpnDef.RouteMetric } else { -1 }
    $vpnIfMetric    = if ($vpnDefInfo) { [int]$vpnDefInfo.IfMetric } else { -1 }
    $vpnTotalMetric = if ($vpnDefInfo) { [int]$vpnDefInfo.TotalMetric } else { -1 }

    $okLan = ($lanRouteMetric -eq $LanRouteMetric)
    $okVpn = ($vpnDef -and $vpnRouteMetric -eq $VpnRouteMetric)
    $okPriority = ($vpnDefInfo -and $lanTotalMetric -lt $vpnTotalMetric)
    $missingVpnPrefixes = @(
        foreach ($prefix in $VpnInternalPrefixes) {
            $route = Get-NetRoute -DestinationPrefix $prefix -AddressFamily IPv4 -ErrorAction SilentlyContinue |
              Where-Object {
                $_.InterfaceIndex -eq $vpnIdx -and (
                    $_.NextHop -eq '0.0.0.0' -or
                    $_.NextHop -eq '::'
                )
              } |
              Select-Object -First 1

            if (-not $route) {
                $prefix
            }
        }
    )
    $okInternal = ($missingVpnPrefixes.Count -eq 0)

    $reason = @(
      "LAN if=$($lanDef.InterfaceIndex)",
      "LAN nextHop=$($lanDef.NextHop)",
      "LAN metric=$lanRouteMetric+$lanIfMetric=$lanTotalMetric",
      "VPN if=$vpnIdx",
      "VPN metric=$(if($vpnDef){"$vpnRouteMetric+$vpnIfMetric=$vpnTotalMetric"}else{'ausente'})",
      "VPN internos=$(if($okInternal){'ok'}else{'faltan ' + ($missingVpnPrefixes -join ', ')})"
    ) -join ', '

    return [pscustomobject]@{
        Ok = ($okLan -and $okVpn -and $okPriority -and $okInternal)
        Repairable = $true
        Reason = $reason
        LanIfIndex = $lanDef.InterfaceIndex
        LanGateway = $lanDef.NextHop
        VpnIfIndex = $vpnIdx
        LanTotalMetric = $lanTotalMetric
        VpnTotalMetric = $vpnTotalMetric
        MissingVpnPrefixes = @($missingVpnPrefixes)
    }
}

function Ensure-Route {
    param(
      [string]$Prefix,
      [int]$IfIndex,
      [string]$Gateway,
      [int]$Metric = $null
    )

    $cidr = [int]($Prefix.Split('/')[-1])
    $mask = Get-MaskFromPrefix $cidr
    $dest = $Prefix.Split('/')[0]
    $prefixRoute = "$dest/$cidr"
    $exists = Get-NetRoute -DestinationPrefix $prefixRoute -InterfaceIndex $IfIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
      Select-Object -First 1

    if ($exists) {
        $cmd = "route change $dest mask $mask $Gateway if $IfIndex"
    } else {
        $cmd = "route add $dest mask $mask $Gateway if $IfIndex"
    }

    if ($Metric -ne $null) { $cmd += " metric $Metric" }
    [void](Invoke-RouteCmd $cmd)
}

function Repair-Routes {
    param(
      [int]$LanIfIndex,
      [string]$LanGateway,
      [int]$VpnIfIndex,
      [string[]]$MissingVpnPrefixes = @()
    )

    Ensure-Route -Prefix '0.0.0.0/0' -IfIndex $LanIfIndex -Gateway $LanGateway -Metric $LanRouteMetric
    Ensure-Route -Prefix '0.0.0.0/0' -IfIndex $VpnIfIndex -Gateway '0.0.0.0' -Metric $VpnRouteMetric

    foreach ($prefix in @($MissingVpnPrefixes | Where-Object { $_ })) {
        Ensure-Route -Prefix $prefix -IfIndex $VpnIfIndex -Gateway '0.0.0.0'
    }
}

function Repair-Dns {
    param(
      [int]$VpnIfIndex,
      [string[]]$DnsServers
    )

    $targets = @($VpnIfIndex)
    $targets = @($targets | Where-Object { $_ })
    $targets = @($targets | Sort-Object -Unique)
    $desired = @($DnsServers | Where-Object { $_ })

    if (-not $targets -or -not $desired) {
        return
    }

    foreach ($ifIndex in $targets) {
        try {
            Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses $desired -ErrorAction Stop
            Write-Log "DNS VPN reaplicados en if=$ifIndex -> $(Format-StringArray $desired)"
        } catch {
            Write-Log "ERROR reaplicando DNS VPN en if=${ifIndex}: $($_.Exception.Message)"
        }
    }
}

$todayStop = [datetime]::Today.Add([timespan]::Parse($StopTime))
if ((Get-Date) -ge $todayStop) {
    $todayStop = $todayStop.AddDays(1)
}

$logDir = Split-Path $LogPath -Parent
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}
if (-not (Test-Path $LogPath)) {
    New-Item -Path $LogPath -ItemType File -Force | Out-Null
}

Rotate-Log -Path $LogPath -Days $LogRetentionDays
Remove-Item -LiteralPath $StopSignalPath -Force -ErrorAction SilentlyContinue
Write-RuntimeState -Path $RuntimePath -StopTimeValue $StopTime -StateFilePath $StatePath -StopFilePath $StopSignalPath
Write-Log "Script iniciado (PID=$PID, StopTime=$StopTime, Interval=${Interval}s)"

$lastHealth = $null

while ((Get-Date) -lt $todayStop) {
    try {
        if (Test-Path $StopSignalPath) {
            Write-Log 'Señal de parada detectada. Finalizando bucle.'
            break
        }

        $routeState = Get-RouteState
        $savedState = Read-StateFile -Path $StatePath
        $dnsLanIfIndex = if ($routeState.LanIfIndex) { $routeState.LanIfIndex } elseif ($savedState) { $savedState.SelectedLanIfIndex } else { 0 }
        $dnsState = if ($savedState -and $savedState.ManageVpnDns) {
            Get-DnsState -LanIfIndex $dnsLanIfIndex -VpnIfIndex $routeState.VpnIfIndex -ExpectedDnsServers $savedState.DesiredDnsServersIPv4
        } else {
            [pscustomobject]@{
                Ok = $true
                Repairable = $false
                Reason = 'Gestión DNS desactivada'
                LanIfIndex = $dnsLanIfIndex
                VpnIfIndex = $routeState.VpnIfIndex
                ExpectedDnsServers = @()
            }
        }

        $health = @(
            "route=$($routeState.Ok)|$($routeState.Repairable)|$($routeState.Reason)|$($routeState.LanIfIndex)|$($routeState.LanGateway)|$($routeState.VpnIfIndex)|$($routeState.LanTotalMetric)|$($routeState.VpnTotalMetric)",
            "dns=$($dnsState.Ok)|$($dnsState.Repairable)|$($dnsState.Reason)|$(Format-StringArray $dnsState.ExpectedDnsServers)"
        ) -join ' || '

        if (-not $routeState.Ok -or -not $dnsState.Ok) {
            $repaired = $false

            if (-not $routeState.Ok) {
                if ($routeState.Repairable -and $routeState.LanIfIndex -and $routeState.LanGateway -and $routeState.VpnIfIndex) {
                    Write-Log "Cambio detectado / rutas incorrectas: $($routeState.Reason). Reaplicando rutas por defecto."
                    Repair-Routes -LanIfIndex $routeState.LanIfIndex -LanGateway $routeState.LanGateway -VpnIfIndex $routeState.VpnIfIndex -MissingVpnPrefixes $routeState.MissingVpnPrefixes
                    $repaired = $true
                } else {
                    if ($health -ne $lastHealth) {
                        Write-Log "Estado de rutas no reparable todavia: $($routeState.Reason)"
                        $lastHealth = $health
                    }
                    Start-Sleep -Seconds $Interval
                    continue
                }
            }

            if (-not $dnsState.Ok) {
                if ($dnsState.Repairable) {
                    Write-Log "Cambio detectado / DNS VPN incorrectos: $($dnsState.Reason). Reaplicando DNS guardados en la VPN."
                    Repair-Dns -VpnIfIndex $routeState.VpnIfIndex -DnsServers $dnsState.ExpectedDnsServers
                    $repaired = $true
                } else {
                    if ($health -ne $lastHealth) {
                        Write-Log "Estado de DNS no reparable todavia: $($dnsState.Reason)"
                        $lastHealth = $health
                    }
                    Start-Sleep -Seconds $Interval
                    continue
                }
            }

            if ($repaired) {
                Start-Sleep -Milliseconds 700
                $routeCheck = Get-RouteState
                $savedState = Read-StateFile -Path $StatePath
                $dnsLanIfIndex = if ($routeCheck.LanIfIndex) { $routeCheck.LanIfIndex } elseif ($savedState) { $savedState.SelectedLanIfIndex } else { 0 }
                $dnsCheck = if ($savedState -and $savedState.ManageVpnDns) {
                    Get-DnsState -LanIfIndex $dnsLanIfIndex -VpnIfIndex $routeCheck.VpnIfIndex -ExpectedDnsServers $savedState.DesiredDnsServersIPv4
                } else {
                    [pscustomobject]@{
                        Ok = $true
                        Repairable = $false
                        Reason = 'Gestión DNS desactivada'
                        LanIfIndex = $dnsLanIfIndex
                        VpnIfIndex = $routeCheck.VpnIfIndex
                        ExpectedDnsServers = @()
                    }
                }

                Write-Log "Post-reaplicacion rutas: $($routeCheck.Reason)"
                Write-Log "Post-reaplicacion DNS: $($dnsCheck.Reason)"
                $lastHealth = @(
                    "route=$($routeCheck.Ok)|$($routeCheck.Repairable)|$($routeCheck.Reason)|$($routeCheck.LanIfIndex)|$($routeCheck.LanGateway)|$($routeCheck.VpnIfIndex)|$($routeCheck.LanTotalMetric)|$($routeCheck.VpnTotalMetric)",
                    "dns=$($dnsCheck.Ok)|$($dnsCheck.Repairable)|$($dnsCheck.Reason)|$(Format-StringArray $dnsCheck.ExpectedDnsServers)"
                ) -join ' || '
            }
        } else {
            if ($health -ne $lastHealth) {
                Write-Log "Estado OK: rutas=[$($routeState.Reason)] ; dns=[$($dnsState.Reason)]"
                $lastHealth = $health
            }
        }
    }
    catch {
        Write-Log "ERROR: $($_.Exception.Message)"
    }

    Start-Sleep -Seconds $Interval
}

Write-Log '--- Fin del bucle ---'
Remove-Item -LiteralPath $StopSignalPath -Force -ErrorAction SilentlyContinue
Remove-RuntimeState -Path $RuntimePath -ExpectedPid $PID
