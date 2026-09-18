# Graba el monitor donde está Suitest (el NO-primario), detectando sus
# coordenadas en vivo en cada corrida en vez de usar valores fijos --
# así no se rompe si se reordenan/reconectan los monitores.
#
# IMPORTANTE (fix): -Stop ya NO mata ffmpeg con Stop-Process -Force. Eso
# dejaba el .mp4 sin el índice final (moov atom) y el archivo quedaba
# corrupto/no reproducible (pasó con 13 videos de una corrida real). Ahora
# -Start lanza un proceso "wrapper" de PowerShell que mantiene abierto el
# stdin de ffmpeg; -Stop le pide a ese wrapper que le escriba "q" a ffmpeg
# (la forma correcta de pedirle que cierre el archivo bien) y espera a que
# el proceso termine solo antes de devolver el control.
#
# Uso:
#   .\record-suitest.ps1 -OutFile "reports\azteca\player\run1\suitest.mp4" -Seconds 30
#   .\record-suitest.ps1 -OutFile "...\suitest.mp4" -Start   (arranca en background, sin límite de tiempo)
#   .\record-suitest.ps1 -Stop                                (corta la grabación en background, prolijo)

param(
  [string]$OutFile,
  [int]$Seconds = 0,
  [switch]$Start,
  [switch]$Stop
)

$ErrorActionPreference = "Stop"
$wrapperPidFile = "$PSScriptRoot\.suitest-record.wrapper.pid"
$stopFlagFile = "$PSScriptRoot\.suitest-record.stopflag"
$outFileRecordFile = "$PSScriptRoot\.suitest-record.outfile"

if ($Stop) {
  if (-not (Test-Path $wrapperPidFile)) {
    Write-Output "No hay grabación en curso (no existe $wrapperPidFile)."
    return
  }
  $wrapperPid = Get-Content $wrapperPidFile
  New-Item -ItemType File -Path $stopFlagFile -Force | Out-Null

  # Esperar a que el wrapper vea la flag, le pida a ffmpeg que cierre bien
  # el archivo, y termine solo -- hasta 15s, después recién forzamos.
  $waited = 0
  while ((Get-Process -Id $wrapperPid -ErrorAction SilentlyContinue) -and $waited -lt 15) {
    Start-Sleep -Milliseconds 500
    $waited += 0.5
  }
  if (Get-Process -Id $wrapperPid -ErrorAction SilentlyContinue) {
    Write-Output "ADVERTENCIA: el wrapper (PID $wrapperPid) no cerró solo tras 15s, forzando -- el video puede quedar corrupto."
    Stop-Process -Id $wrapperPid -Force -ErrorAction SilentlyContinue
  } else {
    Write-Output "Grabación detenida prolijamente (wrapper PID $wrapperPid)."
  }
  Remove-Item $wrapperPidFile, $stopFlagFile -Force -ErrorAction SilentlyContinue
  return
}

Add-Type -AssemblyName System.Windows.Forms
$monitor = [System.Windows.Forms.Screen]::AllScreens | Where-Object { -not $_.Primary } | Select-Object -First 1
if (-not $monitor) {
  throw "No se encontró un monitor no-primario. Monitores detectados: $([System.Windows.Forms.Screen]::AllScreens | ForEach-Object { $_.DeviceName })"
}

# Screen.Bounds da coordenadas LÓGICAS (afectadas por el escalado DPI de
# Windows), pero gdigrab captura píxeles FÍSICOS. Si el monitor tiene un
# escalado distinto de 100%, usar Bounds directo recorta la imagen. Para
# evitarlo, se calcula el factor de escala real de ESE monitor comparando
# su ancho lógico contra la resolución física reportada por su modo de
# video actual (WMI), y se escala el offset/tamaño a píxeles físicos.
$x = $monitor.Bounds.X
$y = $monitor.Bounds.Y
$logicalW = $monitor.Bounds.Width
$logicalH = $monitor.Bounds.Height

$physical = Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue |
  Where-Object { $_.CurrentHorizontalResolution } | Select-Object -First 1
if ($physical -and $physical.CurrentHorizontalResolution -and $logicalW -ne 0) {
  $scale = [math]::Round($physical.CurrentHorizontalResolution / $logicalW, 3)
} else {
  $scale = 1
}
if ($scale -lt 1 -or $scale -gt 2.5) { $scale = 1 }

$w = [int]([math]::Round($logicalW * $scale))
$h = [int]([math]::Round($logicalH * $scale))
Write-Output "Monitor detectado: $($monitor.DeviceName) escala=$scale offset=($x,$y) tamaño=${w}x${h}"

if (-not $OutFile) { throw "Falta -OutFile" }
$outDir = Split-Path $OutFile -Parent
if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
$OutFileAbs = (Resolve-Path -Path $outDir).Path + "\" + (Split-Path $OutFile -Leaf)

$commonArgsStr = "-y -f gdigrab -framerate 10 -offset_x $x -offset_y $y -video_size ${w}x${h} -i desktop -c:v libx264 -pix_fmt yuv420p -profile:v baseline -level 3.0 -preset veryfast"

if ($Start) {
  if (Test-Path $stopFlagFile) { Remove-Item $stopFlagFile -Force -ErrorAction SilentlyContinue }

  # El wrapper corre en su propio proceso de PowerShell, oculto, y es dueño
  # del stdin de ffmpeg durante toda la grabación -- por eso sobrevive
  # aunque este script (el que llama -Start) termine enseguida.
  $wrapperScript = @"
`$psi = New-Object System.Diagnostics.ProcessStartInfo
`$psi.FileName = 'ffmpeg'
`$psi.Arguments = '$commonArgsStr "$OutFileAbs"'
`$psi.RedirectStandardInput = `$true
`$psi.UseShellExecute = `$false
`$psi.CreateNoWindow = `$true
`$p = [System.Diagnostics.Process]::Start(`$psi)
while (-not (Test-Path '$stopFlagFile')) {
  if (`$p.HasExited) { break }
  Start-Sleep -Milliseconds 300
}
if (-not `$p.HasExited) {
  `$p.StandardInput.Write('q')
  `$p.StandardInput.Flush()
  `$p.WaitForExit(10000) | Out-Null
  if (-not `$p.HasExited) { `$p.Kill() }
}
"@
  $wrapperScriptFile = "$PSScriptRoot\.suitest-record.wrapper.ps1"
  Set-Content -Path $wrapperScriptFile -Value $wrapperScript -Encoding UTF8

  $wrapperProc = Start-Process -FilePath "powershell" -ArgumentList @("-NoProfile", "-WindowStyle", "Hidden", "-File", $wrapperScriptFile) -PassThru -WindowStyle Hidden
  Set-Content -Path $wrapperPidFile -Value $wrapperProc.Id
  Set-Content -Path $outFileRecordFile -Value $OutFileAbs
  Write-Output "Grabando en background (wrapper PID $($wrapperProc.Id)) -> $OutFileAbs"
} else {
  if ($Seconds -le 0) { throw "Especificá -Seconds N o usá -Start para grabar sin límite" }
  & ffmpeg -y -f gdigrab -framerate 10 -offset_x $x -offset_y $y -video_size "${w}x${h}" -i desktop -c:v libx264 -pix_fmt yuv420p -profile:v baseline -level 3.0 -preset veryfast -t $Seconds $OutFile
  Write-Output "Grabación de $Seconds s guardada en $OutFile"
}
