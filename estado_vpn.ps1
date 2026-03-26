<#
  estado_vpn.ps1 (fix)
  Muestra si el bucle reaplicar_loop.ps1 está activo, su PID, hora de inicio,
  próxima hora de parada y un resumen/“firma” de las rutas 0.0.0.0 actuales,
  incluyendo la métrica total (ruta + interfaz).
#>

param(
  [string]$LoopPath = 'C:\temp\vpn\reaplicar_loop.ps1',
  [string]$DefaultStopTime = '16:00'
)

# 1) ¿Está corriendo el bucle?
$procs = Get-WmiObject Win32_Process | Where-Object { $_.CommandLine -match [Regex]::Escape($LoopPath) }

if ($procs) {
    $proc = $procs | Sort-Object CreationDate -Descending | Select-Object -First 1
    $loopPid = [int]$proc.ProcessId
    $start   = ([Management.ManagementDateTimeConverter]::ToDateTime($proc.CreationDate))

    $stopMatch = [regex]::Match($proc.CommandLine, '-StopTime\s+"?([0-9]{1,2}:[0-9]{2})"?')
    $stopStr   = $(if ($stopMatch.Success) { $stopMatch.Groups[1].Value } else { $DefaultStopTime })

    $todayStop = [datetime]::Today.Add([timespan]::Parse($stopStr))
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
            $defRoutes = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue
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
            Write-Host "No se pudieron obtener métricas: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
} catch {
    Write-Host "No se pudo leer la tabla de rutas: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host ""
Write-Host "Log: C:\temp\vpn\reaplicar.log (solo registra cuando hay cambios/reaplicación)"
