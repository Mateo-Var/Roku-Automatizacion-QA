<#
  RokuDev.psm1 -- utilidades mínimas de entorno/device que usan los scripts de
  scripts/ (RokuTest.psm1 y los standalone test-vod-analytics.ps1 /
  test-player-multipress.ps1 / roku-console-capture.ps1 / roku-console-live.ps1 /
  roku-devices.ps1 / roku-screenshot.ps1).

  Reescrito el 2026-09-17 al integrar los 12 scripts de la batería de
  automatización de device: el módulo original (roku-ott/scripts/RokuDev.psm1)
  vivía en un repo hermano que no está presente en esta máquina. Estas 4
  funciones son una reimplementación desde cero, deliberadamente simple: leer
  el .env del proyecto y consultar ECP query/device-info por HTTP. No se
  inventó ningún comportamiento adicional que no esté ya consumido por los
  scripts (Get-RokuDeviceInfo, por ejemplo, no resuelve "key owner": ninguno
  de los scripts migrados depende de un signing-keys.json, así que esa
  propiedad queda simplemente ausente/$null si algún consumidor la pide).
#>

$ErrorActionPreference = 'Stop'

# Raíz del proyecto: este módulo vive en <raíz>\scripts\RokuDev.psm1.
function Get-RokuWorkspace {
    (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}

# Carga <raíz>\.env (formato KEY=VALUE, una por línea, '#' comentario) en
# variables de entorno del proceso -- sin pisar una que ya esté seteada
# explícitamente (para no pelearse con un override de sesión).
function Import-RokuEnv {
    param([string]$Path)
    if (-not $Path) { $Path = Join-Path (Get-RokuWorkspace) '.env' }
    if (-not (Test-Path $Path)) { return }
    foreach ($line in Get-Content $Path) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        $i = $t.IndexOf('=')
        if ($i -lt 0) { continue }
        $key = $t.Substring(0, $i).Trim()
        $val = $t.Substring($i + 1).Trim()
        if (-not (Test-Path "env:$key")) { Set-Item -Path "env:$key" -Value $val }
    }
}

# query/device-info por ECP, sin password (el endpoint no la pide).
function Get-RokuDeviceInfo {
    param([Parameter(Mandatory)][string]$RokuHost, [int]$TimeoutSec = 5)
    $x = [xml](Invoke-WebRequest "http://${RokuHost}:8060/query/device-info" -TimeoutSec $TimeoutSec).Content
    $d = $x.'device-info'
    [pscustomobject]@{
        Name        = $d.'friendly-device-name'
        Model       = $d.'model-name'
        ModelNumber = $d.'model-number'
        Firmware    = $d.'software-version'
        DevMode     = ($d.'developer-enabled' -eq 'true')
        DevId       = $d.'keyed-developer-id'
        Serial      = $d.'serial-number'
        KeyOwner    = $null   # no hay signing-keys.json en este proyecto; queda sin resolver
    }
}

# Password de dev: -DevPassword explícito (lo resuelve el propio script
# llamador), si no ROKU_DEV_PASSWORD del entorno/.env, si no el default de
# fábrica de Roku dev mode.
function Get-RokuDevPassword {
    Import-RokuEnv
    if ($env:ROKU_DEV_PASSWORD) { return $env:ROKU_DEV_PASSWORD }
    '1234'
}

Export-ModuleMember -Function *
