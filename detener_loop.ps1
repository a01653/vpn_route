<#
  Script: detener_vpn.ps1
  Autor: J. Querol
  Función:
    - Detiene cualquier proceso PowerShell que esté ejecutando reaplicar_loop.ps1
    - Registra la detención en reaplicar.log
#>

param(
  [string]$LoopScript = 'C:\temp\vpn\reaplicar_loop.ps1',
  [string]$LogPath = 'C:\temp\vpn\reaplicar.log',
  [string]$RuntimePath = 'C:\temp\vpn\reaplicar_runtime.json',
  [string]$StopSignalPath = 'C:\temp\vpn\reaplicar_loop.stop'
)

function Write-StopLog([string]$Text) {
    Add-Content -Path $LogPath -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Text"
}

function Get-LoopPidFromRuntime {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return 0
    }

    try {
        $runtime = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        return [int]$runtime.Pid
    } catch {
        return 0
    }
}

function Request-LoopStop {
    param([string]$Path)

    Set-Content -LiteralPath $Path -Value 'stop' -Encoding ASCII
}

$runtimePid = Get-LoopPidFromRuntime -Path $RuntimePath
$runtimeProc = if ($runtimePid) { Get-Process -Id $runtimePid -ErrorAction SilentlyContinue } else { $null }

if ($runtimeProc) {
    Write-Host "Solicitando parada de reaplicar_loop.ps1..." -ForegroundColor Yellow
    Request-LoopStop -Path $StopSignalPath

    $stopped = $false
    for ($i = 0; $i -lt 8; $i++) {
        Start-Sleep -Milliseconds 500
        if (-not (Get-Process -Id $runtimePid -ErrorAction SilentlyContinue)) {
            $stopped = $true
            break
        }
    }

    if (-not $stopped) {
        try {
            Stop-Process -Id $runtimePid -Force -ErrorAction Stop
            $stopped = $true
        } catch {
            Write-Host "No se pudo forzar el cierre del proceso ${runtimePid}: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    if ($stopped) {
        Write-StopLog "Proceso $runtimePid detenido manualmente."
        Remove-Item -LiteralPath $RuntimePath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $StopSignalPath -Force -ErrorAction SilentlyContinue
        Write-Host "✅ Bucle de reaplicación detenido correctamente." -ForegroundColor Green
    } else {
        Write-Host "Señal enviada, pero el proceso sigue activo. Ejecuta este script como administrador si necesitas forzar el cierre." -ForegroundColor Yellow
    }
}
else {
    $running = $null
    try {
        $running = Get-WmiObject Win32_Process -ErrorAction Stop |
          Where-Object { $_.CommandLine -match [Regex]::Escape($LoopScript) }
    } catch {}

    if ($running) {
        Write-Host "Deteniendo procesos activos de reaplicar_loop.ps1..." -ForegroundColor Yellow
        foreach ($p in $running) {
            try {
                Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
                Write-StopLog "Proceso $($p.ProcessId) detenido manualmente."
            } catch {
                Write-Host "Error al detener proceso $($p.ProcessId): $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        Remove-Item -LiteralPath $RuntimePath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $StopSignalPath -Force -ErrorAction SilentlyContinue
        Write-Host "✅ Bucle de reaplicación detenido correctamente." -ForegroundColor Green
    } else {
        Write-Host "No hay ningún proceso activo de reaplicar_loop.ps1." -ForegroundColor Cyan
    }
}
