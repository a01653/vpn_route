param(
  [string]$LogPath = 'C:\temp\vpn\reaplicar.log',
  [string]$StopTime = '16:00',
  [int]$Interval = 3,
  [int]$LogRetentionDays = 7,
  [int]$LanRouteMetric = 25,
  [int]$VpnRouteMetric = 100
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

function Invoke-RouteCmd([string]$Cmd) {
    $p = Start-Process -FilePath 'cmd.exe' -ArgumentList "/c $Cmd" -WindowStyle Hidden -PassThru -Wait
    return $p.ExitCode
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

    $reason = @(
      "LAN if=$($lanDef.InterfaceIndex)",
      "LAN nextHop=$($lanDef.NextHop)",
      "LAN metric=$lanRouteMetric+$lanIfMetric=$lanTotalMetric",
      "VPN if=$vpnIdx",
      "VPN metric=$(if($vpnDef){"$vpnRouteMetric+$vpnIfMetric=$vpnTotalMetric"}else{'ausente'})"
    ) -join ', '

    return [pscustomobject]@{
        Ok = ($okLan -and $okVpn -and $okPriority)
        Repairable = $true
        Reason = $reason
        LanIfIndex = $lanDef.InterfaceIndex
        LanGateway = $lanDef.NextHop
        VpnIfIndex = $vpnIdx
        LanTotalMetric = $lanTotalMetric
        VpnTotalMetric = $vpnTotalMetric
    }
}

function Repair-Routes {
    param(
      [int]$LanIfIndex,
      [string]$LanGateway,
      [int]$VpnIfIndex
    )

    $cmds = @(
      "route change 0.0.0.0 mask 0.0.0.0 $LanGateway if $LanIfIndex metric $LanRouteMetric",
      "route change 0.0.0.0 mask 0.0.0.0 0.0.0.0 if $VpnIfIndex metric $VpnRouteMetric"
    )

    foreach ($cmd in $cmds) {
        $rc = Invoke-RouteCmd $cmd
        if ($rc -ne 0) {
            if ($cmd -match '^route change (.+) mask (.+) (.+) if (\d+)(?: metric (\d+))?$') {
                $dest = $Matches[1]
                $mask = $Matches[2]
                $gw   = $Matches[3]
                $ifx  = $Matches[4]
                $met  = $Matches[5]

                $addCmd = "route add $dest mask $mask $gw if $ifx"
                if ($met) { $addCmd += " metric $met" }
                [void](Invoke-RouteCmd $addCmd)
            }
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
Write-Log "Script iniciado (PID=$PID, StopTime=$StopTime, Interval=${Interval}s)"

$lastHealth = $null

while ((Get-Date) -lt $todayStop) {
    try {
        $state = Get-RouteState
        $health = "$($state.Ok)|$($state.Repairable)|$($state.Reason)|$($state.LanIfIndex)|$($state.LanGateway)|$($state.VpnIfIndex)|$($state.LanTotalMetric)|$($state.VpnTotalMetric)"

        if (-not $state.Ok) {
            if ($state.Repairable -and $state.LanIfIndex -and $state.LanGateway -and $state.VpnIfIndex) {
                Write-Log "Cambio detectado / estado incorrecto: $($state.Reason). Reaplicando rutas por defecto."
                Repair-Routes -LanIfIndex $state.LanIfIndex -LanGateway $state.LanGateway -VpnIfIndex $state.VpnIfIndex
                Start-Sleep -Milliseconds 700
                $check = Get-RouteState
                Write-Log "Post-reaplicacion: $($check.Reason)"
                $lastHealth = "$($check.Ok)|$($check.Repairable)|$($check.Reason)|$($check.LanIfIndex)|$($check.LanGateway)|$($check.VpnIfIndex)|$($check.LanTotalMetric)|$($check.VpnTotalMetric)"
            }
            else {
                if ($health -ne $lastHealth) {
                    Write-Log "Estado no reparable todavia: $($state.Reason)"
                    $lastHealth = $health
                }
            }
        }
        else {
            if ($health -ne $lastHealth) {
                Write-Log "Estado OK: $($state.Reason)"
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
