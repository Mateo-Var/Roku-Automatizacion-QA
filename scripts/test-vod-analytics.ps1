<#
.SYNOPSIS
  Test de regresión: un VOD con publicidad (ruta RAF) tiene que reportar el arranque real de la
  reproducción a analytics.

.DESCRIPTION
  Defecto del Player SDK en la ruta RAF: si el player no observa RAFPlayerTask.currentState:
    - el evento de analytics "buffering" nunca se emite,
    - la escena nunca recibe status = "playing" (se queda en "stopped"),
    - GA4 "video_views" nunca sale (el Core lo gatea con status = "playing"),
    - los heartbeats "playing" van con duration: 0.
  La sesión sigue mandando eventos, así que el backend registra el start y no el stream.

  El test relanza la app, navega a un VOD, lo deja reproducir y assertea sobre la consola:
    PASS       buffering + escena en playing + video_views + duration > 0
    FAIL       la reproducción arrancó (hubo Init y heartbeats) pero falta alguno de los cuatro
    INVALIDO   no se reprodujo nada, o el contenido no pidió preroll (con -RequireAds, default):
               sin preroll el contenido no pasa por la ruta RAF y el test no probaría nada.

  El banner "MEDIASTREAM PLAYER SDK VERSION" queda en el reporte: es la única forma confiable de
  saber qué player corrió (la versión del Core no lo dice).

.EXAMPLE
  pwsh test-vod-analytics.ps1
  pwsh test-vod-analytics.ps1 -Expect FAIL      # con un player roto conocido: exit 0 si falla como se espera
#>
param(
    [string]$RokuHost = $env:ROKU_HOST,
    # Home -> "Continuar viendo" -> primer tile (reproduce directo). En un device sin historial esa
    # fila no existe: usar 'down,Select,down,down,right,Select' (ficha del show -> tabs -> filtro ->
    # grilla -> primer episodio). Ver roku-testing/SKILL.md.
    [string]$Nav = 'down,Select',
    [int]$WatchSeconds = 75,
    [bool]$RequireAds = $true,
    [ValidateSet('PASS', 'FAIL')][string]$Expect = 'PASS',
    [string]$OutDir = (Join-Path $PSScriptRoot '..\test-runs')
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RokuDev.psm1') -Force; Import-RokuEnv
if (-not $RokuHost) { $RokuHost = $env:ROKU_HOST }
if (-not $RokuHost) { Write-Error 'Falta -RokuHost o ROKU_HOST. Listá los equipos con roku-devices.ps1.'; exit 3 }
$ecp = "http://${RokuHost}:8060"

function Read-Log([string]$Path) {
    if (-not (Test-Path $Path)) { return @() }
    $fs = [IO.FileStream]::new($Path, 'Open', 'Read', 'ReadWrite')
    try { ([IO.StreamReader]::new($fs)).ReadToEnd() -split "`r?`n" | Where-Object { $_ -ne '' } } finally { $fs.Close() }
}
function Wait-Log([string]$Path, [string]$Pattern, [int]$Mark = 0, [int]$TimeoutSec = 30) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $l = @(Read-Log $Path); if ($l.Count -gt $Mark -and ($l[$Mark..($l.Count - 1)] -match $Pattern)) { return $true }
        Start-Sleep -Milliseconds 300
    }
    $false
}
# Esperar a que la consola se calle: navegar antes de que el Home asiente pierde teclas.
function Wait-Settle([string]$Path, [int]$QuietMs = 1500, [int]$MaxSec = 30) {
    $deadline = (Get-Date).AddSeconds($MaxSec); $last = @(Read-Log $Path).Count; $quiet = Get-Date
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 250; $n = @(Read-Log $Path).Count
        if ($n -ne $last) { $last = $n; $quiet = Get-Date } elseif (((Get-Date) - $quiet).TotalMilliseconds -ge $QuietMs) { return }
    }
}
function Send-Key([string]$Key) { Invoke-RestMethod -Method Post -Uri "$ecp/keypress/$Key" -TimeoutSec 5 | Out-Null }

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = Join-Path $OutDir "test-vod-analytics-$stamp.log"
$proc = Start-Process pwsh -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'roku-console-capture.ps1'), '-RokuHost', $RokuHost, '-OutFile', $log)

try {
    if (-not (Wait-Log $log 'FIN DEL BACKLOG' 0 25)) {
        throw "La consola no se enganchó (¿otra sesión tiene el 8085?). Ver $log"
    }
    Write-Host "==> Relanzando la app en $RokuHost" -ForegroundColor Cyan
    Send-Key 'Home'; Start-Sleep -Seconds 3
    $mark = @(Read-Log $log).Count
    Invoke-RestMethod -Method Post -Uri "$ecp/launch/dev" -TimeoutSec 10 | Out-Null
    if (-not (Wait-Log $log 'ViewStack : showScreenhomePage' $mark 45)) { throw 'La app no llegó al Home.' }
    Wait-Settle $log 2500 40

    Write-Host "==> Navegando ($Nav) y mirando ${WatchSeconds}s de reproducción" -ForegroundColor Cyan
    $mark = @(Read-Log $log).Count
    foreach ($k in $Nav -split ',') { Send-Key $k.Trim(); Start-Sleep -Milliseconds 500; Wait-Settle $log 1200 12 }
    Start-Sleep -Seconds $WatchSeconds

    $all = @(Read-Log $log); $lines = if ($all.Count -gt $mark) { $all[$mark..($all.Count - 1)] } else { @() }
    $text = $lines -join "`n"
    $sdk      = [regex]::Match($text, 'MEDIASTREAM PLAYER SDK VERSION: ([\d.]+)').Groups[1].Value
    $mediaId  = [regex]::Match($text, '\]\s+mediaId: "([a-f0-9]+)"').Groups[1].Value
    $adUrl    = [regex]::Match($text, 'mdstrm\.com/ads/([a-f0-9]+)').Groups[1].Value
    $inits    = ([regex]::Matches($text, 'MediaStreamPlayer : Init')).Count
    $playing  = ([regex]::Matches($text, 'getPlayingPayload : playing')).Count
    $buffering = ([regex]::Matches($text, 'getBufferingPayload : buffering')).Count
    $views    = ([regex]::Matches($text, '"name":"video_views"')).Count
    $statuses = @([regex]::Matches($text, 'status: "(\w+)"') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -ne 'Loaded' })
    $durations = @([regex]::Matches($text, '(?m)\]\s+duration: (\d+)\s*$') | ForEach-Object { [long]$_.Groups[1].Value })
    $maxDuration = if ($durations) { ($durations | Measure-Object -Maximum).Maximum } else { 0 }

    $checks = [ordered]@{
        'evento buffering'        = $buffering -gt 0
        'escena en playing'       = $statuses -contains 'playing'
        'GA4 video_views'         = $views -gt 0
        'duration > 0 en playing' = $maxDuration -gt 0
    }
    $invalidReason = if ($inits -eq 0 -or $playing -eq 0) { 'no se reprodujo nada (revisá -Nav con roku-screenshot.ps1)' }
                     elseif ($RequireAds -and -not $adUrl) { 'el contenido no pidió preroll: no pasa por la ruta RAF' }
    $verdict = if ($invalidReason) { 'INVALIDO' } elseif ($checks.Values -notcontains $false) { 'PASS' } else { 'FAIL' }

    Write-Host ''
    Write-Host "    player SDK : $(if ($sdk) { $sdk } else { '?' })"
    Write-Host "    mediaId    : $mediaId   preroll: $(if ($adUrl) { $adUrl } else { 'no' })"
    Write-Host "    escena     : $($statuses -join ' -> ')"
    Write-Host "    heartbeats : $playing   duration máx: $maxDuration"
    foreach ($c in $checks.GetEnumerator()) {
        Write-Host ('    {0,-4}  {1}' -f $(if ($c.Value) { 'ok' } else { 'NO' }), $c.Key) -ForegroundColor $(if ($c.Value) { 'Green' } else { 'Red' })
    }
    $color = @{ PASS = 'Green'; FAIL = 'Red'; INVALIDO = 'Yellow' }[$verdict]
    Write-Host "==> $verdict$(if ($invalidReason) { " - $invalidReason" })" -ForegroundColor $color

    [ordered]@{
        timestamp = (Get-Date).ToString('o'); rokuHost = $RokuHost; playerSdk = $sdk; mediaId = $mediaId; adConfig = $adUrl
        verdict = $verdict; expected = $Expect; invalidReason = $invalidReason; checks = $checks
        sceneStatuses = $statuses; heartbeats = $playing; maxDuration = $maxDuration; log = $log
    } | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $OutDir "test-vod-analytics-$stamp.json")
    Write-Host "    log/json   : $log"

    if ($verdict -eq 'INVALIDO') { exit 2 }
    if ($verdict -eq $Expect) { exit 0 } else { exit 1 }
}
catch { Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red; exit 3 }
finally { if ($proc -and -not $proc.HasExited) { $proc.Kill() } }
