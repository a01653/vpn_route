$detenerScript = Join-Path $PSScriptRoot 'detener_loop.ps1'

if (-not (Test-Path $detenerScript)) {
    Write-Host "No se encuentra $detenerScript" -ForegroundColor Red
    exit 1
}

& $detenerScript
