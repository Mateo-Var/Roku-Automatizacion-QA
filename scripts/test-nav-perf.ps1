<#
.SYNOPSIS
  Rendimiento de navegación: arranque, scroll del Home, abrir y cerrar fichas en ciclos (fugas) y
  páginas del menú. Mide con el reloj del Roku y con las métricas del propio device.

.DESCRIPTION
  Pasos (-Steps, por defecto todos):

  launch  -LaunchRuns arranques en frío. Por arranque:
            appLaunchCompleteMs  beacon del sistema: lo que mide Roku. OJO: el Core lo dispara al
                                 iniciar la escena, antes de tener contenido; por eso se miden
                                 también los dos siguientes.
            homeShownMs          AppLaunchInitiate -> "ViewStack : showScreenhomePage"
            homeSettledMs        AppLaunchInitiate -> la consola se calla (el Home terminó de traer
                                 filas y pósters): lo que el usuario percibe como "cargó"
          Al final: memoria, texturas y nodos SceneGraph con el Home cargado, y filas duplicadas.

  scroll  Baja -Scroll filas a ritmo humano (-KeyIntervalMs) y sube todo a ritmo rápido
          (-FastKeyIntervalMs); después recorre una fila a lo ancho. Mide fps (ECP
          graphics-frame-rate) y CPU (chanperf) durante la navegación, y TECLAS PERDIDAS: la fila
          enfocada al final (leída del árbol de UI) contra la esperada.

  show    Busca por TÍTULO la fila del catálogo (navigation.showRow), entra y hace -Cycles veces
          OK -> ficha del show -> Back. Por ciclo: latencia hasta que se muestra la ficha, hasta
          que termina de cargar, que Back devuelva el foco a la misma fila, y después memoria,
          nodos, texturas y páginas en el árbol. La pendiente de nodos y memoria por ciclo detecta
          fugas: una ficha cerrada tiene que liberar lo que creó.

  menu    Por cada ítem de navigation.menu (por nombre): abre el menú lateral, lo selecciona y
          mide hasta que la página se muestra y termina de cargar, con los fps del momento.

  Latencias de teclas: hora de lectura de la consola - hora de envío - RTT de ESA tecla (la RTT
  aproxima las dos travesías de red). Resolución: la varianza de la red; con WiFi malo la corrida
  sale INVALIDO en vez de publicar números inflados.

  Veredicto:
    FAIL      crash, teclas perdidas a ritmo humano, filas duplicadas en el Home, Back que no
              vuelve, o fichas cerradas que se acumulan en el árbol
    LENTO     algún budget del catálogo excedido, o regresión > -RegressionPct contra -Baseline
    INVALIDO  red degradada, o no se pudo llegar a una pantalla (fila o ítem de menú inexistente)
    PASS      todo lo demás

  Exit: 0 PASS · 1 FAIL o LENTO · 2 INVALIDO · 3 error del test.

.EXAMPLE
  pwsh test-nav-perf.ps1 -RokuHost 192.168.1.46
  pwsh test-nav-perf.ps1 -RokuHost 192.168.1.46 -Steps show -Cycles 10          # solo fugas
  pwsh test-nav-perf.ps1 -Baseline ..\..\..\..\test-runs\test-nav-perf-<antes>.json   # comparar builds
#>
param(
    [string]$RokuHost,
    [string]$Client = 'azteca',
    [ValidateSet('launch', 'scroll', 'show', 'menu')][string[]]$Steps = @('launch', 'scroll', 'show', 'menu'),
    [int]$LaunchRuns = 3,
    [int]$Cycles = 5,
    [int]$Scroll,
    [int]$KeyIntervalMs = 450,
    [int]$FastKeyIntervalMs = 120,
    [string]$Baseline,
    [int]$RegressionPct = 20,
    [string]$OutDir
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RokuTest.psm1') -Force

$cat = Get-RokuTestCatalog $Client
$nav = $cat.navigation
$budgets = $cat.budgets
if (-not $Scroll) { $Scroll = $nav.scrollRows }
$S = New-RokuTestSession -RokuHost $RokuHost -Name 'test-nav-perf' -OutDir $OutDir

$metrics = [ordered]@{}
$detail = [ordered]@{}
$fails = [Collections.Generic.List[string]]::new()
$invalid = [Collections.Generic.List[string]]::new()

function Info($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Note($m) { Write-Host "    $m" }
function Median($v) { $a = @($v | Where-Object { $null -ne $_ } | Sort-Object); if ($a) { $a[[int][Math]::Floor(($a.Count - 1) / 2)] } }
function Slope($v) {
    $y = @($v); $n = $y.Count; if ($n -lt 2) { return $null }
    $mx = ($n - 1) / 2; $my = ($y | Measure-Object -Average).Average
    $num = 0; $den = 0; for ($i = 0; $i -lt $n; $i++) { $num += ($i - $mx) * ($y[$i] - $my); $den += ($i - $mx) * ($i - $mx) }
    [Math]::Round($num / $den, 2)
}
function Entry($all, [int]$idx) { $all | Where-Object Index -eq $idx | Select-Object -First 1 }
function KeyLatency($all, [int]$idx, $key) {
    $e = Entry $all $idx; if (-not $e -or -not $key.RttMs) { return $null }
    [int][Math]::Max(0, ($e.Host - $key.Sent).TotalMilliseconds - $key.RttMs)
}
function Check-Crash([int]$mark, [string]$where) {
    if ($c = Find-RokuCrash (Read-RokuLog $S) $mark) { $fails.Add("crash en ${where}: $c"); return $true }
    $false
}

# Muestreo en paralelo de fps, CPU y memoria (ECP), mientras el hilo principal navega.
function Start-Sampler {
    $state = [hashtable]::Synchronized(@{ Stop = $false; Samples = [Collections.Concurrent.ConcurrentQueue[object]]::new() })
    $job = Start-ThreadJob -ArgumentList $S.Ecp, $state -ScriptBlock {
        param($ecp, $state)
        while (-not $state.Stop) {
            $t = [datetime]::UtcNow; $fps = $null; $cpu = $null; $mem = $null
            try { $fps = [double]([xml](Invoke-WebRequest "$ecp/query/graphics-frame-rate" -TimeoutSec 4).Content).'graphics-frame-rate'.fps } catch {}
            try {
                $p = ([xml](Invoke-WebRequest "$ecp/query/chanperf" -TimeoutSec 4).Content).chanperf.SelectSingleNode('plugin')
                if ($p) { $cpu = [double]$p.'cpu-percent'.user + [double]$p.'cpu-percent'.sys; $mem = [Math]::Round([double]$p.memory.used / 1MB, 1) }
            } catch {}
            $state.Samples.Enqueue([pscustomobject]@{ T = $t; Fps = $fps; Cpu = $cpu; MemMB = $mem })
            Start-Sleep -Milliseconds 400
        }
    }
    [pscustomobject]@{ Job = $job; State = $state }
}
function Stop-Sampler($smp) {
    $smp.State.Stop = $true
    $smp.Job | Wait-Job -Timeout 20 | Out-Null
    $smp.Job | Remove-Job -Force
    , @($smp.State.Samples.ToArray())
}
function Summarize-Samples($samples) {
    $fps = @($samples | Where-Object { $null -ne $_.Fps } | ForEach-Object Fps)
    $cpu = @($samples | Where-Object { $null -ne $_.Cpu } | ForEach-Object Cpu)
    $mem = @($samples | Where-Object { $null -ne $_.MemMB } | ForEach-Object MemMB)
    [ordered]@{
        samples  = $samples.Count
        fpsMin   = $fps ? [Math]::Round(($fps | Measure-Object -Minimum).Minimum, 1) : $null
        fpsMedian = $fps ? [Math]::Round((Median $fps), 1) : $null
        cpuMaxPct = $cpu ? [Math]::Round(($cpu | Measure-Object -Maximum).Maximum, 1) : $null
        cpuAvgPct = $cpu ? [Math]::Round(($cpu | Measure-Object -Average).Average, 1) : $null
        memDeltaMB = ($mem.Count -ge 2) ? [Math]::Round($mem[-1] - $mem[0], 1) : $null
    }
}
function Go-HomeSettled {
    $mark = Restart-RokuApp $S
    if ((Wait-RokuLog $S 'ViewStack : showScreenhomePage' $mark 45) -lt 0) { throw 'La app no llegó al Home.' }
    Wait-RokuQuiet $S 2500 45 | Out-Null
    $mark
}
function Go-Row([int]$row) {
    $ui = Get-RokuUiState $S
    if ($null -eq $ui.HomeRow) { return $ui }
    $d = $row - $ui.HomeRow
    if ($d) { Send-RokuKeys $S ($d -gt 0 ? 'Down' : 'Up') ([Math]::Abs($d)) $KeyIntervalMs; Wait-RokuQuiet $S 1500 20 | Out-Null; $ui = Get-RokuUiState $S }
    $ui
}

# --- pasos -------------------------------------------------------------------------------

function Step-Launch {
    Info "Arranque en frío x$LaunchRuns"
    $runs = @()
    for ($i = 1; $i -le $LaunchRuns; $i++) {
        $mark = Restart-RokuApp $S
        $iHome = Wait-RokuLog $S 'ViewStack : showScreenhomePage' $mark 45
        if ($iHome -lt 0) { $invalid.Add("arranque $i no llegó al Home"); continue }
        $iQuiet = Wait-RokuQuiet $S 2500 45
        if (Check-Crash $mark "arranque $i") { continue }
        $all = ConvertFrom-RokuLog (Read-RokuLog $S); $off = Get-RokuClockOffset $all
        $since = @($all | Where-Object Index -ge $mark)
        $t0 = (Get-RokuBeacon $since 'AppLaunchInitiate' | Select-Object -First 1).Dev
        $alc = Get-RokuBeacon $since 'AppLaunchComplete' | Select-Object -First 1
        $run = [ordered]@{
            appLaunchCompleteMs = $alc ? $alc.Ms : $null
            homeShownMs = Get-RokuMs $t0 (Get-RokuDevTime (Entry $all $iHome) $off)
            homeSettledMs = Get-RokuMs $t0 (Get-RokuDevTime (Entry $all $iQuiet) $off)
        }
        Note ("#{0}  AppLaunchComplete {1} ms · Home visible {2} ms · Home cargado {3} ms" -f $i, $run.appLaunchCompleteMs, $run.homeShownMs, $run.homeSettledMs)
        $runs += $run
    }
    $metrics['launch.appLaunchCompleteMs'] = Median ($runs | ForEach-Object appLaunchCompleteMs)
    $metrics['launch.homeShownMs'] = Median ($runs | ForEach-Object homeShownMs)
    $metrics['launch.homeSettledMs'] = Median ($runs | ForEach-Object homeSettledMs)
    $detail.launch = $runs
}

function Step-HomeSnapshot {
    $ui = Get-RokuUiState $S
    $perf = Get-RokuChanPerf $S; $tex = Get-RokuTextureUse $S; $nodes = Get-RokuNodeCounts $S
    $metrics['home.rows'] = $ui.HomeRows.Count
    $metrics['home.duplicateRows'] = $ui.DuplicateRows.Count
    $metrics['home.memUsedMB'] = $perf.MemUsedMB
    $metrics['home.textureUsedPct'] = $tex ? $tex.Pct : $null
    $metrics['home.nodes'] = $nodes.All
    $metrics['home.rootNodes'] = $nodes.Roots
    $detail.home = [ordered]@{ rows = @($ui.HomeRows | ForEach-Object Title); texture = $tex; memory = $perf }
    Note ("Home: {0} filas · memoria {1} MB · texturas {2}% de {3} MB · nodos {4} (raíces {5})" -f $ui.HomeRows.Count, $perf.MemUsedMB, $tex.Pct, $tex.MaxMB, $nodes.All, $nodes.Roots)
    if ($ui.DuplicateRows) { $fails.Add("Home con filas duplicadas: $($ui.DuplicateRows -join ', ')") }
}

function Step-Scroll {
    Info "Scroll del Home: $Scroll filas a $KeyIntervalMs ms, vuelta a $FastKeyIntervalMs ms, una fila a lo ancho"
    $ui = Go-Row 0
    if ($ui.HomeRow -ne 0) { $invalid.Add("scroll: no se pudo poner el foco en la primera fila ($($ui.FocusChain))"); return }
    $target = [Math]::Min($Scroll, $ui.HomeRows.Count - 1)
    $fail0 = $S.EcpFailures
    $mark = Get-RokuLogMark $S
    $smp = Start-Sampler
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Send-RokuKeys $S 'Down' $target $KeyIntervalMs
    $humanMs = [int]($sw.ElapsedMilliseconds / [Math]::Max(1, $target))
    Wait-RokuQuiet $S 1500 25 | Out-Null
    $row1 = (Get-RokuUiState $S).HomeRow
    $sw.Restart()
    Send-RokuKeys $S 'Up' $target $FastKeyIntervalMs
    $fastMs = [int]($sw.ElapsedMilliseconds / [Math]::Max(1, $target))
    Wait-RokuQuiet $S 1500 25 | Out-Null
    $row2 = (Get-RokuUiState $S).HomeRow
    Send-RokuKeys $S 'Down' 2 $KeyIntervalMs
    Send-RokuKeys $S 'Right' 10 $FastKeyIntervalMs
    Wait-RokuQuiet $S 1500 20 | Out-Null
    Send-RokuKeys $S 'Left' 10 $FastKeyIntervalMs
    Wait-RokuQuiet $S 1500 20 | Out-Null
    $sum = Summarize-Samples (Stop-Sampler $smp)
    Check-Crash $mark 'scroll' | Out-Null
    if ($S.EcpFailures -gt $fail0) { $invalid.Add("scroll: $($S.EcpFailures - $fail0) teclas/consultas ECP fallaron (no se puede contar teclas perdidas)") }

    $metrics['scroll.lostKeysHuman'] = ($null -ne $row1) ? [Math]::Max(0, $target - $row1) : $null
    $metrics['scroll.lostKeysFast'] = $row2
    $metrics['scroll.fpsMin'] = $sum.fpsMin
    $metrics['scroll.fpsMedian'] = $sum.fpsMedian
    $metrics['scroll.cpuMaxPct'] = $sum.cpuMaxPct
    $metrics['scroll.memDeltaMB'] = $sum.memDeltaMB
    $detail.scroll = [ordered]@{ target = $target; rowAfterDown = $row1; rowAfterUp = $row2; humanKeyMs = $humanMs; fastKeyMs = $fastMs; sampler = $sum }
    Note ("bajó a fila {0} de {1} (ritmo real {2} ms/tecla) · volvió a fila {3} (ritmo real {4} ms/tecla)" -f $row1, $target, $humanMs, $row2, $fastMs)
    Note ("fps min {0} · mediana {1} · CPU máx {2}% · Δmemoria {3} MB ({4} muestras)" -f $sum.fpsMin, $sum.fpsMedian, $sum.cpuMaxPct, $sum.memDeltaMB, $sum.samples)
    if ($metrics['scroll.lostKeysHuman'] -gt 0 -and $S.EcpFailures -eq $fail0) { $fails.Add("scroll: se perdieron $($metrics['scroll.lostKeysHuman']) teclas a ritmo humano") }
}

function Step-Show {
    Info "Fichas: '$($nav.showRow)' -> OK -> ficha -> Back, x$Cycles"
    $ui = Get-RokuUiState $S
    $row = -1; for ($i = 0; $i -lt $ui.HomeRows.Count; $i++) { if ($ui.HomeRows[$i].Title -eq $nav.showRow) { $row = $i; break } }
    if ($row -lt 0) { $invalid.Add("show: no hay fila '$($nav.showRow)' en el Home ($(@($ui.HomeRows | ForEach-Object Title) -join ' | '))"); return }
    $ui = Go-Row $row
    if ($ui.HomeRow -ne $row) { $invalid.Add("show: no se pudo enfocar la fila '$($nav.showRow)' (quedó en $($ui.HomeRow))"); return }
    $pages0 = $ui.Pages.Count
    $n0 = Get-RokuNodeCounts $S; $p0 = Get-RokuChanPerf $S
    $cyc = @()
    for ($c = 1; $c -le $Cycles; $c++) {
        $mark = Get-RokuLogMark $S
        $k = Send-RokuKey $S 'Select'
        $iShow = Wait-RokuLog $S 'ViewStack : showScreenshowPage' $mark 20
        if ($iShow -lt 0) { if (-not (Check-Crash $mark "ciclo $c")) { $fails.Add("show: el ciclo $c no abrió la ficha") }; break }
        $iQuiet = Wait-RokuQuiet $S 1500 25
        $all = ConvertFrom-RokuLog (Read-RokuLog $S)
        $open = KeyLatency $all $iShow $k; $settled = KeyLatency $all $iQuiet $k
        $markB = Get-RokuLogMark $S
        $kb = Send-RokuKey $S 'Back'
        $iBackQ = Wait-RokuQuiet $S 1500 20
        $back = KeyLatency (ConvertFrom-RokuLog (Read-RokuLog $S)) $iBackQ $kb
        if (Check-Crash $mark "ciclo $c") { break }
        $ui = Wait-RokuPage $S 'homePage' 10
        $nodes = Get-RokuNodeCounts $S; $perf = Get-RokuChanPerf $S; $tex = Get-RokuTextureUse $S
        $showNodes = @($ui.PageNodes | Where-Object Name -eq 'showPage' | ForEach-Object Count)
        $cyc += [ordered]@{ openMs = $open; settledMs = $settled; backMs = $back; topPage = $ui.TopPage; homeRow = $ui.HomeRow
            pages = $ui.Pages.Count; showPageNodes = ($showNodes ? $showNodes[0] : 0); nodes = $nodes.All; roots = $nodes.Roots
            memUsedMB = $perf.MemUsedMB; texturePct = $tex ? $tex.Pct : $null }
        Note ("#{0}  ficha {1} ms · cargada {2} ms · back {3} ms · nodos {4} · raíces {5} · mem {6} MB · nodos showPage {7}" -f $c, $open, $settled, $back, $nodes.All, $nodes.Roots, $perf.MemUsedMB, $cyc[-1].showPageNodes)
        if ($ui.TopPage -ne 'homePage') { $fails.Add("show: Back del ciclo $c dejó en $($ui.TopPage)"); break }
        if ($ui.HomeRow -ne $row) { $fails.Add("show: Back del ciclo $c no devolvió el foco a la fila (quedó en $($ui.HomeRow))"); $null = Go-Row $row }
    }
    if (-not $cyc) { return }
    $nodesSeries = @($n0.All) + @($cyc | ForEach-Object nodes)
    $memSeries = @($p0.MemUsedMB) + @($cyc | ForEach-Object memUsedMB)
    $metrics['show.openMsMedian'] = Median ($cyc | ForEach-Object openMs)
    $metrics['show.settledMsMedian'] = Median ($cyc | ForEach-Object settledMs)
    $metrics['show.backMsMedian'] = Median ($cyc | ForEach-Object backMs)
    $metrics['show.nodeGrowthPerCycle'] = Slope $nodesSeries
    $metrics['show.rootGrowthPerCycle'] = Slope (@($n0.Roots) + @($cyc | ForEach-Object roots))
    $metrics['show.memGrowthPerCycleMB'] = Slope $memSeries
    $metrics['show.pagesGrowth'] = $cyc[-1].pages - $pages0
    $metrics['show.showPageNodes'] = $cyc[-1].showPageNodes
    # Con 1 ciclo la "pendiente" es una sola resta: se reporta igual, pero el veredicto de fuga
    # necesita al menos 3 ciclos para no acusar por el costo normal de abrir la primera ficha.
    $metrics['show.cycles'] = $cyc.Count
    $detail.show = [ordered]@{ row = $row; before = [ordered]@{ nodes = $n0.All; roots = $n0.Roots; memUsedMB = $p0.MemUsedMB; pages = $pages0 }; cycles = $cyc }
    Note ("tendencia por ciclo: nodos {0:+0.##;-0.##;0} · raíces {1:+0.##;-0.##;0} · memoria {2:+0.##;-0.##;0} MB · páginas en el árbol {3} -> {4}" -f $metrics['show.nodeGrowthPerCycle'], $metrics['show.rootGrowthPerCycle'], $metrics['show.memGrowthPerCycleMB'], $pages0, $cyc[-1].pages)
    if ($cyc.Count -lt 3) { $invalid.Add("show: solo $($cyc.Count) ciclo(s) completo(s); la tendencia de nodos y memoria no es una pendiente, es una resta") }
    elseif ($cyc[-1].showPageNodes -ge $cyc.Count) { $fails.Add("show: cada apertura deja un nodo showPage en el árbol ($($cyc[-1].showPageNodes) nodos en $($cyc.Count) ciclos)") }
}

function Step-Menu {
    Info "Menú lateral: $($nav.menu -join ', ')"
    $detail.menu = [ordered]@{}
    foreach ($label in $nav.menu) {
        $ui = Get-RokuUiState $S
        if ($ui.TopPage -ne 'homePage') { Send-RokuKey $S 'Back' | Out-Null; $ui = Wait-RokuPage $S 'homePage' 10 }
        if ($ui.TopPage -ne 'homePage') { $null = Go-HomeSettled; $ui = Get-RokuUiState $S }
        if (-not $ui.InSideBar) { Send-RokuKey $S 'Left' | Out-Null; Wait-RokuQuiet $S 1000 10 | Out-Null; $ui = Get-RokuUiState $S }
        if (-not $ui.InSideBar) {
            $why = ($ui.Dialogs -contains 'NetworkDialog') ? "la app está mostrando su diálogo de sin conexión" : $ui.FocusChain
            $invalid.Add("menú: no se pudo abrir el menú lateral ($why)"); return
        }
        $ti = [array]::IndexOf($ui.SideBarItems, $label); $ci = [array]::IndexOf($ui.SideBarItems, $ui.SideBarFocus)
        if ($ti -lt 0) { $invalid.Add("menú: no hay ítem '$label' ($($ui.SideBarItems -join ' | '))"); continue }
        $d = $ti - $ci
        if ($d) { Send-RokuKeys $S ($d -gt 0 ? 'Down' : 'Up') ([Math]::Abs($d)) $KeyIntervalMs; Wait-RokuQuiet $S 800 10 | Out-Null; $ui = Get-RokuUiState $S }
        if ($ui.SideBarFocus -ne $label) { $invalid.Add("menú: el foco quedó en '$($ui.SideBarFocus)', no en '$label'"); continue }
        $mark = Get-RokuLogMark $S
        $smp = Start-Sampler
        $k = Send-RokuKey $S 'Select'
        $iPage = Wait-RokuLog $S 'ViewStack : showScreen\w+' $mark 20
        $iQuiet = Wait-RokuQuiet $S 2000 30
        $sum = Summarize-Samples (Stop-Sampler $smp)
        if (Check-Crash $mark "menú '$label'") { continue }
        if ($iPage -lt 0) { $fails.Add("menú: '$label' no abrió ninguna página"); continue }
        $lines = Read-RokuLog $S; $all = ConvertFrom-RokuLog $lines
        $page = ($lines[$iPage] -match 'showScreen(\w+)') ? $Matches[1] : '?'
        $m = [ordered]@{ page = $page; pageMs = KeyLatency $all $iPage $k; settledMs = KeyLatency $all $iQuiet $k; fpsMin = $sum.fpsMin; cpuMaxPct = $sum.cpuMaxPct }
        $detail.menu[$label] = $m
        $metrics["menu.$label.pageMs"] = $m.pageMs
        $metrics["menu.$label.settledMs"] = $m.settledMs
        Note ("{0,-10} -> {1,-14} página {2} ms · cargada {3} ms · fps min {4} · CPU máx {5}%" -f $label, $page, $m.pageMs, $m.settledMs, $sum.fpsMin, $sum.cpuMaxPct)
    }
}

# --- budgets y baseline ------------------------------------------------------------------

function Test-Budgets {
    $out = @()
    $max = @{ 'launch.appLaunchCompleteMs' = 'appLaunchCompleteMs'; 'launch.homeShownMs' = 'homeShownMs'; 'launch.homeSettledMs' = 'homeSettledMs'
        'show.openMsMedian' = 'openShowPageMs'; 'home.textureUsedPct' = 'textureUsedPctMax'; 'show.nodeGrowthPerCycle' = 'nodeGrowthPerCycleMax'
        'show.memGrowthPerCycleMB' = 'memGrowthPerCycleMaxMB' }
    foreach ($k in $max.Keys) { if ($null -ne $metrics[$k] -and $budgets.($max[$k])) { $out += [ordered]@{ metric = $k; value = $metrics[$k]; budget = $budgets.($max[$k]); ok = $metrics[$k] -le $budgets.($max[$k]) } } }
    foreach ($k in @($metrics.Keys | Where-Object { $_ -like 'menu.*.pageMs' })) { if ($null -ne $metrics[$k] -and $budgets.menuPageMs) { $out += [ordered]@{ metric = $k; value = $metrics[$k]; budget = $budgets.menuPageMs; ok = $metrics[$k] -le $budgets.menuPageMs } } }
    # fps NO tiene budget: ECP graphics-frame-rate devuelve casi cero cuando la escena está
    # quieta (medido en .46: 4.2, 0.0 y 20.5 fps seguidos sobre una pantalla estática), así que
    # un mínimo sobre una serie de muestras no distingue "trabado" de "no había nada que dibujar".
    # Se reporta como dato y se compara contra baseline, pero no decide el veredicto.
    $out
}

function Compare-Baseline {
    if (-not $Baseline) { return @() }
    $b = (Get-Content $Baseline -Raw | ConvertFrom-Json).metrics
    $out = @()
    foreach ($k in $metrics.Keys) {
        $prop = $b.PSObject.Properties[$k]
        if (-not $prop -or $null -eq $prop.Value -or $null -eq $metrics[$k] -or $prop.Value -eq 0) { continue }
        $pct = [Math]::Round(100 * ($metrics[$k] - $prop.Value) / [Math]::Abs($prop.Value), 1)
        $worse = ($k -like '*fps*') ? (-$pct) : $pct
        $out += [ordered]@{ metric = $k; baseline = $prop.Value; value = $metrics[$k]; deltaPct = $pct; regression = $worse -gt $RegressionPct }
    }
    $out
}

# --- corrida ------------------------------------------------------------------------------
$exit = 3
try {
    $device = Get-RokuDeviceSummary $S
    Info "Rendimiento de navegación de $Client en $($S.Host): $($device.model) fw $($device.firmware) · $($device.uiResolution) · red $($device.network)"
    Start-RokuTestConsole $S
    $mark0 = Get-RokuLogMark $S

    # Cada paso aislado: un timeout de ECP en el último paso no puede tirar la corrida entera y
    # perder lo ya medido. El paso que falla queda como "no medido" y el reporte se escribe igual.
    $run = { param([string]$name, [scriptblock]$body)
        try { & $body }
        catch { $invalid.Add("paso '$name' interrumpido: $($_.Exception.Message)"); Write-Host "    !   paso '$name' interrumpido: $($_.Exception.Message)" -ForegroundColor Yellow }
    }
    if ($Steps -contains 'launch') { & $run 'launch' { Step-Launch } } else { & $run 'launch' { $null = Go-HomeSettled } }
    $version = try { $a = Get-RokuActiveApp $S; "$($a.Name) v$($a.Version)" } catch { 'desconocida' }
    Note "app: $version"
    & $run 'home' { Step-HomeSnapshot }
    if ($Steps -contains 'scroll') { & $run 'scroll' { Step-Scroll } }
    if ($Steps -contains 'show') { & $run 'show' { Step-Show } }
    if ($Steps -contains 'menu') { & $run 'menu' { Step-Menu } }

    $linesEnd = Read-RokuLog $S; $parsedEnd = ConvertFrom-RokuLog $linesEnd
    $net = Get-RokuNetHealth $S 0 0 $linesEnd $mark0 -Parsed $parsedEnd -OffsetMs (Get-RokuClockOffset $parsedEnd)
    $budgetChecks = @(Test-Budgets)
    $regressions = @(Compare-Baseline)

    Write-Host ''
    Info 'Budgets'
    foreach ($b in $budgetChecks) { Write-Host ('    {0}  {1,-30} {2} (budget {3})' -f ($b.ok ? 'ok ' : 'NO '), $b.metric, $b.value, $b.budget) -ForegroundColor ($b.ok ? 'Green' : 'Magenta') }
    if ($regressions) {
        Info "Contra baseline ($Baseline)"
        foreach ($r in $regressions) { Write-Host ('    {0}  {1,-30} {2} -> {3} ({4:+0.#;-0.#;0}%)' -f ($r.regression ? 'REG' : 'ok '), $r.metric, $r.baseline, $r.value, $r.deltaPct) -ForegroundColor ($r.regression ? 'Magenta' : 'Gray') }
    }
    Note ("red: RTT mediana {0} ms · p90 {1} ms · fallas ECP {2} · eventos de caída {3} · atraso máx. de consola {4} ms" -f $net.RttMedianMs, $net.RttP90Ms, $net.EcpFailures, $net.InternetDrops, $net.ConsoleLagMaxMs)

    $slow = @($budgetChecks | Where-Object { -not $_.ok } | ForEach-Object { "$($_.metric) $($_.value) > $($_.budget)" }) + @($regressions | Where-Object regression | ForEach-Object { "$($_.metric) $($_.deltaPct)% vs baseline" })
    $hard = @($fails | Where-Object { $_ -match '^crash|filas duplicadas' })
    $verdict, $reason = if ($hard) { 'FAIL', ($fails -join '; ') }
        elseif ($net.Degraded) { 'INVALIDO', "red degradada: $($net.Reason)$(if ($fails) { "; además: $($fails -join '; ')" })" }
        elseif ($fails) { 'FAIL', ($fails -join '; ') }
        elseif ($invalid) { 'INVALIDO', ($invalid -join '; ') }
        elseif ($slow) { 'LENTO', ($slow -join '; ') }
        else { 'PASS', '' }
    Write-Host ''
    Write-RokuVerdict $verdict $reason
    foreach ($n in $invalid) { Note "no medido: $n" }

    $json = Save-RokuTestReport $S ([ordered]@{
        timestamp = (Get-Date).ToString('o'); client = $Client; rokuHost = $S.Host; device = $device; app = $version
        verdict = $verdict; reason = $reason; metrics = $metrics; budgets = $budgetChecks; baseline = $Baseline; regressions = $regressions
        failures = $fails; notMeasured = $invalid; network = $net; detail = $detail; log = $S.Log })
    Note "reporte: $json"
    $exit = @{ PASS = 0; FAIL = 1; LENTO = 1; INVALIDO = 2 }[$verdict]
}
catch { Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red; Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray; $exit = 3 }
finally { Stop-RokuTestConsole $S }
exit $exit
