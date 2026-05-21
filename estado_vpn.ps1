<#
  estado_vpn.ps1 (fix)
  Muestra si el bucle reaplicar_loop.ps1 está activo, su PID, hora de inicio,
  próxima hora de parada y un resumen/“firma” de las rutas 0.0.0.0 actuales,
  incluyendo la métrica total (ruta + interfaz).
#>

param(
  [string]$LoopPath = 'C:\temp\vpn\reaplicar_loop.ps1',
  [string]$RuntimePath = 'C:\temp\vpn\reaplicar_runtime.json',
  [string]$DefaultStopTime = '16:00'
)

function Get-LoopRuntimeInfo {
    param(
      [string]$RuntimeFile,
      [string]$FallbackLoopPath
    )

    if (Test-Path $RuntimeFile) {
        try {
            $runtime = Get-Content -LiteralPath $RuntimeFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $proc = Get-Process -Id ([int]$runtime.Pid) -ErrorAction SilentlyContinue
            if ($proc) {
                $stopValue = if ($runtime.StopTime) { [string]$runtime.StopTime } else { $DefaultStopTime }
                $startValue = if ($runtime.StartedAt) { [datetime]$runtime.StartedAt } else { $proc.StartTime }
                return [pscustomobject]@{
                    Found       = $true
                    Pid         = [int]$runtime.Pid
                    Start       = $startValue
                    StopTime    = $stopValue
                    Source      = 'runtime'
                    CommandLine = $FallbackLoopPath
                }
            }
        } catch {}
    }

    try {
        $procs = Get-WmiObject Win32_Process -ErrorAction Stop |
          Where-Object { $_.CommandLine -match [Regex]::Escape($FallbackLoopPath) }

        if ($procs) {
            $proc = $procs | Sort-Object CreationDate -Descending | Select-Object -First 1
            $stopMatch = [regex]::Match($proc.CommandLine, '-StopTime\s+"?([0-9]{1,2}:[0-9]{2})"?')
            $stopValue = if ($stopMatch.Success) { $stopMatch.Groups[1].Value } else { $DefaultStopTime }

            return [pscustomobject]@{
                Found       = $true
                Pid         = [int]$proc.ProcessId
                Start       = ([Management.ManagementDateTimeConverter]::ToDateTime($proc.CreationDate))
                StopTime    = $stopValue
                Source      = 'wmi'
                CommandLine = $proc.CommandLine
            }
        }
    } catch {}

    return [pscustomobject]@{
        Found    = $false
        Pid      = 0
        Start    = $null
        StopTime = $DefaultStopTime
        Source   = 'none'
    }
}

# 1) ¿Está corriendo el bucle?
$loopInfo = Get-LoopRuntimeInfo -RuntimeFile $RuntimePath -FallbackLoopPath $LoopPath

if ($loopInfo.Found) {
    $loopPid = $loopInfo.Pid
    $start   = $loopInfo.Start

    $todayStop = [datetime]::Today.Add([timespan]::Parse($loopInfo.StopTime))
    if ((Get-Date) -ge $todayStop) { $todayStop = $todayStop.AddDays(1) }

    Write-Host "Estado:    ACTIVO ✅" -ForegroundColor Green
    Write-Host "PID:       $loopPid"
    Write-Host "Inicio:    $($start.ToString('yyyy-MM-dd HH:mm:ss'))"
    Write-Host "Se parará: $($todayStop.ToString('yyyy-MM-dd HH:mm:ss'))"
} else {
    Write-Host "Estado:    PARADO ⛔" -ForegroundColor Yellow
    Write-Host "PID:       -"
    Write-Host "Inicio:    -"
    Write-Host "Se parará: - (no hay bucle activo; por defecto $DefaultStopTime hoy)"
}

Write-Host ""

# 2) Resumen de la ruta por defecto (0.0.0.0), firma y métricas totales
try {
    $lines = route print | Select-String "^\s*0\.0\.0\.0"
    $text  = ($lines | ForEach-Object { $_.ToString().Trim() }) -join "`n"

    if (-not $text) {
        Write-Host "Ruta 0.0.0.0: NO PRESENTE ❌"
    } else {
        # Firma SHA1
        $sha1 = New-Object Security.Cryptography.SHA1Managed
        $hash = [BitConverter]::ToString($sha1.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))

        Write-Host "Ruta 0.0.0.0 (resumen actual):"
        $lines | ForEach-Object { "  " + $_.ToString().Trim() } | Write-Host
        Write-Host "Firma: $hash"

        # Métricas totales con cmdlets (ruta + interfaz)
        try {
            $defRoutes = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction Stop
            $lanRoute  = $defRoutes | Where-Object { $_.NextHop -and $_.NextHop -ne '0.0.0.0' } | Sort-Object RouteMetric | Select-Object -First 1
            $vpnRoute  = $defRoutes | Where-Object { $_.NextHop -eq '0.0.0.0' } | Sort-Object RouteMetric | Select-Object -First 1

            if ($lanRoute) {
                $lanIfaceMetric = (Get-NetIPInterface -InterfaceIndex $lanRoute.ifIndex -AddressFamily IPv4).InterfaceMetric
                $lanTotal = $lanRoute.RouteMetric + $lanIfaceMetric
                Write-Host ("Métrica total LAN : {0} (ruta {1} + interfaz {2})" -f $lanTotal, $lanRoute.RouteMetric, $lanIfaceMetric)
            }
            if ($vpnRoute) {
                $vpnIfaceMetric = (Get-NetIPInterface -InterfaceIndex $vpnRoute.ifIndex -AddressFamily IPv4).InterfaceMetric
                $vpnTotal = $vpnRoute.RouteMetric + $vpnIfaceMetric
                Write-Host ("Métrica total VPN : {0} (ruta {1} + interfaz {2})" -f $vpnTotal, $vpnRoute.RouteMetric, $vpnIfaceMetric)
            }

            if ($lanRoute) {
                Write-Host "Estado ruta por defecto: OK ✅ (hay gateway real)" -ForegroundColor Green
            } else {
                Write-Host "Estado ruta por defecto: NO VÁLIDA ❌ (solo on-link / En vínculo)" -ForegroundColor Red
            }
        } catch {
            Write-Host "No se pudo obtener el estado detallado de métricas: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
} catch {
    Write-Host "No se pudo leer la tabla de rutas: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host ""
Write-Host "Log: C:\temp\vpn\reaplicar.log (solo registra cuando hay cambios/reaplicación)"
