<#
.SYNOPSIS
  Test de regresión: OK repetido sobre el botón de reproducir rompe el player.

  OBLIGATORIO: este test se corre SIEMPRE en toda pasada de la batería de
  player (scenarios/clients/azteca/scenarios/player/scenarios.yaml), sin excepción y sin
  degradar su prioridad -- es la única forma de detectar si los bugs A/B de
  abajo (ya confirmados y arreglados en su momento) vuelven a aparecer en un
  build nuevo. Relacionado pero DISTINTO de SC-VERAHORA-RAPID-CRASH-01 (el
  botón "Ver ahora" del hero de ShowPage específicamente) -- ver la nota
  junto a ese escenario en scenarios/clients/azteca/scenarios/player/scenarios.yaml.

.DESCRIPTION
  Maneja el Roku por ECP (nadie toca el control) y assertea sobre la consola de
  depuración. Cubre DOS bugs distintos, observados el 2026-09-04 sobre
  client/azteca v1.18.92608240 (Core 1.36.202608240, Player SDK 9.7.202608050).

  BUG A - no hay guard en la acción de reproducir.
    N OK rápidos producen N instancias de MediaStreamPlayer (relación 1:1
    medida en 4 corridas). Los teardowns se pisan y el RAFPlayerTask de una
    instancia vieja sobrevive a su propio `content`, que ya fue liberado:
        'Dot' Operator attempted with invalid BrightScript Component
        ... mediastreamrokuplayersdk:/components/tasks/RAFPlayerTask.brs(78)
    y la app queda colgada en el Micro Debugger.

  BUG B - el id de contenido se pierde en el teardown cruzado (persistente).
    Después del abuso el player queda con el id en blanco y pide
        https://mdstrm.com/episode/.json     <- sin id
    que devuelve 404 con cuerpo de texto plano "Not found". Encima
    MediaStreamPlayerAPI.brs(67) le hace ParseJSON sin mirar el status:
        ParseJSON: Unknown identifier 'Not found'
    A partir de ahí ningún contenido reproduce hasta reiniciar la app, incluso
    con un OK único y limpio. Fue determinístico: 4 de 4 intentos.

  POR QUÉ SON DOS TESTS Y NO UNO
    Durante el bug B se cumple "1 OK = 1 Init", así que la assertion del test A
    lo deja pasar entero. Y el síntoma del A es no determinístico: el mismo
    abuso dio crash duro, "Rendezvous aborted" y "RAF state = error" en
    corridas distintas, según qué carrera gane. Por eso el test A assertea la
    causa (cuántas instancias se crean) y no el crash: assertear el crash da un
    test flaky que además puede pasar en verde por la razón equivocada.

  Los dos errores roSGNode de InnovidDCL y BrightLine NO se assertean: salen
  igual en la corrida sana, son ruido de RAF.

  ANTES DEL FIX AMBOS TESTS FALLAN. Eso es lo esperado y es el punto.

.PARAMETER Nav
  Teclas para llegar del Home a la página del show con el botón de play
  enfocado. Es lo más frágil del test: si cambia el layout del Home hay que
  actualizarlo. El test verifica que efectivamente llegó (showScreenshowPage) y
  falla fuerte si no, en vez de assertear sobre una pantalla equivocada.

.PARAMETER NavOtroCapitulo
  Teclas para moverse a un capítulo distinto dentro del show, para el test B.
  Default 'right' (desde la tarjeta ya enfocada, la de al lado).

.EXAMPLE
  pwsh test-player-multipress.ps1 -RokuHost 192.168.1.186
  pwsh test-player-multipress.ps1 -Test A -OkCount 3 -OkIntervalMs 150
  pwsh test-player-multipress.ps1 -OkCount 1     # control: debe pasar hoy
#>
param(
    [string]$RokuHost = $env:ROKU_HOST,

    # Cada test quiere un burst distinto y por eso los defaults son por test
    # (ver $burstA / $burstB mas abajo): el A necesita ser agresivo para forzar
    # la carrera, y el B necesita corromper SIN crashear, porque si la app cae
    # al Micro Debugger no queda nada que medir despues. Si se pasan explicitos,
    # estos valores mandan para los dos.
    [int]$OkCount,
    [int]$OkIntervalMs,

    [string]$Nav = 'down,Select',

    # Teclas para pasar del estado en que queda la página del show a una tarjeta
    # de episodio reproducible.
    [string]$NavToPlay = 'down,right',
    [string]$NavOtroCapitulo = 'right',

    [ValidateSet('A', 'B', 'both')]
    [string]$Test = 'both',

    [string]$OutDir = (Join-Path $PSScriptRoot '..\test-runs')
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RokuDev.psm1') -Force; Import-RokuEnv
if (-not $RokuHost) { $RokuHost = $env:ROKU_HOST }
if (-not $RokuHost) { Write-Error 'Falta -RokuHost o ROKU_HOST. Listá los equipos con roku-devices.ps1.'; exit 3 }
$ecp = "http://${RokuHost}:8060"

# A: agresivo, para forzar la carrera de instancias.
# B: mas suave, para corromper sin tirar la app al Micro Debugger.
$burstA = @{ n = 5; ms = 60 }
$burstB = @{ n = 3; ms = 200 }
if ($PSBoundParameters.ContainsKey('OkCount')) { $burstA.n = $OkCount; $burstB.n = $OkCount }
if ($PSBoundParameters.ContainsKey('OkIntervalMs')) { $burstA.ms = $OkIntervalMs; $burstB.ms = $OkIntervalMs }
$capturer = Join-Path $PSScriptRoot 'roku-console-capture.ps1'

function Info($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Pass($m) { Write-Host "    PASS  $m" -ForegroundColor Green }
function Fail($m) { Write-Host "    FAIL  $m" -ForegroundColor Red }
function Note($m) { Write-Host "          $m" -ForegroundColor DarkGray }

# --- consola ----------------------------------------------------------------

# Lee el log aunque el proceso capturador lo tenga abierto para escritura.
function Read-Log {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return @() }
    $fs = New-Object System.IO.FileStream $Path,
        ([System.IO.FileMode]::Open),
        ([System.IO.FileAccess]::Read),
        ([System.IO.FileShare]::ReadWrite)
    try {
        $sr = New-Object System.IO.StreamReader $fs
        return $sr.ReadToEnd() -split "`r?`n"
    }
    finally { $fs.Close() }
}

function Get-Mark { param([string]$Path) (Read-Log $Path).Count }

function Get-Since {
    param([string]$Path, [int]$Mark)
    $all = Read-Log $Path
    if ($all.Count -le $Mark) { return @() }
    $all[$Mark..($all.Count - 1)]
}

function Wait-Log {
    param([string]$Path, [string]$Pattern, [int]$Mark = 0, [int]$TimeoutSec = 20)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ((Get-Since $Path $Mark) -match $Pattern) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

# Espera a que la consola se calle: la señal de que la pantalla terminó de
# cargar. Dormir un tiempo fijo no sirve — el Home sigue trayendo filas y
# pósters durante varios segundos después de showScreenhomePage, y si se navega
# antes el foco todavía no está asentado: el DOWN lo termina manejando otro
# nodo y el OK siguiente se pierde sin navegar.
function Wait-Settle {
    param([string]$Path, [int]$QuietMs = 1800, [int]$MaxSec = 25)
    $deadline = (Get-Date).AddSeconds($MaxSec)
    $last = (Read-Log $Path).Count
    $quietSince = Get-Date
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 200
        $now = (Read-Log $Path).Count
        if ($now -ne $last) {
            $last = $now
            $quietSince = Get-Date
        }
        elseif (((Get-Date) - $quietSince).TotalMilliseconds -ge $QuietMs) {
            return
        }
    }
}

# --- device -----------------------------------------------------------------

function Send-Key {
    param([string]$Key)
    Invoke-RestMethod -Method Post -Uri "$ecp/keypress/$Key" -TimeoutSec 5 | Out-Null
}

function Send-Nav {
    param([string]$Keys, [string]$Path)
    foreach ($k in ($Keys -split ',')) {
        Send-Key $k.Trim()
        Start-Sleep -Milliseconds 400
        Wait-Settle $Path -QuietMs 1200 -MaxSec 12
    }
}

function Get-AppVersion {
    try {
        $a = Invoke-RestMethod -Uri "$ecp/query/active-app" -TimeoutSec 5
        '{0} v{1}' -f $a.'active-app'.app.'#text', $a.'active-app'.app.version
    }
    catch { 'desconocida' }
}

# Reinicia la app a Home limpio.
# OJO: launch/dev por sí solo NO reinicia si la app quedó colgada en el Micro
# Debugger. Devuelve 200, trae el proceso suspendido al frente y no loguea
# nada. Hay que mandar Home primero para matarlo de verdad.
function Reset-App {
    param([string]$Path)
    Send-Key 'Home'
    Start-Sleep -Seconds 3
    $mark = Get-Mark $Path
    Invoke-RestMethod -Method Post -Uri "$ecp/launch/dev" -TimeoutSec 10 | Out-Null
    if (-not (Wait-Log $Path 'ViewStack : showScreenhomePage' $mark 30)) {
        throw 'La app no llegó al Home después del relaunch.'
    }
    # Recién acá el canal está corriendo: antes del launch, query/active-app
    # devuelve la pantalla del Roku ("Roku Dynamic Menu") y el reporte quedaba
    # sin decir qué build se probó.
    $script:version = Get-AppVersion
    Wait-Settle $Path -QuietMs 2500 -MaxSec 40
}

# Lleva de Home a la página del show con el botón de play enfocado.
function Goto-ShowPage {
    param([string]$Path)
    $mark = Get-Mark $Path
    Send-Nav $Nav $Path
    if (-not (Wait-Log $Path 'ViewStack : showScreenshowPage' $mark 20)) {
        throw "No se llegó a la página del show con Nav='$Nav'. El layout del Home probablemente cambió: ajustá -Nav."
    }
    # El foco al entrar es inestable: el botón de play del hero lo tiene un
    # instante y lo pierde cuando terminan de cargar TabView/SeasonListView.
    # En vez de correrle la carrera a esa ventana, se espera a que la página
    # quede quieta y después se navega explícitamente a una tarjeta de episodio.
    # Además no todos los shows tienen botón de play (Exatlón México no), así
    # que la lista de episodios es el único camino que sirve para todos.
    Wait-Settle $Path -QuietMs 1800 -MaxSec 25
    Send-Nav $NavToPlay $Path
}

function Invoke-OkBurst {
    param([int]$Count, [int]$IntervalMs)
    for ($i = 1; $i -le $Count; $i++) {
        Send-Key 'Select'
        if ($i -lt $Count) { Start-Sleep -Milliseconds $IntervalMs }
    }
}

# --- patrones de assertion --------------------------------------------------

# Init loguea exactamente una linea por instancia, siempre con el prefijo del
# logger INFO (verificado: 3 con prefijo, 0 sin, en la corrida de 3 OK).
$RX_INIT      = '----> MediaStreamPlayer : Init'
$RX_CRASH_A   = "'Dot' Operator attempted with invalid"
$RX_IDVACIO   = 'mdstrm\.com/episode/\.json'
$RX_PARSEJSON = "ParseJSON: Unknown identifier 'Not found'"
$RX_PLAYING   = 'RAFPlayerTask: state = playing'
$RX_DEBUGGER  = 'BrightScript Micro Debugger'

function Count-Match {
    param([string[]]$Lines, [string]$Pattern)
    @($Lines | Select-String -Pattern $Pattern).Count
}

# --- setup ------------------------------------------------------------------

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = Join-Path $OutDir "test-multipress-$stamp.log"

Info "Roku    : $RokuHost"
Info "Burst   : A=$($burstA.n)x$($burstA.ms)ms  B=$($burstB.n)x$($burstB.ms)ms"
Info "Log     : $log"

$proc = Start-Process pwsh -PassThru -WindowStyle Hidden -ArgumentList @(
    '-NoProfile', '-File', $capturer, '-RokuHost', $RokuHost, '-OutFile', $log
)

try {
    if (-not (Wait-Log $log 'FIN DEL BACKLOG' 0 25)) {
        throw "La consola no se enganchó. ¿Otra sesión tiene el puerto 8085 (telnet, VS Code)? Ver $log"
    }

    $script:version = 'desconocida'   # la completa Reset-App, con el canal ya arriba
    Write-Host ''

    $results = [ordered]@{}

    # === TEST A =============================================================
    if ($Test -eq 'A' -or $Test -eq 'both') {
        Info 'TEST A - un intento de reproducir debe crear un solo player'
        Reset-App $log
        Goto-ShowPage $log

        $mark = Get-Mark $log
        Invoke-OkBurst $burstA.n $burstA.ms
        Start-Sleep -Seconds 7
        $lines = Get-Since $log $mark

        $inits = Count-Match $lines $RX_INIT
        $crashed = (Count-Match $lines $RX_CRASH_A) -gt 0
        Note "$($burstA.n) OK enviados -> $inits instancias de MediaStreamPlayer"
        if ($crashed) { Note 'crash observado: content.LIVE sobre Invalid (RAFPlayerTask.brs:78)' }

        # Cero instancias NO es el bug: es el test no probando nada. Si se
        # reporta como FAIL "falta el guard" queda un rojo que miente, y peor,
        # se pone en verde solo cuando el burst vuelva a errarle al botón.
if ($inits -eq 0) {
            Fail 'INVALIDO - ningun OK arranco la reproduccion, el test no probo nada'
            Note 'El foco no estaba sobre algo reproducible cuando salio el burst.'
            Note "Ajusta -NavToPlay (actual '$NavToPlay') o -Nav."
            $results['A'] = @{ pass = $false; invalido = $true; motivo = 'el burst no arranco ninguna reproduccion' }
        }
        elseif ($inits -eq 1 -and -not $crashed) {
            Pass '1 intento = 1 player, sin crash'
            $results['A'] = @{ pass = $true; inits = 1; crashed = $false; okSent = $burstA.n }
        }
        else {
            Fail "se crearon $inits players para un solo intento (esperado 1)"
            Note 'Causa: la accion de reproducir no tiene guard/debounce.'
            $results['A'] = @{ pass = $false; inits = $inits; crashed = $crashed; okSent = $burstA.n }
        }
        Write-Host ''
    }

    # === TEST B =============================================================
    if ($Test -eq 'B' -or $Test -eq 'both') {
        Info 'TEST B - despues del abuso, otro contenido debe seguir reproduciendo'
        Reset-App $log
        Goto-ShowPage $log

        # Fase 1: el abuso que corrompe.
        $markAbuso = Get-Mark $log
        Invoke-OkBurst $burstB.n $burstB.ms
        Start-Sleep -Seconds 7

        $abuso = Get-Since $log $markAbuso

        # Si el burst le erró al botón no hubo corrupción, y entonces la fase 2
        # reproduce bien y el test da VERDE FALSO. Hay que cortarlo antes: sin
        # abuso efectivo (>=2 instancias) no hay nada que medir.
        $initsAbuso = Count-Match $abuso $RX_INIT
        if ($initsAbuso -lt 2) {
            Fail 'INVALIDO - el abuso no corrompio nada, el test no probo nada'
            Note "El burst genero $initsAbuso instancia(s); se necesitan >=2 para corromper."
            Note "Ajusta -NavToPlay (actual '$NavToPlay'), -OkCount o -Nav."
            $results['B'] = @{ pass = $false; invalido = $true; motivo = 'el abuso no corrompio'; initsAbuso = $initsAbuso }
        }
        # Si cayó en el Micro Debugger ganó el bug A y B no se puede medir: la
        # app está muerta, no hay intento posterior que observar.
        elseif ($abuso -match $RX_DEBUGGER) {
            Fail 'INCONCLUSO - la app cayó en el Micro Debugger durante el abuso (bug A)'
            Note 'El bug A tapa al B. Probá -OkCount 3 -OkIntervalMs 200 para corromper sin crashear,'
            Note 'o corregí primero el bug A y volvé a correr este test.'
            $results['B'] = @{ pass = $false; inconcluso = $true; motivo = 'micro debugger (bug A)' }
        }
        else {
            # --- Fase 2: salir del player y probar OTRO capitulo con un OK limpio.
            Send-Key 'Back'
            Start-Sleep -Seconds 2
            Send-Nav $NavOtroCapitulo $log

            $mark = Get-Mark $log
            Send-Key 'Select'          # un solo OK, prolijo
            Start-Sleep -Seconds 12
            $f2 = Get-Since $log $mark

            $f2Inits     = Count-Match $f2 $RX_INIT
            $f2IdVacio   = Count-Match $f2 $RX_IDVACIO
            $f2Parse     = Count-Match $f2 $RX_PARSEJSON
            $f2Reprodujo = (Count-Match $f2 $RX_PLAYING) -gt 0

            Note "post-abuso  : 1 OK limpio -> $f2Inits player(s); reprodujo=$f2Reprodujo"
            if ($f2IdVacio) { Note "$f2IdVacio request(s) a episode/.json (id perdido)" }
            if ($f2Parse)   { Note "$f2Parse ParseJSON sobre el cuerpo 404 'Not found' (MediaStreamPlayerAPI.brs:67)" }

            # --- Fase 3, control: reiniciar la app y repetir lo MISMO.
            # Sin este control el rojo de la fase 2 no es atribuible: un contenido
            # caido del lado del servidor, la red, o un nav equivocado dan el
            # mismo sintoma, y el test terminaria acusando al bug por algo que no
            # es suyo. Si el mismo contenido reproduce con la app recien
            # reiniciada, entonces lo que lo rompe es el abuso de OK.
            Info 'control: reiniciando la app y repitiendo el mismo intento'
            Reset-App $log
            Goto-ShowPage $log
            Send-Nav $NavOtroCapitulo $log

            $mark = Get-Mark $log
            Send-Key 'Select'
            Start-Sleep -Seconds 12
            $f3 = Get-Since $log $mark

            $f3Inits     = Count-Match $f3 $RX_INIT
            $f3Reprodujo = (Count-Match $f3 $RX_PLAYING) -gt 0
            Note "post-reinicio: 1 OK limpio -> $f3Inits player(s); reprodujo=$f3Reprodujo"

            $datos = @{
                postAbuso    = @{ inits = $f2Inits; reprodujo = $f2Reprodujo; idVacio = $f2IdVacio; parseJson = $f2Parse }
                postReinicio = @{ inits = $f3Inits; reprodujo = $f3Reprodujo }
                initsAbuso   = $initsAbuso
            }

            if (-not $f3Reprodujo) {
                Fail 'INVALIDO - el mismo contenido tampoco reproduce con la app recien reiniciada'
                Note 'El fallo no se le puede atribuir al abuso: puede ser el contenido, la red o el nav.'
                $results['B'] = $datos + @{ pass = $false; invalido = $true; motivo = 'el control post-reinicio tampoco reprodujo' }
            }
            elseif ($f2Reprodujo -and $f2IdVacio -eq 0 -and $f2Parse -eq 0) {
                Pass 'reproduce normal despues del abuso'
                $results['B'] = $datos + @{ pass = $true }
            }
            else {
                Fail 'la reproduccion quedo rota para todo contenido posterior'
                Note 'Confirmado contra el control: el mismo contenido y el mismo nav reproducen'
                Note 'bien tras reiniciar la app, asi que lo que lo rompe es el abuso de OK.'
                if ($f2IdVacio) { Note 'Causa B1: el id de contenido se pierde en el teardown cruzado.' }
                if ($f2Parse)   { Note 'Causa B2: no se valida el status HTTP antes del ParseJSON.' }
                $results['B'] = $datos + @{ pass = $false }
            }
        }
        Write-Host ''
    }

    # === reporte ============================================================
    $failed = @($results.Values | Where-Object { -not $_.pass })
    $jsonPath = Join-Path $OutDir "test-multipress-$stamp.json"
    [ordered]@{
        timestamp = (Get-Date).ToString('o')
        rokuHost  = $RokuHost
        app       = $script:version
        burst     = @{ A = $burstA; B = $burstB }
        nav       = @{ show = $Nav; otroCapitulo = $NavOtroCapitulo }
        results   = $results
        log       = $log
    } | ConvertTo-Json -Depth 6 | Set-Content $jsonPath

    Info 'Resumen'
    Write-Host "    app     : $script:version"
    Write-Host "    log     : $log"
    Write-Host "    reporte : $jsonPath"
    foreach ($k in $results.Keys) {
        $r = $results[$k]
        $tag = if ($r.inconcluso) { 'INCONCLUSO' } elseif ($r.pass) { 'PASS' } else { 'FAIL' }
        Write-Host "    test $k  : $tag"
    }

    if ($failed.Count -gt 0) {
        Write-Host ''
        Write-Host "$($failed.Count) test(s) en rojo." -ForegroundColor Red
        exit 1
    }
    Write-Host ''
    Write-Host 'Todo verde.' -ForegroundColor Green
    exit 0
}
finally {
    if ($proc -and -not $proc.HasExited) { $proc.Kill() }
}
