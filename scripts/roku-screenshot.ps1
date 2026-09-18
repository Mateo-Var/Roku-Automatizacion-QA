<#
.SYNOPSIS
  Baja una captura de la pantalla actual del Roku en dev mode.

.DESCRIPTION
  Dos pasos: se le pide al device que tome la captura (/plugin_inspect con
  mysubmit=Screenshot) y despues se baja el jpg de /pkgs/dev.jpg. Ambos van con
  digest auth del usuario rokudev. Sirve para ver donde quedo el foco cuando un
  test automatizado no hace lo que se esperaba.

.EXAMPLE
  pwsh roku-screenshot.ps1 -OutFile pantalla.jpg
#>
param(
    [string]$RokuHost = $env:ROKU_HOST,
    [string]$DevPassword = $(if ($env:ROKU_DEV_PASSWORD) { $env:ROKU_DEV_PASSWORD } else { '1234' }),
    [Parameter(Mandatory)][string]$OutFile
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RokuDev.psm1') -Force; Import-RokuEnv
if (-not $RokuHost) { $RokuHost = $env:ROKU_HOST }
if (-not $PSBoundParameters.ContainsKey('DevPassword')) { $DevPassword = Get-RokuDevPassword }
if (-not $RokuHost) { Write-Error 'Falta -RokuHost o ROKU_HOST. Listá los equipos con roku-devices.ps1.'; exit 3 }
$cred = "rokudev:$DevPassword"
$devnull = if ($IsWindows -or $env:OS -eq 'Windows_NT') { 'NUL' } else { '/dev/null' }

curl.exe -s --digest -u $cred --max-time 20 `
    -F 'mysubmit=Screenshot' -F 'archive=' -F 'passwd=' `
    "http://$RokuHost/plugin_inspect" -o $devnull

$code = curl.exe -s --digest -u $cred --max-time 20 -w '%{http_code}' `
    "http://$RokuHost/pkgs/dev.jpg?time=$([DateTimeOffset]::Now.ToUnixTimeSeconds())" -o $OutFile

if ($code -ne '200') { Write-Error "El device devolvio HTTP $code al bajar la captura."; exit 1 }

$size = (Get-Item $OutFile).Length
if ($size -lt 2000) { Write-Error "La captura salio de $size bytes: probablemente sea un HTML de error, no un jpg."; exit 1 }
Write-Host ("captura: {0} ({1:N0} KB)" -f $OutFile, ($size / 1KB))
