<#
.SYNOPSIS
  Lista los Roku disponibles para probar: los descubre en la LAN (SSDP) y los cruza con el
  inventario devices.json.

.DESCRIPTION
  Para cada equipo consulta por ECP (sin contraseña): modelo, firmware, dev mode, de quién es la
  llave cargada (según signing-keys.json), qué canal está activo y si la consola 8085 está libre.

  Por qué consultar y no confiar en la documentación: las IPs cambian por DHCP y los modelos
  anotados a mano estaban mal (el .186 figuraba como Ultra y es un Express 3960X).

  Los Roku de Suitest (remotos) no se ven desde acá: se refrescan pidiéndole a Claude que corra
  suitest_list_devices (MCP de Suitest) y actualice la sección "suitest" de devices.json.

.EXAMPLE
  pwsh roku-devices.ps1              # descubre + inventario, sin escribir nada
  pwsh roku-devices.ps1 -Save        # además actualiza devices.json (lastSeen, modelo, firmware...)
  pwsh roku-devices.ps1 -NoDiscover  # solo los del inventario
#>
param(
    [switch]$Save,
    [switch]$NoDiscover,
    [int]$DiscoverSeconds = 4
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RokuDev.psm1') -Force
$inventoryPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'devices.json'

# SSDP: M-SEARCH por roku:ecp. Cada Roku responde con LOCATION: http://<ip>:8060/
function Find-RokuOnLan([int]$Seconds) {
    $found = [System.Collections.Generic.HashSet[string]]::new()
    $udp = [System.Net.Sockets.UdpClient]::new(0)
    try {
        $udp.Client.ReceiveTimeout = 500
        $msg = [Text.Encoding]::ASCII.GetBytes("M-SEARCH * HTTP/1.1`r`nHost: 239.255.255.250:1900`r`nMan: `"ssdp:discover`"`r`nST: roku:ecp`r`nMX: 2`r`n`r`n")
        $ep = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Parse('239.255.255.250'), 1900)
        1..2 | ForEach-Object { [void]$udp.Send($msg, $msg.Length, $ep) }
        $deadline = (Get-Date).AddSeconds($Seconds)
        while ((Get-Date) -lt $deadline) {
            try {
                $remote = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
                $text = [Text.Encoding]::ASCII.GetString($udp.Receive([ref]$remote))
                if ($text -match '(?im)^LOCATION:\s*http://([\d.]+):8060') { [void]$found.Add($Matches[1]) }
            } catch [System.Net.Sockets.SocketException] { }
        }
    } finally { $udp.Close() }
    return $found
}

function Test-ConsoleFree([string]$Ip) {
    $c = [System.Net.Sockets.TcpClient]::new()
    try {
        if (-not $c.ConnectAsync($Ip, 8085).Wait(1500)) { return 'sin respuesta' }
        $s = $c.GetStream(); $s.ReadTimeout = 1200
        $buf = New-Object byte[] 256
        $deadline = (Get-Date).AddMilliseconds(1200); $text = ''
        while ((Get-Date) -lt $deadline -and $text.Length -lt 60) {
            if ($s.DataAvailable) { $n = $s.Read($buf, 0, $buf.Length); $text += [Text.Encoding]::ASCII.GetString($buf, 0, $n) }
            else { Start-Sleep -Milliseconds 100 }
        }
        if ($text -match 'already in use') { 'OCUPADA' } else { 'libre' }
    } catch { 'sin respuesta' } finally { $c.Close() }
}

$inventory = if (Test-Path $inventoryPath) { Get-Content $inventoryPath -Raw | ConvertFrom-Json } else { [pscustomobject]@{ local = @(); suitest = @() } }
$ips = [System.Collections.Generic.List[string]]::new()
foreach ($d in $inventory.local) { if ($d.ip -and -not $ips.Contains($d.ip)) { $ips.Add($d.ip) } }
$discovered = @()
if (-not $NoDiscover) {
    Write-Host "==> Buscando Roku en la LAN (SSDP, ${DiscoverSeconds}s)..." -ForegroundColor Cyan
    $discovered = @(Find-RokuOnLan $DiscoverSeconds)
    foreach ($ip in $discovered) { if (-not $ips.Contains($ip)) { $ips.Add($ip) } }
    Write-Host "    respondieron: $(if ($discovered) { $discovered -join ', ' } else { 'ninguno' })"
}

$rows = foreach ($ip in $ips) {
    $known = $inventory.local | Where-Object ip -eq $ip | Select-Object -First 1
    try {
        $i = Get-RokuDeviceInfo $ip -TimeoutSec 4
        $app = try { $a = (Invoke-RestMethod "http://${ip}:8060/query/active-app" -TimeoutSec 4).'active-app'.app; if ($a.id -eq 'dev') { "dev: $($a.'#text') v$($a.version)" } else { [string]$a.'#text' } } catch { '?' }
        [pscustomobject]@{
            IP = $ip; Estado = 'online'; Nombre = $i.Name; Modelo = "$($i.Model) ($($i.ModelNumber))"; Firmware = $i.Firmware
            DevMode = $i.DevMode; Llave = $(if ($i.KeyOwner) { $i.KeyOwner } elseif ($i.DevId) { "desconocida $($i.DevId.Substring(0,8))" } else { 'sin llave' })
            AppActiva = $app; Consola = Test-ConsoleFree $ip; Uso = $known.purpose
            _info = $i
        }
    } catch {
        [pscustomobject]@{ IP = $ip; Estado = 'OFFLINE'; Nombre = $known.name; Modelo = $known.model; Firmware = $known.firmware
            DevMode = $null; Llave = $known.keyOwner; AppActiva = ''; Consola = ''; Uso = $known.purpose; _info = $null }
    }
}

$rows | Select-Object IP, Estado, Modelo, Firmware, DevMode, Llave, AppActiva, Consola | Format-Table -AutoSize
$rows | Where-Object Uso | ForEach-Object { Write-Host ("    {0,-14} {1}" -f $_.IP, $_.Uso) -ForegroundColor DarkGray }
Write-Host ''
if ($inventory.suitest) {
    Write-Host '==> Suitest (último refresh: ' -NoNewline -ForegroundColor Cyan
    Write-Host "$($inventory.suitestRefreshed))" -ForegroundColor Cyan
    $inventory.suitest | Select-Object name, model, firmware, owner, status, ipAddress | Format-Table -AutoSize
}

if ($Save) {
    $now = (Get-Date).ToString('yyyy-MM-dd HH:mm')
    $local = foreach ($r in $rows) {
        $prev = $inventory.local | Where-Object ip -eq $r.IP | Select-Object -First 1
        $i = $r._info
        [ordered]@{
            ip       = $r.IP
            name     = if ($i) { $i.Name } else { $prev.name }
            model    = if ($i) { "$($i.Model) ($($i.ModelNumber))" } else { $prev.model }
            firmware = if ($i) { $i.Firmware } else { $prev.firmware }
            serial   = if ($i) { $i.Serial } else { $prev.serial }
            devMode  = if ($i) { $i.DevMode } else { $prev.devMode }
            keyOwner = if ($i) { $r.Llave } else { $prev.keyOwner }
            purpose  = $prev.purpose
            status   = $r.Estado
            lastSeen = if ($i) { $now } else { $prev.lastSeen }
        }
    }
    $inventory.local = @($local)
    $inventory | ConvertTo-Json -Depth 5 | Set-Content $inventoryPath -Encoding utf8
    Write-Host "==> devices.json actualizado ($($local.Count) locales)" -ForegroundColor Cyan
}
