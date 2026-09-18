<#
.SYNOPSIS
  Test de deep links: cada contenido del catálogo abre lo que tiene que abrir, en cuánto tiempo,
  y Back vuelve al Home. En frío (la app se lanza con el deep link) y en caliente (la app ya está
  abierta y recibe el deep link por ECP input, como cuando el usuario viene de la búsqueda de Roku).

.DESCRIPTION
  Casos: las entradas de scenarios/clients/<cliente>/catalog.json con tag "deeplink" (o las de -Tag / -Case) y
  los negativos de "deeplinkNegative". Por caso:

    1. Precheck contra la API (catalog.ps1): si el contenido rotó o el live no tiene programa en
       curso, INVALIDO sin tocar el Roku. Un contenido caído no es un bug de la app.
    2. cold:  Home -> launch/dev?contentId=...&mediaType=...
       warm:  launch/dev, esperar el Home asentado -> input?contentId=...&mediaType=...
    3. Resultado esperado (campo "expect"):
         play        el player llega a state=play con la posición avanzando (ECP query/media-player),
                     is_live coincide con el catálogo y, si el catálogo trae mediaId, la consola
                     confirma que se pidió ese media y no otro.
         showPage    se muestra la ficha del show.
         login       se muestra la pantalla de login.
         home-toast  queda en el Home, sin reproducir, con el toast esperado.
         home        queda en el Home, sin reproducir y sin diálogos colgados.
    4. Back (play y showPage): la app sigue abierta y vuelve al Home, sin filas duplicadas.

  Tiempos, con el reloj del Roku (ver RokuTest.psm1):
    toVideoMs        cold: AppLaunchInitiate -> VODStartComplete (beacons del sistema)
                     warm: "Main : Input Event" -> VODStartComplete
    waitForHomeMs    cold: cuánto espera el deep link a que termine de cargar el Home. El Core no
                     atiende el deep link hasta que cargaron todas las filas.
    appLaunchCompleteMs  el beacon que mide Roku. Hoy se dispara al iniciar la escena, antes de que
                     el contenido del deep link arranque.

  Estados por caso:
    PASS      abrió lo esperado y, si hay budget en el catálogo, dentro del budget
    FAIL      abrió otra cosa, no abrió nada, se colgó, o Back no volvió al Home
    LENTO     funcionalmente bien pero excede el budget (budgets: deeplinkColdToVideoMs,
              deeplinkWarmToVideoMs, deeplinkToShowPageMs)
    INVALIDO  el test no probó nada: contenido caído en la API, o la red se degradó en ese caso

  Exit: 0 todo PASS · 1 algún FAIL o LENTO · 2 solo INVALIDO además de PASS · 3 error del test.

.EXAMPLE
  pwsh test-deeplink.ps1 -RokuHost 192.168.1.46 -Tag smoke          # 3 casos, frío y caliente
  pwsh test-deeplink.ps1 -RokuHost 192.168.1.46                     # todo el catálogo
  pwsh test-deeplink.ps1 -Case live-azteca-noticias -Mode cold
#>
param(
    [string]$RokuHost,
    [string]$Client = 'azteca',
    [string[]]$Case,
    [string]$Tag = 'deeplink',
    [ValidateSet('cold', 'warm', 'both')][string]$Mode = 'both',
    [switch]$NoNegative,
    [int]$TimeoutSec = 45,
    [string]$OutDir
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RokuTest.psm1') -Force

$cat = Get-RokuTestCatalog $Client
$S = New-RokuTestSession -RokuHost $RokuHost -Name 'test-deeplink' -OutDir $OutDir
$budgets = $cat.budgets

# --- selección de casos ---------------------------------------------------------------
$cases = @()
if ($Case) {
    $cases = @($cat.content | Where-Object { $Case -contains $_.key }) + @($cat.deeplinkNegative | Where-Object { $Case -contains $_.key })
    $missing = @($Case | Where-Object { $_ -notin $cases.key })
    if ($missing) { Write-Error "Casos inexistentes en el catálogo: $($missing -join ', ')"; exit 3 }
}
else {
    $cases = @($cat.content | Where-Object { $_.tags -contains $Tag })
    if (-not $NoNegative -and $Tag -eq 'deeplink') { $cases += @($cat.deeplinkNegative) }
}
$modes = ($Mode -eq 'both') ? @('cold', 'warm') : @($Mode)

function New-Result($c, $mode) {
    [ordered]@{ key = $c.key; mode = $mode; contentId = $c.contentId; mediaType = $c.mediaType; expect = $c.expect
        verdict = $null; reason = ''; timings = [ordered]@{}; observed = [ordered]@{}; network = $null }
}

function Invoke-DeeplinkCase($c, [string]$mode, $pre) {
    $r = New-Result $c $mode
    if ($pre -and -not $pre.Ok) { $r.verdict = 'INVALIDO'; $r.reason = "catálogo: $($pre.Reason)"; return $r }

    $rtt0 = $S.Rtt.Count; $fail0 = $S.EcpFailures
    $q = '?contentId=' + [uri]::EscapeDataString($c.contentId)
    if ($c.mediaType) { $q += '&mediaType=' + [uri]::EscapeDataString($c.mediaType) }

    if ($mode -eq 'cold') {
        $mark = Restart-RokuApp $S $q
    }
    else {
        $m0 = Restart-RokuApp $S
        if ((Wait-RokuLog $S 'ViewStack : showScreenhomePage' $m0 45) -lt 0) { $r.verdict = 'INVALIDO'; $r.reason = 'la app no llegó al Home antes del deep link'; return $r }
        Wait-RokuQuiet $S 2500 40 | Out-Null
        $mark = Get-RokuLogMark $S
        Invoke-RokuEcp $S "input$q" -Post | Out-Null
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $fail = { param($why) if (-not $r.verdict) { $r.verdict = 'FAIL'; $r.reason = $why } }
    $playSeen = $null; $ui = $null

    switch ($c.expect) {
        'play' {
            while ((Get-Date) -lt $deadline) {
                if (Find-RokuCrash (Read-RokuLog $S) $mark) { break }
                $mp = Get-RokuMediaPlayer $S
                if ($mp.State -eq 'play' -and $mp.PositionMs -gt 0) { $playSeen = [datetime]::UtcNow; break }
                Start-Sleep -Milliseconds 700
            }
            if (-not $playSeen) { & $fail "no reprodujo en $TimeoutSec s"; break }
            Start-Sleep -Seconds 3
            $mp2 = Get-RokuMediaPlayer $S
            $r.observed.player = [ordered]@{ state = $mp2.State; positionMs = $mp2.PositionMs; durationMs = $mp2.DurationMs; isLive = $mp2.IsLive }
            if ($mp2.State -ne 'play' -or $mp2.PositionMs -le $mp.PositionMs) { & $fail "arrancó pero no sigue reproduciendo (state=$($mp2.State))" }
            if ($null -ne $c.isLive -and $mp2.IsLive -ne [bool]$c.isLive) { & $fail "is_live=$($mp2.IsLive), el catálogo espera $($c.isLive)" }
            if ($c.mediaId) {
                $since = (Read-RokuLog $S)[$mark..((Get-RokuLogMark $S) - 1)] -join "`n"
                $ids = @([regex]::Matches($since, 'mediaId: "([a-f0-9]+)"') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
                $r.observed.mediaIds = $ids
                if ($ids -and $ids -notcontains $c.mediaId) { & $fail "reprodujo otro media ($($ids -join ', '))" }
            }
        }
        { $_ -in 'showPage', 'login' } {
            $page = ($c.expect -eq 'showPage') ? 'showPage' : 'loginPage'
            # En frío el Home aparece antes: se espera específicamente la página pedida.
            $idx = Wait-RokuLog $S "ViewStack : showScreen$page" $mark $TimeoutSec
            if ($idx -lt 0) { & $fail "no abrió $page en $TimeoutSec s"; break }
            Wait-RokuQuiet $S 1500 20 | Out-Null
            $ui = Get-RokuUiState $S
            $r.observed.topPage = $ui.TopPage
            if ($ui.TopPage -ne $page) { & $fail "la página visible es $($ui.TopPage), no $page" }
            if ((Get-RokuMediaPlayer $S).State -eq 'play') { & $fail 'además está reproduciendo' }
        }
        { $_ -in 'home', 'home-toast' } {
            if ($mode -eq 'cold' -and (Wait-RokuLog $S 'ViewStack : showScreenhomePage' $mark 45) -lt 0) { & $fail 'la app no llegó al Home'; break }
            if ($c.mediaType) { Wait-RokuLog $S 'handleDeepLinkingInputEvent' $mark 30 | Out-Null }
            if ($c.expect -eq 'home-toast') {
                $seen = $null; $until = (Get-Date).AddSeconds(12)
                while (-not $seen -and (Get-Date) -lt $until) {
                    $ui = Get-RokuUiState $S
                    if ($ui.Toast -and $ui.Toast -match $c.toastPattern) { $seen = $ui.Toast }
                }
                $r.observed.toast = $seen ?? $ui.Toast
                if (-not $seen) { & $fail "no apareció el toast '$($c.toastPattern)'" }
            }
            Wait-RokuQuiet $S 3000 30 | Out-Null
            $ui = Get-RokuUiState $S
            if ($ui.Dialogs) { Start-Sleep -Seconds 8; $ui = Get-RokuUiState $S }
            $r.observed.topPage = $ui.TopPage; $r.observed.dialogs = $ui.Dialogs
            if ($ui.TopPage -ne 'homePage') { & $fail "la página visible es $($ui.TopPage), no el Home" }
            if ($ui.Dialogs) { & $fail "diálogo colgado: $($ui.Dialogs -join ', ')" }
            if ((Get-RokuMediaPlayer $S).State -eq 'play') { & $fail 'está reproduciendo' }
        }
        default { throw "expect desconocido en $($c.key): $($c.expect)" }
    }

    $lines = Read-RokuLog $S
    if ($crash = Find-RokuCrash $lines $mark) { $r.verdict = 'FAIL'; $r.reason = "crash: $crash" }

    # Back: la app sigue abierta y vuelve al Home.
    if (-not $r.verdict -and $c.expect -in 'play', 'showPage') {
        Send-RokuKey $S 'Back' | Out-Null
        Wait-RokuQuiet $S 2000 20 | Out-Null
        $app = Get-RokuActiveApp $S
        if ($app.Id -ne 'dev') { & $fail "Back salió de la app (activa: $($app.Name))" }
        else {
            $ui = Get-RokuUiState $S
            $r.observed.afterBack = $ui.TopPage
            if ($ui.TopPage -ne 'homePage') { & $fail "Back dejó en $($ui.TopPage), no en el Home" }
            if ((Get-RokuMediaPlayer $S).State -eq 'play') { & $fail 'después de Back sigue reproduciendo' }
        }
    }
    if ($ui -and $ui.DuplicateRows) { $r.observed.duplicateRows = $ui.DuplicateRows; & $fail "Home con filas duplicadas: $($ui.DuplicateRows -join ', ')" }

    # Tiempos con el reloj del device. Cada ancla se registra en observed.anchors: si alguna no
    # aparece en la consola, el tiempo sale null y el caso lo dice, en vez de pasar en verde sin medir.
    $lines = Read-RokuLog $S
    $all = ConvertFrom-RokuLog $lines
    $off = Get-RokuClockOffset $all
    $since = @($all | Where-Object Index -ge $mark)
    $anchors = [ordered]@{}
    $t0 = if ($mode -eq 'cold') {
        $b = Get-RokuBeacon $since 'AppLaunchInitiate' | Select-Object -First 1
        if ($b) { $anchors.start = 'AppLaunchInitiate'; $b.Dev }
    }
    else {
        # "Main : Input Event" lo imprime la app del cliente al recibir el roInputEvent. Si no
        # aparece (otra versión de la cáscara, o se perdió la línea), sirve el handler del Core:
        # es el mismo instante salvo milisegundos.
        $e = Find-RokuEntry $since 'Main : Input Event'
        if (-not $e) { $e = Find-RokuEntry $since 'handleDeepLinkingInputEvent' }
        if ($e) { $anchors.start = ($e.Text -match 'Main : Input Event') ? 'Main : Input Event' : 'handleDeepLinkingInputEvent' }
        Get-RokuDevTime $e $off
    }
    $tHome = Get-RokuDevTime (Find-RokuEntry $since 'ViewStack : showScreenhomePage') $off
    $tHandled = Get-RokuDevTime (Find-RokuEntry $since 'handleDeepLinkingInputEvent') $off
    $vs = Get-RokuBeacon $since 'VODStartComplete' | Select-Object -First 1
    # Sin el beacon del sistema, el instante en que el test vio state=play (corregido por el offset)
    # es una cota superior: llega hasta 700 ms tarde por el intervalo de sondeo.
    $tVideo = $vs ? $vs.Dev : (($playSeen -and $null -ne $off) ? $playSeen.AddMilliseconds(-$off) : $null)
    if ($tVideo) { $anchors.video = $vs ? 'VODStartComplete' : 'query/media-player state=play (±700 ms)' }
    $tPage = Get-RokuDevTime (Find-RokuEntry $since 'ViewStack : showScreen(showPage|loginPage)') $off
    $alc = Get-RokuBeacon $since 'AppLaunchComplete' | Select-Object -First 1
    if ($mode -eq 'cold') {
        $r.timings.appLaunchCompleteMs = $alc ? $alc.Ms : $null
        $r.timings.homeShownMs = Get-RokuMs $t0 $tHome
        $r.timings.waitForHomeMs = Get-RokuMs $tHome $tHandled
    }
    if ($c.expect -eq 'play') { $r.timings.toVideoMs = Get-RokuMs $t0 $tVideo; $r.timings.handledToVideoMs = Get-RokuMs $tHandled $tVideo }
    if ($c.expect -in 'showPage', 'login') { $r.timings.toPageMs = Get-RokuMs $t0 $tPage }
    $r.observed.anchors = $anchors

    $r.network = Get-RokuNetHealth $S $rtt0 $fail0 $lines $mark -Parsed $all -OffsetMs $off
    if (-not $r.verdict) {
        $r.verdict = 'PASS'
        $b = $null; $v = $null; $what = $null
        if ($c.expect -eq 'play') { $what = 'toVideoMs'; $v = $r.timings.toVideoMs; $b = ($mode -eq 'cold') ? $budgets.deeplinkColdToVideoMs : $budgets.deeplinkWarmToVideoMs }
        elseif ($c.expect -eq 'showPage') { $what = 'toPageMs'; $v = $r.timings.toPageMs; $b = $budgets.deeplinkToShowPageMs }
        if ($b -and $null -eq $v) { $r.reason = "abrió lo esperado, pero $what no se pudo medir (falta un ancla en la consola): budget no verificado" }
        elseif ($b -and $v -gt $b -and -not $r.network.Degraded) { $r.verdict = 'LENTO'; $r.reason = "$v ms > budget $b ms" }
    }
    if ($r.network.Degraded -and $r.verdict -in 'FAIL', 'LENTO') { $r.reason = "red degradada ($($r.network.Reason)); sin eso: $($r.reason)"; $r.verdict = 'INVALIDO' }
    elseif ($r.network.Degraded) { $r.reason = "tiempos no confiables: red degradada ($($r.network.Reason))" }
    $r
}

# --- corrida ----------------------------------------------------------------------------
$results = [Collections.Generic.List[object]]::new()
$exit = 3
try {
    Write-Host "==> Deep links de $Client en $($S.Host): $($cases.Count) casos x $($modes -join '+')" -ForegroundColor Cyan
    $device = Get-RokuDeviceSummary $S
    Write-Host "    $($device.model) fw $($device.firmware) · red $($device.network)"
    $api = Get-OttApi $cat
    Start-RokuTestConsole $S
    $version = $null

    foreach ($c in $cases) {
        $pre = ($c.PSObject.Properties['kind']) ? (Test-OttCatalogEntry $api $c) : $null
        foreach ($m in $modes) {
            Write-Host ("==> {0} [{1}] {2}={3}" -f $c.key, $m, $c.mediaType, $c.contentId) -ForegroundColor Cyan
            try { $r = Invoke-DeeplinkCase $c $m $pre }
            catch { $r = New-Result $c $m; $r.verdict = 'INVALIDO'; $r.reason = "error del test: $($_.Exception.Message)" }
            if (-not $version -and $r.verdict -ne 'INVALIDO') { try { $a = Get-RokuActiveApp $S; if ($a.Id -eq 'dev') { $version = "$($a.Name) v$($a.Version)" } } catch {} }
            $t = ($r.timings.GetEnumerator() | Where-Object { $null -ne $_.Value } | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' '
            Write-RokuVerdict $r.verdict ("$($r.reason) $t".Trim())
            $results.Add($r)
        }
    }

    $count = { param($v) @($results | Where-Object verdict -eq $v).Count }
    Write-Host ''
    Write-Host ("==> PASS {0} · FAIL {1} · LENTO {2} · INVALIDO {3}" -f (& $count 'PASS'), (& $count 'FAIL'), (& $count 'LENTO'), (& $count 'INVALIDO')) -ForegroundColor Cyan
    $json = Save-RokuTestReport $S ([ordered]@{
        timestamp = (Get-Date).ToString('o'); client = $Client; rokuHost = $S.Host; device = $device; app = $version
        catalogVerified = $cat.verified.date; budgets = $budgets; results = $results; log = $S.Log })
    Write-Host "    reporte: $json"
    $exit = ((& $count 'FAIL') + (& $count 'LENTO')) ? 1 : ((& $count 'INVALIDO') ? 2 : 0)
}
catch { Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red; $exit = 3 }
finally { Stop-RokuTestConsole $S }
exit $exit
