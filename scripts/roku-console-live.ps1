<#
  Consola de depuracion del Roku EN VIVO (puerto 8085), en pantalla y a archivo.
  Ctrl+C corta. Solo puede haber UNA conexion al 8085 a la vez.
#>
param(
    [string]$RokuHost = $env:ROKU_HOST,
    [int]$Port = 8085,
    [string]$OutFile,
    # Si el Roku responde "Console connection is already in use" sin ningún proceso local
    # conectado, es una sesión muerta del lado del device: se reintenta hasta este tope.
    [int]$WaitBusySec = 240
)

Import-Module (Join-Path $PSScriptRoot 'RokuDev.psm1') -Force; Import-RokuEnv
if (-not $RokuHost) { $RokuHost = $env:ROKU_HOST }
if (-not $RokuHost) { Write-Host 'Falta -RokuHost o ROKU_HOST.' -ForegroundColor Red; exit 3 }
$Host.UI.RawUI.WindowTitle = "Roku console $RokuHost`:$Port"

if (-not $OutFile) {
    $OutFile = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')).Path ("test-runs\sesion-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
New-Item -ItemType Directory -Force -Path (Split-Path $OutFile) | Out-Null

Write-Host "Conectando a ${RokuHost}:${Port} ..." -ForegroundColor Cyan
$deadline = (Get-Date).AddSeconds($WaitBusySec)
while ($true) {
    $socket = New-Object System.Net.Sockets.TcpClient
    try { $socket.Connect($RokuHost, $Port) }
    catch {
        Write-Host "No se pudo conectar: $_" -ForegroundColor Red
        Write-Host "Enter para cerrar."; [void][Console]::ReadLine(); exit 3
    }
    # El Roku avisa "ocupada" apenas se conecta; si en 1,5 s no llega eso, la consola es nuestra.
    $probe = New-Object System.IO.StreamReader $socket.GetStream()
    $sw = [Diagnostics.Stopwatch]::StartNew(); $first = $null
    while ($sw.ElapsedMilliseconds -lt 1500 -and -not $first) {
        if ($socket.GetStream().DataAvailable) { $first = $probe.ReadLine() } else { Start-Sleep -Milliseconds 50 }
    }
    if ($first -notmatch 'Console connection is already in use') { $pending = $first; break }
    $socket.Close()
    if ((Get-Date) -ge $deadline) {
        Write-Host "La consola sigue ocupada después de $WaitBusySec s. Si no hay un proceso local conectado es una sesión muerta del Roku: reiniciarlo la libera." -ForegroundColor Red
        Write-Host "Enter para cerrar."; [void][Console]::ReadLine(); exit 2
    }
    Write-Host ("[{0}] consola ocupada por una sesión muerta del Roku; reintento en 10 s..." -f (Get-Date -Format 'HH:mm:ss')) -ForegroundColor Yellow
    Start-Sleep -Seconds 10
}

$reader = $probe
$fs  = New-Object System.IO.FileStream $OutFile, 'Create', 'Write', 'ReadWrite'
$out = New-Object System.IO.StreamWriter $fs
$out.AutoFlush = $true

Write-Host "Log: $OutFile" -ForegroundColor Cyan
Write-Host "Ctrl+C para cortar.`n" -ForegroundColor DarkGray

$backlogDone = $false
$lastData = Get-Date

function Show($line) {
    $color = 'Gray'
    if     ($line -match "ERROR|'Dot' Operator|Micro Debugger|Compilation Failed|Failed") { $color = 'Red' }
    elseif ($line -match 'WARN|Not found|404')                                            { $color = 'Yellow' }
    elseif ($line -match 'MediaStreamPlayer|RAFPlayerTask|ViewStack')                      { $color = 'Cyan' }
    $stamped = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss.fff'), $line
    Write-Host $stamped -ForegroundColor $color
    $out.WriteLine($stamped)
}

try {
    if ($pending) { Show $pending }
    while ($true) {
        if ($socket.Client.Poll(0, [System.Net.Sockets.SelectMode]::SelectRead) -and -not $socket.GetStream().DataAvailable) {
            Write-Host "`n=== EL ROKU CERRO LA CONEXION ===" -ForegroundColor Red
            break
        }
        if ($socket.GetStream().DataAvailable) {
            $line = $reader.ReadLine()
            if ($null -ne $line) {
                Show $line
                $lastData = Get-Date
                if ($line -match 'Console connection is already in use') {
                    Write-Host "`n=== OTRA SESION TIENE LA CONSOLA (VS Code, telnet u otra ventana) ===" -ForegroundColor Red
                    Write-Host "Cerrala y volve a abrir esta ventana." -ForegroundColor Red
                    break
                }
            }
        }
        else {
            if (-not $backlogDone -and ((Get-Date) - $lastData).TotalMilliseconds -gt 1000) {
                Write-Host ("=" * 70) -ForegroundColor Magenta
                Write-Host "=== FIN DEL BACKLOG - DESDE ACA ES EN VIVO ===" -ForegroundColor Magenta
                Write-Host ("=" * 70) -ForegroundColor Magenta
                $out.WriteLine('=== FIN DEL BACKLOG - DESDE ACA ES EN VIVO ===')
                $backlogDone = $true
            }
            Start-Sleep -Milliseconds 50
        }
    }
}
finally {
    $out.Flush(); $out.Close(); $fs.Close(); $reader.Close(); $socket.Close()
    Write-Host "`nLog guardado en: $OutFile" -ForegroundColor Cyan
    Write-Host "Enter para cerrar la ventana."
    [void][Console]::ReadLine()
}
