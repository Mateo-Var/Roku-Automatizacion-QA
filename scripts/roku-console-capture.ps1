<#
.SYNOPSIS
  Captura la consola de depuración del Roku (puerto 8085) a un archivo.

.DESCRIPTION
  Pensado para correr como proceso hijo mientras otro script maneja el device
  por ECP. Dos detalles que importan y que se aprendieron a los golpes:

  - Al conectar, el Roku vuelca un backlog de lo ya ocurrido. Se escribe un
    marcador cuando ese volcado termina (primer silencio de 1s), para no
    confundir historia vieja con lo que pasa en vivo durante una prueba.
  - El archivo se abre con FileShare.ReadWrite: sin eso, el proceso que
    interpreta el log no puede leerlo mientras se escribe.

  Solo puede haber UNA conexión a la consola a la vez. Si otra la tiene, el
  Roku responde "Console connection is already in use." y este script termina
  con exit 2 en vez de quedarse colgado en silencio.

.EXAMPLE
  pwsh roku-console-capture.ps1 -RokuHost 192.168.1.186 -OutFile run.log
#>
param(
    [string]$RokuHost = $env:ROKU_HOST,
    [int]$Port = 8085,
    [Parameter(Mandatory)][string]$OutFile
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RokuDev.psm1') -Force; Import-RokuEnv
if (-not $RokuHost) { $RokuHost = $env:ROKU_HOST }
if (-not $RokuHost) { Write-Error 'Falta -RokuHost o ROKU_HOST. Listá los equipos con roku-devices.ps1.'; exit 3 }

$socket = New-Object System.Net.Sockets.TcpClient
try {
    $socket.Connect($RokuHost, $Port)
} catch {
    Write-Error "No se pudo conectar a ${RokuHost}:${Port} - $_"
    exit 3
}

$stream = $socket.GetStream()
$reader = New-Object System.IO.StreamReader $stream

$fs = New-Object System.IO.FileStream $OutFile,
    ([System.IO.FileMode]::Create),
    ([System.IO.FileAccess]::Write),
    ([System.IO.FileShare]::ReadWrite)
$out = New-Object System.IO.StreamWriter $fs
$out.AutoFlush = $true

function Emit($text) {
    $out.WriteLine(("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss.fff'), $text))
}

Emit "=== CAPTURA INICIADA ${RokuHost}:${Port} ==="

$backlogDone = $false
$lastData = Get-Date

try {
    while ($true) {
        if ($stream.DataAvailable) {
            $line = $reader.ReadLine()
            if ($null -ne $line) {
                Emit $line
                $lastData = Get-Date
                if ($line -match 'Console connection is already in use') {
                    Emit '=== ABORTA: otra sesion tiene la consola ==='
                    exit 2
                }
            }
        }
        else {
            if (-not $backlogDone -and ((Get-Date) - $lastData).TotalMilliseconds -gt 1000) {
                Emit '=== FIN DEL BACKLOG - DESDE ACA ES EN VIVO ==='
                $backlogDone = $true
            }
            Start-Sleep -Milliseconds 50
        }
    }
}
finally {
    $out.Flush(); $out.Close(); $fs.Close()
    $reader.Close(); $socket.Close()
}
