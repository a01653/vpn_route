<#
  Script: detener_vpn.ps1
  Autor: J. Querol
  Función:
    - Detiene cualquier proceso PowerShell que esté ejecutando reaplicar_loop.ps1
    - Registra la detención en reaplicar.log
#>

$loopScript = 'C:\temp\vpn\reaplicar_loop.ps1'
$logPath    = 'C:\temp\vpn\reaplicar.log'

# Buscar procesos que estén ejecutando el bucle
$running = Get-WmiObject Win32_Process | Where-Object { $_.CommandLine -match [Regex]::Escape($loopScript) }

if ($running) {
    Write-Host "Deteniendo procesos activos de reaplicar_loop.ps1..." -ForegroundColor Yellow
    foreach ($p in $running) {
        try {
            Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
            $msg = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Proceso $($p.ProcessId) detenido manualmente."
            Add-Content -Path $logPath -Value $msg
        } catch {
            Write-Host "Error al detener proceso $($p.ProcessId): $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    Write-Host "✅ Bucle de reaplicación detenido correctamente." -ForegroundColor Green
} else {
    Write-Host "No hay ningún proceso activo de reaplicar_loop.ps1." -ForegroundColor Cyan
}
