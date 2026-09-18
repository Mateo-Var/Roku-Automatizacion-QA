<#
  Funciones comunes de los tests en device: test-deeplink.ps1, test-nav-perf.ps1 y catalog.ps1.

  Tres ideas que atraviesan todo el módulo:

  - RELOJ DEL DEVICE. Los tiempos se miden con los timestamps del propio Roku, no con el reloj
    de la PC. Las líneas de sistema de la consola ("09-11 14:35:56.010 sdkl [beacon.signal] ...")
    traen hora del device con milisegundos; los print de BrightScript no. Para esos se estima la
    hora del device como  hora_de_lectura - offset,  con offset = mínimo de
    (hora_de_lectura - hora_device) sobre las líneas de sistema: la línea que llegó más rápido
    fija la relación entre los dos relojes. Así un WiFi lento no infla las mediciones.

  - RED. Cada llamada ECP mide su RTT y cuenta reintentos. Si la red se degradó durante un caso
    (timeouts, RTT alto, la app reportó caída de internet), el caso sale INVALIDO: un resultado
    medido sobre una red rota no dice nada de la app.

  - UI POR NOMBRE. El estado de pantalla sale de ECP query/app-ui (árbol SceneGraph): página
    visible, cadena de foco, fila enfocada del Home y títulos de filas, toast, diálogos. Se navega
    buscando una fila o un ítem de menú por su título, no contando teclas a ciegas.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RokuDev.psm1') -Force

$script:Capturer  = Join-Path $PSScriptRoot 'roku-console-capture.ps1'
$script:ClientsDir = Join-Path $PSScriptRoot '..\scenarios\clients'
$script:Inv       = [Globalization.CultureInfo]::InvariantCulture
$script:RxCrash   = 'BrightScript Micro Debugger|Brightscript Debugger>|\(runtime error &h'
# Señales de que la app detectó problemas de conexión. El Core solo re-chequea internet
# (checkPeriodicConnectionStatus) después de detectar una caída.
$script:RxNetDrop = 'Internet : status false|handleConnectionDropped : dropped true|checkPeriodicConnectionStatus|onConnectionChange'
# Llamadas livianas: su RTT refleja la red. app-ui, sgnodes, r2d2 y chanperf tardan por lo que
# hacen (chanperf mide 1 s de CPU), no por la red, y no entran en la estadística.
$script:RxLightEcp = '^(keypress|launch|input|query/(active-app|media-player|device-info|graphics-frame-rate))'

# --- sesión y consola ---------------------------------------------------------

function New-RokuTestSession {
    param([string]$RokuHost, [Parameter(Mandatory)][string]$Name, [string]$OutDir)
    Import-RokuEnv
    if (-not $RokuHost) { $RokuHost = $env:ROKU_HOST }
    if (-not $RokuHost) { throw 'Falta -RokuHost o ROKU_HOST. Listá los equipos con roku-devices.ps1.' }
    if (-not $OutDir) { $OutDir = Join-Path (Get-RokuWorkspace) 'test-runs' }
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    [pscustomobject]@{
        Host        = $RokuHost
        Ecp         = "http://${RokuHost}:8060"
        Name        = $Name
        Stamp       = $stamp
        OutDir      = (Resolve-Path $OutDir).Path
        Log         = Join-Path (Resolve-Path $OutDir).Path "$Name-$stamp.log"
        Proc        = $null
        Rtt         = [Collections.Generic.List[double]]::new()
        EcpFailures = 0
    }
}

# El 8085 admite UNA sola conexión. Cuando la tiene una sesión muerta del lado del Roku no hay
# nada local que matar y la espera puede ser de minutos (observado 2026-09-11), así que se
# reintenta en vez de abandonar en el primer intento.
function Start-RokuTestConsole {
    param([Parameter(Mandatory)]$S, [int]$WaitSec = 120)
    $deadline = (Get-Date).AddSeconds($WaitSec)
    $busy = $false
    for ($try = 1; ; $try++) {
        $S.Proc = Start-Process pwsh -PassThru -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-File', $script:Capturer, '-RokuHost', $S.Host, '-OutFile', $S.Log)
        if ((Wait-RokuLog $S 'FIN DEL BACKLOG' 0 30) -ge 0) { return }
        $busy = (Read-RokuLog $S) -match 'Console connection is already in use'
        Stop-RokuTestConsole $S
        if (-not $busy -or (Get-Date) -ge $deadline) { break }
        if ($try -eq 1) { Write-RokuWarn "La consola de $($S.Host) está ocupada; esperando hasta $WaitSec s a que se libere." }
        Start-Sleep -Seconds 10
    }
    if ($busy) {
        throw ("La consola de $($S.Host) sigue ocupada después de $WaitSec s. Si no hay ningún proceso local conectado " +
            "(Get-NetTCPConnection -RemotePort 8085), es una sesión muerta del lado del Roku: se libera sola o reiniciando el device. Ver $($S.Log)")
    }
    throw "La consola de $($S.Host) no respondió (¿el Roku está en reposo o cambió de IP? roku-devices.ps1). Ver $($S.Log)"
}

function Stop-RokuTestConsole {
    param([Parameter(Mandatory)]$S)
    if ($S.Proc -and -not $S.Proc.HasExited) { $S.Proc.Kill() }
}

# Lee el log aunque el capturador lo tenga abierto para escritura.
function Read-RokuLog {
    param([Parameter(Mandatory)]$S)
    if (-not (Test-Path $S.Log)) { return , @() }
    $fs = [IO.FileStream]::new($S.Log, 'Open', 'Read', 'ReadWrite')
    try { , ([IO.StreamReader]::new($fs).ReadToEnd() -split "`r?`n") } finally { $fs.Close() }
}

function Get-RokuLogMark { param([Parameter(Mandatory)]$S) (Read-RokuLog $S).Count }

# Índice absoluto de la primera línea desde $Mark que matchea, o -1 si vence el timeout.
function Wait-RokuLog {
    param([Parameter(Mandatory)]$S, [Parameter(Mandatory)][string]$Pattern, [int]$Mark = 0, [int]$TimeoutSec = 20)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        $lines = Read-RokuLog $S
        for ($i = $Mark; $i -lt $lines.Count; $i++) { if ($lines[$i] -match $Pattern) { return $i } }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    -1
}

# Espera a que la consola se calle ($QuietMs sin líneas nuevas) y devuelve el índice de la
# última línea antes del silencio: su hora es "cuándo terminó de cargar". Dormir un tiempo fijo
# no sirve: el Home sigue trayendo filas y pósters varios segundos después de mostrarse.
function Wait-RokuQuiet {
    param([Parameter(Mandatory)]$S, [int]$QuietMs = 2000, [int]$MaxSec = 30)
    $deadline = (Get-Date).AddSeconds($MaxSec)
    $last = (Read-RokuLog $S).Count; $since = Get-Date
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 200
        $n = (Read-RokuLog $S).Count
        if ($n -ne $last) { $last = $n; $since = Get-Date }
        elseif (((Get-Date) - $since).TotalMilliseconds -ge $QuietMs) { break }
    }
    # La última línea no vacía.
    $lines = Read-RokuLog $S
    for ($i = $lines.Count - 1; $i -ge 0; $i--) { if ($lines[$i]) { return $i } }
    0
}

# --- líneas de consola y reloj del device -----------------------------------------------

# "[HH:mm:ss.fff] resto" (hora de lectura, reloj local de la PC) y, si es una línea de sistema,
# "MM-dd HH:mm:ss.fff" del device al principio del resto. Todo se devuelve en UTC.
function ConvertFrom-RokuLogLine {
    param([string]$Line)
    if ($Line -notmatch '^\[(\d\d:\d\d:\d\d\.\d{3})\] ?(.*)$') { return $null }
    $text = $Matches[2]
    $hostT = [datetime]::ParseExact((Get-Date -Format 'yyyy-MM-dd') + ' ' + $Matches[1], 'yyyy-MM-dd HH:mm:ss.fff', $script:Inv).ToUniversalTime()
    $devT = $null
    if ($text -match '^(\d\d-\d\d \d\d:\d\d:\d\d\.\d{3}) ') {
        $devT = [datetime]::ParseExact("$((Get-Date).Year)-$($Matches[1])", 'yyyy-MM-dd HH:mm:ss.fff', $script:Inv,
            [Globalization.DateTimeStyles]'AssumeUniversal,AdjustToUniversal')
    }
    [pscustomobject]@{ Host = $hostT; Dev = $devT; Text = $text }
}

function ConvertFrom-RokuLog {
    param([string[]]$Lines, [int]$From = 0)
    $out = [Collections.Generic.List[object]]::new()
    for ($i = [Math]::Max(0, $From); $i -lt $Lines.Count; $i++) {
        $p = ConvertFrom-RokuLogLine $Lines[$i]
        if ($p) { $p | Add-Member Index $i; $out.Add($p) }
    }
    , $out
}

# Offset (ms) entre la hora de lectura y la hora del device: el mínimo sobre las líneas de sistema.
function Get-RokuClockOffset {
    param($Parsed)
    $d = @($Parsed | Where-Object { $_.Dev } | ForEach-Object { ($_.Host - $_.Dev).TotalMilliseconds })
    if ($d.Count -eq 0) { return $null }
    ($d | Measure-Object -Minimum).Minimum
}

# Hora del device de una línea: la real si la trae, estimada con el offset si es un print.
function Get-RokuDevTime {
    param($Entry, $OffsetMs)
    if (-not $Entry) { return $null }
    if ($Entry.Dev) { return $Entry.Dev }
    if ($null -eq $OffsetMs) { return $null }
    $Entry.Host.AddMilliseconds(-$OffsetMs)
}

function Find-RokuEntry {
    param($Parsed, [Parameter(Mandatory)][string]$Pattern, [switch]$Last)
    $m = @($Parsed | Where-Object { $_.Text -match $Pattern })
    if ($m.Count -eq 0) { return $null }
    if ($Last) { $m[-1] } else { $m[0] }
}

# Beacons del sistema: "[beacon.signal] |AppLaunchComplete ---> Duration(2859 ms : 2711 ms)".
function Get-RokuBeacon {
    param($Parsed, [Parameter(Mandatory)][string]$Name)
    @($Parsed | Where-Object { $_.Dev -and $_.Text -match "\[beacon\.signal\] \|$Name\s*-+>\s*(TimeBase|Duration)\((\d+) ms" } |
        ForEach-Object { [pscustomobject]@{ Name = $Name; Dev = $_.Dev; Ms = [int]$Matches[2]; Index = $_.Index } })
}

function Find-RokuCrash {
    param([string[]]$Lines, [int]$From = 0)
    for ($i = [Math]::Max(0, $From); $i -lt $Lines.Count; $i++) { if ($Lines[$i] -match $script:RxCrash) { return $Lines[$i] } }
    $null
}

function Get-RokuMs { param($A, $B) if ($A -and $B) { [int][Math]::Round(($B - $A).TotalMilliseconds) } else { $null } }

# --- ECP -----------------------------------------------------------------------------

function Invoke-RokuEcp {
    param([Parameter(Mandatory)]$S, [Parameter(Mandatory)][string]$Path, [switch]$Post, [int]$TimeoutSec = 10, [int]$Retries = 2)
    for ($i = 0; ; $i++) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            $r = Invoke-WebRequest -Uri "$($S.Ecp)/$Path" -Method ($Post ? 'Post' : 'Get') -TimeoutSec $TimeoutSec
            if ($Path -match $script:RxLightEcp) { $S.Rtt.Add($sw.Elapsed.TotalMilliseconds) }
            $c = $r.Content
            return ($c -is [byte[]]) ? [Text.Encoding]::UTF8.GetString($c) : [string]$c
        }
        catch {
            $S.EcpFailures++
            if ($i -ge $Retries) { throw "ECP $Path sin respuesta de $($S.Host): $($_.Exception.Message)" }
            Start-Sleep -Milliseconds 800
        }
    }
}

# Manda una tecla y devuelve cuándo salió (UTC) y la RTT de esa llamada: la RTT aproxima las dos
# travesías de red (tecla hacia el Roku, consola de vuelta) que hay que descontar a una latencia.
function Send-RokuKey {
    param([Parameter(Mandatory)]$S, [Parameter(Mandatory)][string]$Key)
    $t = [datetime]::UtcNow
    $n = $S.Rtt.Count
    Invoke-RokuEcp $S "keypress/$Key" -Post | Out-Null
    [pscustomobject]@{ Sent = $t; RttMs = ($S.Rtt.Count -gt $n) ? $S.Rtt[$S.Rtt.Count - 1] : $null }
}

function Send-RokuKeys {
    param([Parameter(Mandatory)]$S, [Parameter(Mandatory)][string]$Key, [int]$Count = 1, [int]$IntervalMs = 400)
    for ($i = 0; $i -lt $Count; $i++) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Send-RokuKey $S $Key | Out-Null
        $rest = $IntervalMs - $sw.ElapsedMilliseconds
        if ($rest -gt 0 -and $i -lt $Count - 1) { Start-Sleep -Milliseconds $rest }
    }
}

# Home primero: launch/dev sobre una app colgada en el Micro Debugger devuelve 200 y no reinicia.
function Restart-RokuApp {
    param([Parameter(Mandatory)]$S, [string]$Query = '')
    Send-RokuKey $S 'Home' | Out-Null
    Start-Sleep -Seconds 3
    $mark = Get-RokuLogMark $S
    Invoke-RokuEcp $S "launch/dev$Query" -Post -TimeoutSec 15 | Out-Null
    $mark
}

function Get-RokuActiveApp {
    param([Parameter(Mandatory)]$S)
    $a = ([xml](Invoke-RokuEcp $S 'query/active-app')).'active-app'.app
    [pscustomobject]@{ Id = $a.GetAttribute('id'); Name = $a.InnerText; Version = $a.GetAttribute('version') }
}

function Get-RokuDeviceSummary {
    param([Parameter(Mandatory)]$S)
    $d = ([xml](Invoke-RokuEcp $S 'query/device-info')).'device-info'
    [ordered]@{ model = "$($d.'model-name') ($($d.'model-number'))"; firmware = $d.'software-version'
        uiResolution = $d.'ui-resolution'; network = $d.'network-type' }
}

function Get-RokuMediaPlayer {
    param([Parameter(Mandatory)]$S)
    $p = ([xml](Invoke-RokuEcp $S 'query/media-player' -TimeoutSec 8)).player
    $ms = { param($v) if ($v -and "$v" -match '(\d+)') { [long]$Matches[1] } else { $null } }
    $pos = $p.SelectSingleNode('position'); $dur = $p.SelectSingleNode('duration'); $live = $p.SelectSingleNode('is_live')
    [pscustomobject]@{
        State      = $p.GetAttribute('state')
        PositionMs = & $ms ($pos ? $pos.InnerText : $null)
        DurationMs = & $ms ($dur ? $dur.InnerText : $null)
        IsLive     = $live ? ($live.InnerText -eq 'true') : $null
    }
}

function Get-RokuChanPerf {
    param([Parameter(Mandatory)]$S)
    $c = ([xml](Invoke-RokuEcp $S 'query/chanperf')).chanperf
    $p = $c.SelectSingleNode('plugin')
    if (-not $p) { return $null }
    $cpu = $p.SelectSingleNode('cpu-percent'); $m = $p.SelectSingleNode('memory')
    [pscustomobject]@{
        CpuPct    = [double]$cpu.user + [double]$cpu.sys
        MemUsedMB = [Math]::Round([double]$m.used / 1MB, 1)
        MemAnonMB = [Math]::Round([double]$m.anon / 1MB, 1)
        LimitMB   = [Math]::Round([double]$m.limit / 1MB, 1)
    }
}

function Get-RokuNodeCounts {
    param([Parameter(Mandatory)]$S)
    $all = Invoke-RokuEcp $S 'query/sgnodes/all' -TimeoutSec 20
    $roots = Invoke-RokuEcp $S 'query/sgnodes/roots' -TimeoutSec 20
    [pscustomobject]@{
        All   = ($all -match 'All_Nodes node-count="(\d+)"') ? [int]$Matches[1] : $null
        Roots = ($roots -match 'Root_Nodes node-count="(\d+)"') ? [int]$Matches[1] : $null
    }
}

# Memoria de texturas: el mayor "used" de los bloques con max > 0. En equipos de gama baja,
# texturas cerca del tope significan pósters que se descargan y recargan al scrollear.
function Get-RokuTextureUse {
    param([Parameter(Mandatory)]$S)
    $x = [xml](Invoke-RokuEcp $S 'query/r2d2-bitmaps' -TimeoutSec 15)
    $best = $null
    foreach ($tm in $x.SelectNodes('//texture-memory')) {
        $max = @($tm.SelectNodes('max') | ForEach-Object { [double]$_.InnerText } | Measure-Object -Maximum).Maximum
        $used = @($tm.SelectNodes('used') | ForEach-Object { [double]$_.InnerText } | Measure-Object -Maximum).Maximum
        if ($max -gt 0 -and (-not $best -or $used -gt $best.UsedMB * 1MB)) {
            $best = [pscustomobject]@{ UsedMB = [Math]::Round($used / 1MB, 1); MaxMB = [Math]::Round($max / 1MB, 1); Pct = [Math]::Round(100 * $used / $max, 1) }
        }
    }
    $best
}

# --- estado de la UI (ECP query/app-ui) -------------------------------------------------

function Get-RokuUiState {
    param([Parameter(Mandatory)]$S)
    $x = [xml](Invoke-RokuEcp $S 'query/app-ui' -TimeoutSec 25)
    $label = { param($n) $l = $n.SelectSingleNode('.//Label[@text!=""]'); if ($l) { $l.GetAttribute('text') } }

    # Cadena de foco desde la pantalla.
    $chain = [Collections.Generic.List[object]]::new()
    $n = $x.SelectSingleNode('//screen')
    while ($n) {
        $pos = 0; $next = $null
        foreach ($c in $n.ChildNodes) {
            if ($c.NodeType -ne 'Element') { continue }
            if ($c.GetAttribute('focused') -eq 'true') { $next = $c; break }
            $pos++
        }
        if (-not $next) { break }
        $chain.Add([pscustomobject]@{ Tag = $next.LocalName; Name = $next.GetAttribute('name'); Pos = $pos; Node = $next })
        $n = $next
    }

    # Páginas del ViewStack: hijos de gPageContainer. La visible es la de arriba; el Core oculta
    # las anteriores con visible="false" pero NO las saca del árbol, así que acá también se ve
    # cuántas quedaron acumuladas.
    $pages = @()
    $pc = $x.SelectSingleNode("//*[@name='gPageContainer']")
    if ($pc) { $pages = @($pc.ChildNodes | Where-Object { $_.NodeType -eq 'Element' } | ForEach-Object { [pscustomobject]@{ Name = $_.GetAttribute('name'); Visible = ($_.GetAttribute('visible') -ne 'false') } }) }
    $top = @($pages | Where-Object Visible | Select-Object -Last 1)

    # Filas del Home, en orden, con su título.
    $gc = $x.SelectSingleNode("//*[@name='focusableGroup']//*[@name='gContainer']")
    $rows = @()
    if ($gc) { $rows = @($gc.ChildNodes | Where-Object { $_.NodeType -eq 'Element' } | ForEach-Object { [pscustomobject]@{ Id = $_.GetAttribute('name'); Title = & $label $_ } }) }

    # Fila enfocada del Home: el hijo DIRECTO de gContainer marcado focused="true".
    # Ni la cadena de foco ni "el nodo focused más profundo" sirven acá: dentro de gContainer
    # quedan 25 nodos con focused="true" de filas por las que ya se pasó, y el último focused del
    # documento entero está en el menú lateral, fuera del Home. El hijo directo es el único
    # marcador que se mueve con la fila real (verificado: 3 Down -> índice 3).
    $homeRow = $null
    if ($gc) {
        $i = 0
        foreach ($c in $gc.ChildNodes) {
            if ($c.NodeType -ne 'Element') { continue }
            if ($c.GetAttribute('focused') -eq 'true') { $homeRow = $i; break }
            $i++
        }
    }

    $toast = $x.SelectSingleNode('//ToastMessage')
    $dialogs = @($x.SelectNodes("//*[contains(local-name(),'Dialog')]") | Where-Object { $_.GetAttribute('visible') -ne 'false' } | ForEach-Object LocalName)
    $sideItem = @($chain | Where-Object { $_.Tag -eq 'SideBarItem' })

    [pscustomobject]@{
        TopPage       = $top ? $top[0].Name : $null
        Pages         = $pages
        PageNodes     = @($pages | Group-Object Name | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Count = $_.Count } })
        FocusChain    = ($chain | ForEach-Object { if ($_.Name) { "$($_.Tag)#$($_.Name)" } else { $_.Tag } }) -join ' > '
        HomeRows      = $rows
        HomeRow       = $homeRow
        DuplicateRows = @($rows | Group-Object Id | Where-Object Count -gt 1 | ForEach-Object Name)
        Toast         = $toast ? (@($toast.SelectNodes('.//Label') | ForEach-Object { $_.GetAttribute('text') }) -join ' ') : $null
        Dialogs       = $dialogs
        InSideBar     = [bool]($chain | Where-Object Tag -eq 'SideBar')
        SideBarItems  = @($x.SelectNodes('//SideBar//SideBarItem') | ForEach-Object { & $label $_ })
        SideBarFocus  = $sideItem ? (& $label $sideItem[0].Node) : $null
    }
}

# Espera a que la página visible sea la esperada: después de un Back el árbol puede seguir
# mostrando la página anterior unos cientos de ms.
function Wait-RokuPage {
    param([Parameter(Mandatory)]$S, [Parameter(Mandatory)][string]$Page, [int]$TimeoutSec = 10)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        $ui = Get-RokuUiState $S
        if ($ui.TopPage -eq $Page) { return $ui }
    } while ((Get-Date) -lt $deadline)
    $ui
}

# --- red ---------------------------------------------------------------------------

# Salud de la red durante un tramo de la prueba. Cuatro señales:
#   - llamadas ECP que fallaron (timeouts),
#   - RTT p90 de las llamadas livianas,
#   - la app detectó caídas de internet (ver $script:RxNetDrop),
#   - ATRASO DE LA CONSOLA: con las líneas de sistema (hora del device) y el offset de relojes,
#     cuánto tardó cada línea en llegar a la PC. Es la señal más directa: mide el mismo camino de
#     red por el que viajan los datos de la prueba, y detecta cortes aunque ECP haya respondido.
function Get-RokuNetHealth {
    param([Parameter(Mandatory)]$S, [int]$RttFrom = 0, [int]$FailuresBefore = 0, [string[]]$Lines = @(), [int]$From = 0,
        $Parsed, $OffsetMs, [int]$MaxRttP90Ms = 1500, [int]$MaxConsoleLagMs = 3000)
    $r = @(); if ($S.Rtt.Count -gt $RttFrom) { $r = @($S.Rtt.GetRange($RttFrom, $S.Rtt.Count - $RttFrom) | Sort-Object) }
    $med = $r ? $r[[int][Math]::Floor(($r.Count - 1) / 2)] : $null
    $p90 = $r ? $r[[int][Math]::Floor(($r.Count - 1) * 0.9)] : $null
    $drops = 0; for ($i = $From; $i -lt $Lines.Count; $i++) { if ($Lines[$i] -match $script:RxNetDrop) { $drops++ } }
    $lag = $null
    if ($Parsed -and $null -ne $OffsetMs) {
        $l = @($Parsed | Where-Object { $_.Dev -and $_.Index -ge $From } | ForEach-Object { ($_.Host - $_.Dev).TotalMilliseconds - $OffsetMs })
        if ($l) { $lag = [int]($l | Measure-Object -Maximum).Maximum }
    }
    $fails = $S.EcpFailures - $FailuresBefore
    $why = @()
    if ($fails -gt 0) { $why += "$fails llamadas ECP fallaron" }
    if ($p90 -gt $MaxRttP90Ms) { $why += "RTT p90 $([int]$p90) ms" }
    if ($drops -gt 0) { $why += "la app registró $drops eventos de caída de internet" }
    if ($lag -gt $MaxConsoleLagMs) { $why += "la consola llegó con hasta $([Math]::Round($lag / 1000, 1)) s de atraso" }
    [pscustomobject]@{ RttMedianMs = $med ? [int]$med : $null; RttP90Ms = $p90 ? [int]$p90 : $null; EcpFailures = $fails
        InternetDrops = $drops; ConsoleLagMaxMs = $lag; Degraded = [bool]$why; Reason = ($why -join ', ') }
}

# --- catálogo y API de contenido -------------------------------------------------------

function Get-RokuTestCatalog {
    param([Parameter(Mandatory)][string]$Client)
    # Desde 2026-09-18 el catálogo vive dentro de la carpeta del cliente
    # (scenarios/clients/<cliente>/catalog.json), no en un test-data/ suelto
    # -- así queda todo lo de un cliente en un solo lugar.
    $f = Join-Path $script:ClientsDir "$Client\catalog.json"
    if (-not (Test-Path $f)) { throw "No hay catálogo para '$Client' ($f)." }
    Get-Content $f -Raw | ConvertFrom-Json
}

# Misma resolución que hace la app: manager config -> release.json -> config.api.
# La x-client-id es pública (la sirve el config de la app) y no se guarda en ningún archivo.
function Get-OttApi {
    param([Parameter(Mandatory)]$Catalog)
    $hosts = @{ develop = 'https://dev.next.platform.mediastre.am'; staging = 'https://qa.next.platform.mediastre.am'; production = 'https://next.platform.mediastre.am' }
    # S3 sirve release.json sin content-type JSON: se parsea a mano.
    $json = { param($u) $c = (Invoke-WebRequest $u -TimeoutSec 20).Content; if ($c -is [byte[]]) { $c = [Text.Encoding]::UTF8.GetString($c) }; $c.TrimStart([char]0xFEFF) | ConvertFrom-Json -AsHashtable }
    $mgr = & $json "$($hosts[$Catalog.ottEnv])/ott?appId=$($Catalog.ottId):tv"
    $rel = & $json "$($mgr.data)/release.json"
    $api = $rel.config.api
    if (-not $api.nextUrl) { throw "El config de la app ($($mgr.data)/release.json) no trae config.api.nextUrl." }
    [pscustomobject]@{ Url = $api.nextUrl + $api.graphPath; ClientId = $api.headers.'x-client-id' }
}

function Invoke-OttGraph {
    param([Parameter(Mandatory)]$Api, [Parameter(Mandatory)][string]$Query, [hashtable]$Variables = @{}, [string]$QueryName)
    $body = @{ query = $Query; variables = $Variables; query_name = $QueryName } | ConvertTo-Json -Depth 6 -Compress
    $h = @{ 'x-client-id' = $Api.ClientId; 'x-app-os' = 'roku'; 'x-app-device' = 'tv'; 'x-ott-language' = 'es' }
    Invoke-RestMethod -Method Post -Uri $Api.Url -Headers $h -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 20
}

# ¿La entrada del catálogo sigue sirviendo para lo que promete? Consulta la API con los mismos
# query_name que usa el Core (los que pueden resolver accessToken sin sesión).
function Test-OttCatalogEntry {
    param([Parameter(Mandatory)]$Api, [Parameter(Mandatory)]$Entry)
    $ok = { param($d) [pscustomobject]@{ Ok = $true; Reason = ''; Detail = $d } }
    $bad = { param($r) [pscustomobject]@{ Ok = $false; Reason = $r; Detail = '' } }
    $id = $Entry.contentId
    try {
        switch ($Entry.kind) {
            'live' {
                $liveId = ($id -match '-([^-]+)$') ? $Matches[1] : $id
                $r = Invoke-OttGraph $Api 'query getPlayerLive($id:String!){ getLive(_id:$id){ _id name accessToken schedules(hours:8){ name current } } }' @{ id = $liveId } 'getPlayerLive'
                $l = $r.data.getLive
                if (-not $l) { return & $bad 'la API no devuelve el live' }
                if (-not $l.accessToken) { return & $bad 'sin token anónimo' }
                $cur = @($l.schedules | Where-Object current)
                if (-not $cur) { return & $bad 'sin programa en curso: el deep link no reproduciría' }
                return & $ok "en curso: $($cur[0].name)"
            }
            'episode' {
                $r = Invoke-OttGraph $Api 'query getPlayerEpisode($id:String!){ getEpisode(_id:$id){ _id title content{ ...on Media{ _id accessToken } } } }' @{ id = $id } 'getPlayerEpisode'
                $e = $r.data.getEpisode
                if (-not $e) { return & $bad 'la API no devuelve el episodio' }
                if (-not $e.content.accessToken) { return & $bad 'sin token anónimo (pediría login)' }
                if ($Entry.mediaId -and $e.content._id -ne $Entry.mediaId) { return & $bad "el media cambió: $($e.content._id)" }
                return & $ok $e.title
            }
            'series' {
                $r = Invoke-OttGraph $Api 'query getPlayerEpisodeAndShowDetails($id:String!){ getShow(_id:$id){ _id title } getEpisode(_id:$id){ show{ _id title } } }' @{ id = $id } 'getPlayerEpisodeAndShowDetails'
                $t = $r.data.getShow ? $r.data.getShow.title : ($r.data.getEpisode ? $r.data.getEpisode.show.title : $null)
                if (-not $t) { return & $bad 'la API no resuelve ni show ni episodio' }
                return & $ok $t
            }
            'media' {
                $r = Invoke-OttGraph $Api 'query getPlayerMedia($id:String!){ getMedia(_id:$id){ _id title accessToken } }' @{ id = $id } 'getPlayerMedia'
                $m = $r.data.getMedia
                if (-not $m) { return & $bad 'la API no devuelve el media' }
                $hasToken = [bool]$m.accessToken
                if ($Entry.expect -eq 'play' -and -not $hasToken) { return & $bad 'sin token anónimo (pediría login)' }
                if ($Entry.expect -eq 'login' -and $hasToken) { return & $bad 'ahora tiene token anónimo: ya no pediría login' }
                return & $ok $m.title
            }
            default { return & $bad "kind desconocido: $($Entry.kind)" }
        }
    }
    catch { return & $bad "error consultando la API: $($_.Exception.Message)" }
}

# --- reporte -----------------------------------------------------------------------

function Save-RokuTestReport {
    param([Parameter(Mandatory)]$S, [Parameter(Mandatory)]$Report)
    $path = Join-Path $S.OutDir "$($S.Name)-$($S.Stamp).json"
    $Report | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8 $path
    $path
}

function Write-RokuVerdict {
    param([string]$Verdict, [string]$Text)
    $color = @{ PASS = 'Green'; FAIL = 'Red'; LENTO = 'Magenta'; INVALIDO = 'Yellow' }[$Verdict]
    Write-Host ('    {0,-8} {1}' -f $Verdict, $Text) -ForegroundColor ($color ?? 'Gray')
}

Export-ModuleMember -Function *
