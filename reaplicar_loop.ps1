param(
  [string]$BatPath = 'C:\temp\vpn\FINAL.bat',
  [string]$LogPath = 'C:\temp\vpn\reaplicar.log',
  [string]$StopTime = '16:00',
  [int]$Interval = 3,
  [int]$LogRetentionDays = 7,
  [int]$LanMetric = 25,
  [int]$VpnMetric = 100,
  [int]$LocalLanMetric = 500
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
                } else { $_ }
            } | Set-Content $tmp -Encoding UTF8
            Move-Item -Force $tmp $Path
        }
    } catch {}
}

function Write-Log([string]$Text) {
    Add-Content -Path $LogPath -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Text"
}

function Invoke-RouteCmd([string]$cmd) {
    $p = Start-Process -FilePath 'cmd.exe' -ArgumentList "/c $cmd" -WindowStyle Hidden -PassThru -Wait
    return $p.ExitCode
}

function Get-MaskFromPrefix([int]$PrefixLen) {
    if ($PrefixLen -lt 0 -or $PrefixLen -gt 32) { throw "Prefijo /$PrefixLen no válido" }
    $maskInt = [uint32](([math]::Pow(2, 32) - 1) -bxor ([math]::Pow(2, (32 - $PrefixLen)) - 1))
    $maskBytes = [BitConverter]::GetBytes([uint32]$maskInt)
    [Array]::Reverse($maskBytes)
    return [IPAddress]::new($maskBytes).ToString()
}

function Get-NetworkAddress([string]$IpAddress, [string]$Mask) {
    $ipBytes = ([IPAddress]$IpAddress).GetAddressBytes()
    $maskBytes = ([IPAddress]$Mask).GetAddressBytes()
    $netBytes = for ($i = 0; $i -lt 4; $i++) { $ipBytes[$i] -band $maskBytes[$i] }
    return [IPAddress]::new([byte[]]$netBytes).ToString()
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

    $lanDef = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 -ErrorAction SilentlyContinue |
      Where-Object {
        $_.NextHop -and
        $_.NextHop -ne '0.0.0.0' -and
        $_.InterfaceIndex -ne $vpnIdx
      } |
      Sort-Object RouteMetric |
      Select-Object -First 1

    if (-not $lanDef) {
        return [pscustomobject]@{
            Ok = $false
            Repairable = $false
            Reason = 'No hay ruta LAN por defecto válida'
            VpnIfIndex = $vpnIdx
        }
    }

    $lanCfg = Get-NetIPConfiguration -InterfaceIndex $lanDef.InterfaceIndex -ErrorAction SilentlyContinue
    $lanIpv4 = $lanCfg.IPv4Address | Select-Object -First 1

    if (-not $lanIpv4) {
        return [pscustomobject]@{
            Ok = $false
            Repairable = $false
            Reason = 'No se pudo obtener la IPv4 de la LAN'
            LanIfIndex = $lanDef.InterfaceIndex
            LanGateway = $lanDef.NextHop
            VpnIfIndex = $vpnIdx
        }
    }

    $prefixLen = [int]$lanIpv4.PrefixLength
    $maskLan = Get-MaskFromPrefix $prefixLen
    $network = Get-NetworkAddress -IpAddress $lanIpv4.IPAddress -Mask $maskLan
    $localPrefix = "$network/$prefixLen"

    $vpnDef = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 -ErrorAction SilentlyContinue |
      Where-Object {
        $_.InterfaceIndex -eq $vpnIdx -and
        $_.NextHop -eq '0.0.0.0'
      } |
      Sort-Object RouteMetric |
      Select-Object -First 1

    $lanLocal = Get-NetRoute -DestinationPrefix $localPrefix -AddressFamily IPv4 -ErrorAction SilentlyContinue |
      Where-Object {
        $_.InterfaceIndex -eq $lanDef.InterfaceIndex -and
        $_.NextHop -eq '0.0.0.0'
      } |
      Sort-Object RouteMetric |
      Select-Object -First 1

    $vpnLocal = Get-NetRoute -DestinationPrefix $localPrefix -AddressFamily IPv4 -ErrorAction SilentlyContinue |
      Where-Object {
        $_.InterfaceIndex -eq $vpnIdx -and
        $_.NextHop -eq '0.0.0.0'
      } |
      Sort-Object RouteMetric |
      Select-Object -First 1

    $okLan = ($lanDef.RouteMetric -eq $LanMetric)
    $okVpn = ($vpnDef -and $vpnDef.RouteMetric -eq $VpnMetric)
    $okLanLocal = ($lanLocal -and $lanLocal.RouteMetric -eq $LocalLanMetric)
    $okVpnLocal = (-not $vpnLocal)

    $reason = @(
      "LAN def metric=$($lanDef.RouteMetric)",
      "VPN def metric=$(if($vpnDef){$vpnDef.RouteMetric}else{'ausente'})",
      "LAN local metric=$(if($lanLocal){$lanLocal.RouteMetric}else{'ausente'})",
      "VPN local=$(if($vpnLocal){'presente'}else{'ausente'})"
    ) -join ', '

    return [pscustomobject]@{
        Ok = ($okLan -and $okVpn -and $okLanLocal -and $okVpnLocal)
        Repairable = $true
        Reason = $reason
        LanIfIndex = $lanDef.InterfaceIndex
        LanGateway = $lanDef.NextHop
        VpnIfIndex = $vpnIdx
        LanIp = $lanIpv4.IPAddress
        PrefixLen = $prefixLen
        MaskLan = $maskLan
        LocalNetwork = $network
        LocalPrefix = $localPrefix
        HasVpnRoute = [bool]$vpnDef
        HasVpnLocal = [bool]$vpnLocal
    }
}

function Repair-Routes {
    param(
      [int]$LanIfIndex,
      [string]$LanGateway,
      [int]$VpnIfIndex,
      [string]$LocalNetwork,
      [string]$MaskLan
    )

    $cmds = @(
      "route change 0.0.0.0 mask 0.0.0.0 $LanGateway if $LanIfIndex metric $LanMetric",
      "route change 0.0.0.0 mask 0.0.0.0 0.0.0.0 if $VpnIfIndex metric $VpnMetric",
      "route delete $LocalNetwork mask $MaskLan 0.0.0.0 if $VpnIfIndex",
      "route change $LocalNetwork mask $MaskLan 0.0.0.0 if $LanIfIndex metric $LocalLanMetric"
    )

    foreach ($cmd in $cmds) {
        $rc = Invoke-RouteCmd $cmd
        if ($rc -ne 0) {
            if ($cmd -match '^route change (.+) mask (.+) (.+) if (\d+)(?: metric (\d+))?$') {
                $dest = $Matches[1]
                $mask = $Matches[2]
                $gw = $Matches[3]
                $ifx = $Matches[4]
                $met = $Matches[5]
                $addCmd = "route add $dest mask $mask $gw if $ifx"
                if ($met) { $addCmd += " metric $met" }
                [void](Invoke-RouteCmd $addCmd)
            }
        }
    }
}

$todayStop = [datetime]::Today.Add([timespan]::Parse($StopTime))
if ((Get-Date) -ge $todayStop) { $todayStop = $todayStop.AddDays(1) }

$logDir = Split-Path $LogPath -Parent
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
if (-not (Test-Path $LogPath)) { New-Item -Path $LogPath -ItemType File -Force | Out-Null }
Rotate-Log -Path $LogPath -Days $LogRetentionDays
Write-Log "Script iniciado (PID=$PID, StopTime=$StopTime, Interval=${Interval}s)"

$lastHealth = $null

while ((Get-Date) -lt $todayStop) {
    try {
        $state = Get-RouteState
        $health = "$($state.Ok)|$($state.Repairable)|$($state.Reason)|$($state.LanIfIndex)|$($state.LanGateway)|$($state.VpnIfIndex)|$($state.LocalPrefix)"

        if (-not $state.Ok) {
            if ($state.Repairable -and $state.LanIfIndex -and $state.LanGateway -and $state.VpnIfIndex -and $state.LocalNetwork -and $state.MaskLan) {
                Write-Log "Cambio detectado / estado incorrecto: $($state.Reason). Reaplicando rutas por defecto y ruta local."
                Repair-Routes -LanIfIndex $state.LanIfIndex -LanGateway $state.LanGateway -VpnIfIndex $state.VpnIfIndex -LocalNetwork $state.LocalNetwork -MaskLan $state.MaskLan
                Start-Sleep -Milliseconds 700
                $check = Get-RouteState
                Write-Log "Post-reaplicación: $($check.Reason)"
                $lastHealth = "$($check.Ok)|$($check.Repairable)|$($check.Reason)|$($check.LanIfIndex)|$($check.LanGateway)|$($check.VpnIfIndex)|$($check.LocalPrefix)"
            }
            else {
                if ($health -ne $lastHealth) {
                    Write-Log "Estado no reparable todavía: $($state.Reason)"
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
