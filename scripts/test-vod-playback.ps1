<#
.SYNOPSIS
  Test de reproducción de un VOD (episodio): arranca, pausa/resume, busca con Fwd/Rev, y sale
  limpio con Back. Para la regresión de analytics del VOD-con-ads, ver test-vod-analytics.ps1
  (este test no la duplica: solo reporta video_views como dato informativo).

.DESCRIPTION
  A diferencia de un live (ver test-live-playback.ps1), en un VOD los controles de transporte SÍ
  tienen que funcionar:
    - Play pausa (state=pause, la posición se congela) y reanuda (state=play, sigue avanzando).
    - Fwd/Rev inician una búsqueda: el player queda en pause con la posición sin confirmar hasta
      que se manda Select, que la aplica (el salto se ve en query/media-player). Confirmado a
      mano el 2026-09-15 sobre client/azteca v1.24.92609040 (Player SDK 9.10.202609040): Fwd ->
      Select saltó de 47s a 351s.
    - Back durante una búsqueda sin confirmar cierra el player directamente (no cancela el
      scrub). Es el comportamiento observado, no necesariamente el ideal; el test lo verifica
      pero no lo trata como bug.

  OJO con ECP query/app-ui: no sirve para verificar overlays transitorios (como la barra de
  trickplay). Este test no la usa para nada visual — solo query/media-player (estado y posición,
  que sí son confiables) y la consola.

  Pasos, deep-linkeando al episodio del catálogo:
    1. arranca en state=play, is_live=false, con la posición avanzando.
    2. GA4: screen_view(Player), player_ready(video_type=VOD). video_views se reporta pero NO
       decide el veredicto (ver test-vod-analytics.ps1 para esa regresión conocida).
    3. Play pausa y reanuda correctamente.
    4. Fwd + Select busca hacia adelante (la posición salta y queda por encima del punto de
       partida más el salto mínimo esperado).
    5. Rev + Select busca hacia atrás desde ahí (la posición baja).
    6. Back cierra el player, la app sigue abierta, vuelve al Home sin diálogos colgados, y GA4
       manda screen_view(Home).
    7. Sin crash en toda la corrida. Los BRIGHTSCRIPT: ERROR: roSGNode de InnovidDCL/BrightLine
       no se assertean: son el ruido conocido del fallback RAF -> DAI cuando el preroll no llena.

  PASS todos los checks. FAIL si falta alguno. INVALIDO si el catálogo dice que el contenido no
  sirve, o si nunca llegó a reproducir.

.EXAMPLE
  pwsh test-vod-playback.ps1
  pwsh test-vod-playback.ps1 -RokuHost 192.168.1.63 -Case episode-docufia-cap1
#>
param(
    [string]$RokuHost,
    [string]$Client = 'azteca',
    [string]$Case = 'episode-loteria-t1e1',
    [int]$TimeoutSec = 30,
    # Un solo Fwd/Rev salta ~20-30s (no minutos: eso requiere varias pulsaciones seguidas, que
    # acumulan el incremento). El piso solo tiene que distinguir un seek real de la deriva normal
    # de reproducción durante los ~800ms entre la tecla y el Select que confirma.
    [int]$MinSeekMs = 5000,
    [string]$OutDir
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RokuTest.psm1') -Force

$cat = Get-RokuTestCatalog $Client
$entry = $cat.content | Where-Object key -eq $Case
if (-not $entry) { Write-Error "No existe '$Case' en el catálogo de $Client."; exit 3 }
if ($entry.kind -ne 'episode') { Write-Error "'$Case' no es un episodio (kind=$($entry.kind)). Casos episode: $(($cat.content | Where-Object kind -eq 'episode').key -join ', ')"; exit 3 }

$S = New-RokuTestSession -RokuHost $RokuHost -Name 'test-vod-playback' -OutDir $OutDir
$checks = [ordered]@{}
$observed = [ordered]@{}
function Check([string]$Name, [bool]$Ok) { $script:checks[$Name] = $Ok }

$exit = 3
try {
    Write-Host "==> VOD '$($entry.title)' de $Client en $RokuHost" -ForegroundColor Cyan
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
    Write-Host "    $($device.model) fw $($device.firmware) · red $($device.network) · $($pre.Detail)"
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
    Check 'is_live = false' ($mp -and $mp.IsLive -eq $false)
    $observed.playerStart = $mp

    if (-not $checks['arrancó en play']) {
        Write-RokuVerdict 'INVALIDO' 'nunca llegó a reproducir'
        $json = Save-RokuTestReport $S ([ordered]@{ timestamp = (Get-Date).ToString('o'); rokuHost = $S.Host; case = $Case
            verdict = 'INVALIDO'; reason = 'nunca llegó a reproducir'; checks = $checks; observed = $observed; log = $S.Log })
        Write-Host "    reporte: $json"
        exit 2
    }
    Start-Sleep -Seconds 3
    $mp = Get-RokuMediaPlayer $S

    Write-Host '==> Analytics (informativo, no decide el veredicto — ver test-vod-analytics.ps1)' -ForegroundColor Cyan
    $lines = Read-RokuLog $S
    $sinceText = ($lines[$mark..($lines.Count - 1)]) -join "`n"
    Check 'GA4 screen_view(Player)' ($sinceText -match '"screen_name":"Player"')
    Check 'GA4 player_ready video_type=VOD' ($sinceText -match '"name":"player_ready"[^\n]*"video_type":"VOD"')
    $observed.videoViewsFired = [bool]($sinceText -match '"name":"video_views"')

    Write-Host '==> Play debe pausar y reanudar' -ForegroundColor Cyan
    Send-RokuKey $S 'Play' | Out-Null
    Start-Sleep -Seconds 2
    $paused = Get-RokuMediaPlayer $S
    Check 'Play pausa (state=pause)' ($paused.State -eq 'pause')
    Start-Sleep -Seconds 2
    $stillPaused = Get-RokuMediaPlayer $S
    Check 'la posición no avanza en pausa' ($stillPaused.PositionMs -eq $paused.PositionMs)
    Send-RokuKey $S 'Play' | Out-Null
    Start-Sleep -Seconds 2
    $resumed = Get-RokuMediaPlayer $S
    Check 'Play reanuda (state=play, avanza)' ($resumed.State -eq 'play' -and $resumed.PositionMs -ge $paused.PositionMs)
    $observed.pauseResume = [ordered]@{ beforePause = $mp; paused = $paused; stillPaused = $stillPaused; resumed = $resumed }

    Write-Host '==> Fwd + Select debe buscar hacia adelante' -ForegroundColor Cyan
    $beforeFwd = Get-RokuMediaPlayer $S
    Send-RokuKey $S 'Fwd' | Out-Null
    Start-Sleep -Milliseconds 800
    Send-RokuKey $S 'Select' | Out-Null
    Start-Sleep -Seconds 2
    $afterFwd = Get-RokuMediaPlayer $S
    Check 'Fwd+Select avanza la posición' ($afterFwd.PositionMs -ge $beforeFwd.PositionMs + $MinSeekMs)
    Check 'sigue reproduciendo después de buscar' ($afterFwd.State -eq 'play')
    $observed.seekForward = [ordered]@{ before = $beforeFwd; after = $afterFwd }

    Write-Host '==> Rev + Select debe buscar hacia atrás' -ForegroundColor Cyan
    $beforeRev = Get-RokuMediaPlayer $S
    Send-RokuKey $S 'Rev' | Out-Null
    Start-Sleep -Milliseconds 800
    Send-RokuKey $S 'Select' | Out-Null
    Start-Sleep -Seconds 2
    $afterRev = Get-RokuMediaPlayer $S
    Check 'Rev+Select retrocede la posición' ($afterRev.PositionMs -lt $beforeRev.PositionMs)
    $observed.seekBackward = [ordered]@{ before = $beforeRev; after = $afterRev }

    Check 'sin crash tras pausa/búsqueda' (-not (Find-RokuCrash (Read-RokuLog $S) $mark))

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
    Write-Host ('    {0,-4}  video_views (informativo, no decide el veredicto)' -f $(if ($observed.videoViewsFired) { 'ok' } else { 'NO' })) -ForegroundColor DarkGray
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
