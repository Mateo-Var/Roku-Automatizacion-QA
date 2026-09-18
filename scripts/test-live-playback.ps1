<#
.SYNOPSIS
  Test de reproducción de un live: arranca, se queda reproduciendo, dispara analytics (GA4 +
  Mediastream) y sale limpio con Back.

.DESCRIPTION
  Comportamiento esperado en un live, confirmado a mano el 2026-09-15 sobre client/azteca
  v1.24.92609040 (Core 1.44.202609040, Player SDK 9.10.202609040): un live NO es trickplay-able
  desde el remoto. OK, Play (pausa) y Rev llegan al player (se ven como "onKeyEvent" en la
  consola) pero no pausan ni retroceden nada: es el contrato correcto, no un bug. El test lo
  assertea así — si algún día SÍ pausan o retroceden, es un cambio de comportamiento para
  confirmar con producto, no algo que haya que "arreglar" a ciegas.

  OJO con ECP query/app-ui: no sirve para verificar overlays transitorios (como la barra de
  transporte). Un query justo después de la tecla puede leer el árbol en un instante en que el
  overlay ya se ocultó de nuevo, dando un falso negativo (pasó en esta sesión). Este test no lo
  usa para nada visual: solo query/media-player (estado y posición) y la consola.

  Pasos, deep-linkeando al live del catálogo:
    1. arranca en state=play, is_live=true, con la posición avanzando.
    2. GA4: screen_view(Player), player_ready(video_type=Live), video_views.
    3. Mediastream: heartbeat "playing" (plt_content_type=vlive) con la posición avanzando entre
       dos heartbeats.
    4. OK, Play y Rev no cambian el estado ni frenan la posición (comportamiento esperado).
    5. Back cierra el player (state=close), la app sigue abierta, vuelve al Home sin diálogos
       colgados, y GA4 manda screen_view(Home).
    6. Sin crash en toda la corrida. Los BRIGHTSCRIPT: ERROR: roSGNode de InnovidDCL/BrightLine
       no se assertean: son el ruido conocido del fallback RAF -> DAI cuando el preroll no llena.

  PASS todos los checks. FAIL si falta alguno. INVALIDO si el catálogo dice que el contenido no
  sirve (sin programa en curso) o si nunca llegó a reproducir.

.EXAMPLE
  pwsh test-live-playback.ps1
  pwsh test-live-playback.ps1 -RokuHost 192.168.1.63 -Case live-adn-noticias
#>
param(
    [string]$RokuHost,
    [string]$Client = 'azteca',
    [string]$Case = 'live-azteca-noticias',
    [int]$WatchSeconds = 40,
    [int]$TimeoutSec = 30,
    [string]$OutDir
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RokuTest.psm1') -Force

$cat = Get-RokuTestCatalog $Client
$entry = $cat.content | Where-Object key -eq $Case
if (-not $entry) { Write-Error "No existe '$Case' en el catálogo de $Client."; exit 3 }
if ($entry.kind -ne 'live') { Write-Error "'$Case' no es un live (kind=$($entry.kind)). Casos live: $(($cat.content | Where-Object kind -eq 'live').key -join ', ')"; exit 3 }

$S = New-RokuTestSession -RokuHost $RokuHost -Name 'test-live-playback' -OutDir $OutDir
$checks = [ordered]@{}
$observed = [ordered]@{}
function Check([string]$Name, [bool]$Ok) { $script:checks[$Name] = $Ok }

# Heartbeats PERIÓDICOS "playing" de MediaStreamPlayerAnalytics (cada ~30s), no el evento
# "playing" único que se dispara una sola vez al arrancar con position: 0. Los periódicos van
# precedidos, a pocas líneas, de "periodicPlayingEventExpired" — sin ese precursor no es un
# heartbeat de cadencia, es el arranque, y no sirve para verificar que la posición avanza.
# Cada uno se imprime como un dump BrightScript multilínea (no JSON): se busca la marca y se
# leen los campos de las ~20 líneas siguientes en vez de parsear la corrida entera con una regex.
function Get-PlayingHeartbeats([string[]]$Lines) {
    $out = [Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -notmatch 'getPlayingPayload : playing:') { continue }
        $periodic = $false
        for ($k = [Math]::Max(0, $i - 6); $k -lt $i; $k++) { if ($Lines[$k] -match 'periodicPlayingEventExpired') { $periodic = $true; break } }
        if (-not $periodic) { continue }
        $pos = $null; $plt = $null
        for ($j = $i; $j -lt [Math]::Min($i + 20, $Lines.Count); $j++) {
            if ($null -eq $pos -and $Lines[$j] -match '\bposition:\s*(\d+)\s*$') { $pos = [long]$Matches[1] }
            if ($null -eq $plt -and $Lines[$j] -match 'plt_content_type:\s*"([^"]+)"') { $plt = $Matches[1] }
            if ($pos -and $plt) { break }
        }
        $out.Add([pscustomobject]@{ Index = $i; PositionMs = $pos; PltContentType = $plt })
    }
    , $out
}

$exit = 3
try {
    Write-Host "==> Live '$($entry.title)' de $Client en $RokuHost" -ForegroundColor Cyan
    $api = Get-OttApi $cat
    $pre = Test-OttCatalogEntry $api $entry
    if (-not $pre.Ok) {
        Write-Host "==> INVALIDO - catálogo: $($pre.Reason)" -ForegroundColor Yellow
        $json = Save-RokuTestReport $S ([ordered]@{ timestamp = (Get-Date).ToString('o'); rokuHost = $S.Host; case = $Case
            verdict = 'INVALIDO'; reason = "catálogo: $($pre.Reason)" })
        Write-Host "    reporte: $json"
        exit 2
    }
    $device = Get-RokuDeviceSummary $S
    Write-Host "    $($device.model) fw $($device.firmware) · red $($device.network) · en curso: $($pre.Detail)"
    Start-RokuTestConsole $S

    $q = '?contentId=' + [uri]::EscapeDataString($entry.contentId) + '&mediaType=' + [uri]::EscapeDataString($entry.mediaType)
    $mark = Restart-RokuApp $S $q

    Write-Host '==> Esperando que arranque' -ForegroundColor Cyan
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $mp = $null
    while ((Get-Date) -lt $deadline) {
        if ($crash = Find-RokuCrash (Read-RokuLog $S) $mark) { $observed.crash = $crash; break }
        $mp = Get-RokuMediaPlayer $S
        if ($mp.State -eq 'play' -and $mp.PositionMs -gt 0) { break }
        Start-Sleep -Milliseconds 700
    }
    Check 'arrancó en play' ($mp -and $mp.State -eq 'play' -and $mp.PositionMs -gt 0)
    Check 'is_live = true' ($mp -and $mp.IsLive -eq $true)
    $observed.playerStart = $mp

    if (-not $checks['arrancó en play']) {
        Write-RokuVerdict 'INVALIDO' 'nunca llegó a reproducir'
        $json = Save-RokuTestReport $S ([ordered]@{ timestamp = (Get-Date).ToString('o'); rokuHost = $S.Host; case = $Case
            verdict = 'INVALIDO'; reason = 'nunca llegó a reproducir'; checks = $checks; observed = $observed; log = $S.Log })
        Write-Host "    reporte: $json"
        exit 2
    }

    # Los heartbeats periódicos salen cada ~30s: se espera activamente a ver 2 (no un sleep fijo
    # de $WatchSeconds), porque con la red del lab la cadencia real puede correrse varios
    # segundos. Igual se respeta $WatchSeconds como piso.
    Write-Host "==> Mirando reproducción (mínimo ${WatchSeconds}s, hasta ver 2 heartbeats periódicos)" -ForegroundColor Cyan
    $watchDeadline = (Get-Date).AddSeconds([Math]::Max($WatchSeconds, 65) + 40)
    $minDeadline = (Get-Date).AddSeconds($WatchSeconds)
    $hb = @()
    do {
        Start-Sleep -Seconds 3
        $lines = Read-RokuLog $S
        $since = $lines[$mark..($lines.Count - 1)]
        $hb = Get-PlayingHeartbeats $since
    } while ((Get-Date) -lt $minDeadline -or ($hb.Count -lt 2 -and (Get-Date) -lt $watchDeadline))

    $mp2 = Get-RokuMediaPlayer $S
    Check 'la posición sigue avanzando' ($mp2.State -eq 'play' -and $mp2.PositionMs -gt $mp.PositionMs)
    $observed.playerAfterWatch = $mp2

    Write-Host '==> Analytics' -ForegroundColor Cyan
    $sinceText = $since -join "`n"
    Check 'GA4 screen_view(Player)' ($sinceText -match '"screen_name":"Player"')
    Check 'GA4 player_ready video_type=Live' ($sinceText -match '"name":"player_ready"[^\n]*"video_type":"Live"')
    Check 'GA4 video_views' ($sinceText -match '"name":"video_views"')

    $observed.heartbeats = $hb.Count
    Check 'heartbeat de Mediastream (plt_content_type=vlive)' ($hb.Count -gt 0 -and -not ($hb | Where-Object { $_.PltContentType -ne 'vlive' }))
    if ($hb.Count -ge 2) {
        Check 'la posición del heartbeat avanza' ($hb[-1].PositionMs -gt $hb[0].PositionMs)
    }
    else {
        Check 'la posición del heartbeat avanza' $false
        $observed.heartbeatNote = 'menos de 2 heartbeats en la ventana: subí -WatchSeconds (son cada ~30s)'
    }

    Write-Host '==> OK / Play / Rev no deben pausar ni retroceder un live' -ForegroundColor Cyan
    $mpBefore = Get-RokuMediaPlayer $S
    $markKeys = Get-RokuLogMark $S
    Send-RokuKey $S 'Select' | Out-Null; Start-Sleep -Milliseconds 800
    Send-RokuKey $S 'Play' | Out-Null; Start-Sleep -Milliseconds 800
    Send-RokuKey $S 'Rev' | Out-Null; Start-Sleep -Seconds 3
    $mpAfter = Get-RokuMediaPlayer $S
    Check 'OK/Play/Rev no pausan ni retroceden el live' ($mpAfter.State -eq 'play' -and $mpAfter.PositionMs -gt $mpBefore.PositionMs)
    Check 'sin crash tras OK/Play/Rev' (-not (Find-RokuCrash (Read-RokuLog $S) $markKeys))
    $observed.keysTest = [ordered]@{ before = $mpBefore; after = $mpAfter }

    Write-Host '==> Back debe cerrar el player y volver al Home' -ForegroundColor Cyan
    $markBack = Get-RokuLogMark $S
    Send-RokuKey $S 'Back' | Out-Null
    Start-Sleep -Seconds 2
    Check 'Back cierra el player' ((Get-RokuMediaPlayer $S).State -eq 'close')
    $app = Get-RokuActiveApp $S
    Check 'la app sigue abierta (no salió a Roku Home)' ($app.Id -eq 'dev')
    Wait-RokuQuiet $S 1500 15 | Out-Null
    $ui = Get-RokuUiState $S
    Check 'vuelve a la página Home' ($ui.TopPage -eq 'homePage')
    Check 'sin diálogos colgados' (-not $ui.Dialogs)
    $linesBack = Read-RokuLog $S
    $sinceBack = $linesBack[$markBack..($linesBack.Count - 1)] -join "`n"
    Check 'GA4 screen_view(Home) tras Back' ($sinceBack -match '"screen_name":"Home"')
    $observed.topPageAfterBack = $ui.TopPage

    Check 'sin crash en toda la corrida' (-not (Find-RokuCrash (Read-RokuLog $S) 0))

    Write-Host ''
    foreach ($c in $checks.GetEnumerator()) {
        Write-Host ('    {0,-4}  {1}' -f $(if ($c.Value) { 'ok' } else { 'NO' }), $c.Key) -ForegroundColor $(if ($c.Value) { 'Green' } else { 'Red' })
    }
    $verdict = ($checks.Values -notcontains $false) ? 'PASS' : 'FAIL'
    Write-Host ''
    Write-RokuVerdict $verdict "$($entry.title) ($Case)"

    $json = Save-RokuTestReport $S ([ordered]@{
        timestamp = (Get-Date).ToString('o'); rokuHost = $S.Host; client = $Client; case = $Case
        verdict = $verdict; checks = $checks; observed = $observed; log = $S.Log
    })
    Write-Host "    reporte: $json"
    $exit = ($verdict -eq 'PASS') ? 0 : 1
}
catch { Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red; $exit = 3 }
finally { Stop-RokuTestConsole $S }
exit $exit
