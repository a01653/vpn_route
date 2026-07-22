# ================================
#  C:\temp\vpn\FINAL.ps1
# ================================


# Las rutas requieren privilegios de administrador. Sin esta comprobacion el
# .bat y el bucle posterior fallaban silenciosamente con "requiere elevacion".
$principal = [Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdministrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdministrator) {
    Write-Host 'Solicitando permisos de administrador para aplicar las rutas VPN...' -ForegroundColor Yellow
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    Start-Process -FilePath (Get-Command powershell.exe).Source -Verb RunAs -ArgumentList $arguments
    exit
}

# --- Utilidades ---
function Get-MaskFromPrefix($prefixLen) {
    $p = [int]$prefixLen
    if ($p -lt 0 -or $p -gt 32) { throw "Prefijo /$prefixLen no válido" }
    # Calcula la máscara como uint32 y la convierte a IPv4
    $maskInt = [uint32](([math]::Pow(2, 32) - 1) -bxor ([math]::Pow(2, (32 - $p)) - 1))
    $maskBytes = [BitConverter]::GetBytes([uint32]$maskInt)
    [Array]::Reverse($maskBytes)
    return [IPAddress]::new($maskBytes).ToString()
}

function Get-Ipv4DnsServers {
    param([int]$InterfaceIndex)

    try {
        return @(
            (Get-DnsClientServerAddress -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop).ServerAddresses |
            Where-Object { $_ }
        )
    } catch {
        return @()
    }
}

function Save-ReapplyState {
    param(
      [string]$Path,
      [int]$LanIfIndex,
      [string]$LanName,
      [string[]]$DesiredDnsServersIPv4,
      [bool]$ManageVpnDns = $false
    )

    $payload = [pscustomobject]@{
        SavedAt               = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        SelectedLanIfIndex    = $LanIfIndex
        SelectedLanName       = $LanName
        ManageVpnDns          = $ManageVpnDns
        DesiredDnsServersIPv4 = @($DesiredDnsServersIPv4)
    }

    $payload | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Set-Ipv4DnsServers {
    param(
      [int[]]$InterfaceIndexes,
      [string[]]$DnsServers
    )

    $targets = @($InterfaceIndexes | Where-Object { $_ } | Sort-Object -Unique)
    $desired = @($DnsServers | Where-Object { $_ })

    if (-not $targets) {
        return
    }

    if (-not $desired) {
        Write-Host "DNS de referencia no detectados. No se fuerzan DNS en la VPN." -ForegroundColor Yellow
        return
    }

    foreach ($ifIndex in $targets) {
        $current = Get-Ipv4DnsServers -InterfaceIndex $ifIndex
        if ((@($current) -join ',') -eq (@($desired) -join ',')) {
            Write-Host "DNS ya correctos en if=$ifIndex -> $($desired -join ', ')" -ForegroundColor DarkGray
            continue
        }

        try {
            Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses $desired -ErrorAction Stop
            Write-Host "DNS aplicados en if=$ifIndex -> $($desired -join ', ')" -ForegroundColor Cyan
        } catch {
            Write-Host "No se pudieron aplicar DNS en if=${ifIndex}: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

# --- Ruta y nombres del script / bat ---
$psScriptPath = $PSCommandPath
$psScriptName = [System.IO.Path]::GetFileNameWithoutExtension($psScriptPath)
$psScriptDir  = [System.IO.Path]::GetDirectoryName($psScriptPath)

$batFilePath  = "$psScriptDir\$psScriptName.bat"
$stateFilePath = Join-Path $psScriptDir 'reaplicar_state.json'


# Crear o LIMPIAR el .bat sin dejarlo abierto
if (Test-Path $batFilePath) {
   Remove-Item -Path $batFilePath -Force -ErrorAction SilentlyContinue
#   Clear-Content -Path $batFilePath -ErrorAction SilentlyContinue
} else {
    New-Item -Path $batFilePath -ItemType File -Force | Out-Null
}


# --- 1) Detectar interfaz VPN (PANGP) y salir si no está ---
$vpn = Get-NetAdapter |
  Where-Object { $_.InterfaceDescription -like '*PANGP*' -and $_.Status -eq 'Up' } |
  Select-Object -First 1

if (-not $vpn) {
    Write-Host "VPN PANGP no conectada. Salgo sin cambios." -ForegroundColor Yellow
    return
}

$vpnIdx = $vpn.IfIndex
$vpnIP  = (Get-NetIPAddress -InterfaceIndex $vpnIdx -AddressFamily IPv4).IPAddress
Write-Host "VPN -> idx=$vpnIdx, IP=$vpnIP" -ForegroundColor Green

# --- 2) Listar LAN/WiFi activas y seleccionar ---
$ifs = Get-NetAdapter | Where-Object Status -eq 'Up' | ForEach-Object {
    $cfg = Get-NetIPConfiguration -InterfaceIndex $_.IfIndex
	if (
		$_.IfIndex -ne $vpnIdx -and
		$cfg.IPv4Address -and
		$cfg.IPv4DefaultGateway -and
		$cfg.IPv4DefaultGateway.NextHop -ne '0.0.0.0'
	) {
        [pscustomobject]@{
            Idx      = $_.IfIndex
            Name     = $_.Name
            IPv4     = $cfg.IPv4Address.IPAddress
            Gateway  = $cfg.IPv4DefaultGateway.NextHop
        }
    }
}
Write-Host "`nLAN/WiFi activas:" -ForegroundColor Cyan
$ifs | Format-Table

if (-not $ifs) {
    Write-Error "No se encontró ninguna LAN/WiFi válida."
    exit 1
} elseif ($ifs.Count -eq 1) {
    $lanIdx = [int]$ifs[0].Idx
    Write-Host "`nSolo hay una LAN/WiFi válida. Seleccionada automáticamente: $lanIdx" -ForegroundColor Yellow
} else {
    [int]$lanIdx = Read-Host "`nElige índice de la LAN/WiFi"
}

$lan = $ifs | Where-Object Idx -eq $lanIdx
if (-not $lan) {
    Write-Error "Índice LAN inválido: $lanIdx"
    exit 1
}


$lanIP = $lan.IPv4
$lanGW = $lan.Gateway
Write-Host "LAN -> idx=$lanIdx, IP=$lanIP, Gateway=$lanGW" -ForegroundColor Green

$manageVpnDns = $false
$desiredDnsServers = Get-Ipv4DnsServers -InterfaceIndex $lanIdx
if ($desiredDnsServers) {
    Write-Host "DNS LAN de referencia -> $($desiredDnsServers -join ', ')" -ForegroundColor Green
} else {
    Write-Host "DNS LAN de referencia -> no detectados" -ForegroundColor Yellow
}

Save-ReapplyState -Path $stateFilePath -LanIfIndex $lanIdx -LanName $lan.Name -DesiredDnsServersIPv4 $desiredDnsServers -ManageVpnDns $manageVpnDns
if ($manageVpnDns) {
    Set-Ipv4DnsServers -InterfaceIndexes @($vpnIdx) -DnsServers $desiredDnsServers
} else {
    Write-Host "Gestión de DNS VPN desactivada. Se conservan solo las rutas." -ForegroundColor Yellow
}

# --- 3) Helper para emitir add/change en el .bat ---
function EmitRoute {
    param(
      [string]$Prefix,   # ej: "10.0.0.0/16" o "0.0.0.0/0"
      [int]   $IfIndex,
      [string]$Gateway,
      [int]   $Metric = $null
    )

    # Determinar máscara universal a partir de /n
    $cidr = [int]($Prefix.Split('/')[-1])
    if ($cidr -lt 0 -or $cidr -gt 32) { throw "Máscara /$cidr no válida" }
    $mask = Get-MaskFromPrefix $cidr

    $dest = $Prefix.Split('/')[0]

    # Comprobar existencia de la ruta en esa interfaz
    $prefixRoute = "$dest/$cidr"
    $exists = Get-NetRoute -DestinationPrefix $prefixRoute -InterfaceIndex $IfIndex -ErrorAction SilentlyContinue

    if ($exists) {
      $cmd = "route change $dest mask $mask $Gateway if $IfIndex"
      if ($Metric) { $cmd += " metric $Metric" }
    } else {
      $cmd = "route add    $dest mask $mask $Gateway if $IfIndex"
      if ($Metric) { $cmd += " metric $Metric" }
    }

    # Mostrar y escribir en el .bat
    Write-Host $cmd
    Add-Content -Path $batFilePath -Value $cmd
}

Write-Host "`n--- COMANDOS ROUTE ---" -ForegroundColor Yellow

# --- 3.1) Ruta por defecto vía LAN (métrica 25) ---
EmitRoute -Prefix "0.0.0.0/0" -IfIndex $lanIdx -Gateway $lanGW -Metric 25

# --- 3.2) Ruta por defecto on-link via VPN (métrica 100) ---
EmitRoute -Prefix "0.0.0.0/0" -IfIndex $vpnIdx -Gateway "0.0.0.0" -Metric 100

# --- 3.3) Rutas internas via VPN ---
"10.136.0.0/16","172.28.0.0/16","10.143.0.0/16","10.142.0.0/16","10.141.0.0/16","10.140.0.0/16" |
    ForEach-Object { EmitRoute -Prefix $_ -IfIndex $vpnIdx -Gateway "0.0.0.0" }

# --------------------------------------------------
# 3.4) Eliminar la ruta LAN (red local) “On-link” en la VPN
# --------------------------------------------------
$lanCfg    = Get-NetIPConfiguration -InterfaceIndex $lanIdx
$prefixLen = $lanCfg.IPv4Address.PrefixLength
$maskLAN   = Get-MaskFromPrefix $prefixLen

# Calcular dirección de red de la LAN (IP AND máscara)
$ipBytes   = ([IPAddress]$lanIP).GetAddressBytes()
$maskBytes = ([IPAddress]$maskLAN).GetAddressBytes()
$netBytes  = for ($i = 0; $i -lt 4; $i++) { $ipBytes[$i] -band $maskBytes[$i] }
$network   = [IPAddress]::new([byte[]]$netBytes).ToString()

Write-Host "`n-- Eliminar ruta LAN local de la VPN --" -ForegroundColor Cyan
$cmdDel = "route delete $network mask $maskLAN 0.0.0.0 if $vpnIdx"
Write-Host $cmdDel
Add-Content -Path $batFilePath -Value $cmdDel

# --------------------------------------------------
# 3.5) Red local calculada via LAN (métrica 500)
# --------------------------------------------------
Write-Host "`n-- Cambia la ruta local --" -ForegroundColor Cyan
EmitRoute -Prefix "$network/$prefixLen" -IfIndex $lanIdx -Gateway "0.0.0.0" -Metric 500

# ===================================================
# 4) EJECUTAR FINAL.BAT DIRECTAMENTE (rutas iniciales)
# ===================================================
try {
    Write-Host "`nAplicando rutas iniciales (ejecutando FINAL.bat)..." -ForegroundColor Cyan
    $p = Start-Process -FilePath "cmd.exe" `
        -ArgumentList "/c `"$batFilePath auto`"" `
        -WindowStyle Hidden -PassThru -Wait
    if ($p.ExitCode -eq 0) {
        Write-Host "FINAL.bat ejecutado correctamente. Rutas iniciales aplicadas." -ForegroundColor Green
    } else {
        Write-Host "⚠️ FINAL.bat devolvió ExitCode=$($p.ExitCode). Revisa las rutas." -ForegroundColor Yellow
    }
} catch {
    Write-Host "ERROR ejecutando FINAL.bat: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host "`n--- FIN ---" -ForegroundColor Yellow

# ===================================================
# 5) Lanzar bucle reaplicar_loop.ps1 sólo si no está activo
# ===================================================
$loopScript = 'C:\temp\vpn\reaplicar_loop.ps1'
if (-not (Test-Path $loopScript)) {
    Write-Host "ERROR: No se encuentra $loopScript. No se puede iniciar el bucle." -ForegroundColor Red
    exit 1
}

$running = Get-WmiObject Win32_Process | Where-Object { $_.CommandLine -match 'reaplicar_loop.ps1' }

if ($running) {
    Write-Host "Ya había un proceso de reaplicación. Lo reinicio." -ForegroundColor Yellow
    $running | ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "Iniciando bucle de reaplicación en segundo plano..." -ForegroundColor Cyan
$psExe = (Get-Command powershell).Source
$pLoop = Start-Process -FilePath $psExe `
    -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-File",$loopScript,"-StopTime","16:00","-StatePath",$stateFilePath `
    -WorkingDirectory (Split-Path $loopScript -Parent) `
    -WindowStyle Hidden `
    -PassThru

Start-Sleep -Seconds 2

if (Get-Process -Id $pLoop.Id -ErrorAction SilentlyContinue) {
    Write-Host "Bucle lanzado correctamente. PID=$($pLoop.Id)" -ForegroundColor Green
} else {
    Write-Host "ERROR: el proceso del bucle arrancó y murió al instante." -ForegroundColor Red
    Write-Host "Prueba manual: powershell -NoProfile -ExecutionPolicy Bypass -File $loopScript -StopTime 16:00 -StatePath $stateFilePath" -ForegroundColor Yellow
}

Write-Host "`nEl script ha terminado. El bucle de reaplicación se detendrá automáticamente a las 16:00." -ForegroundColor Yellow
