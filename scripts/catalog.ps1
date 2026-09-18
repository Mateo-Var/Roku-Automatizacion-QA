<#
.SYNOPSIS
  Valida el catálogo de datos de prueba de un cliente contra la API de contenido, y propone
  reemplazos cuando algo rotó.

.DESCRIPTION
  El catálogo (scenarios/clients/<cliente>/catalog.json) fija IDs reales para que los tests no dependan de "el
  primer tile del Home", que cambia todos los días. Pero el contenido rota: un episodio se
  despublica, un live se queda sin programación. Este script consulta la misma API GraphQL que
  usa la app (y con los mismos query_name, que son los que resuelven el token sin sesión) y dice,
  por entrada, si sigue sirviendo para lo que promete:

    live      existe, tiene token anónimo y tiene un programa EN CURSO (sin programa en curso el
              deep link no reproduce: el Core cierra el diálogo y deja al usuario en el Home)
    episode   existe, tiene token anónimo y apunta al mismo media
    series    el id resuelve a un show (o a un episodio de un show)
    media     existe y el token coincide con lo esperado (play = con token, login = sin token)

  Los tests de deep link usan esta misma validación antes de cada caso y marcan INVALIDO lo que
  no pasa: un contenido caído no es un bug de la app.

  No toca el Roku. La x-client-id se resuelve en runtime del config público de la app.

.EXAMPLE
  pwsh catalog.ps1 -Client azteca              # valida todo el catálogo; exit 1 si algo falla
  pwsh catalog.ps1 -Client azteca -Discover    # además lista candidatos para reemplazar
#>
param(
    [string]$Client = 'azteca',
    [switch]$Discover
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RokuTest.psm1') -Force

$cat = Get-RokuTestCatalog $Client
Write-Host "==> Catálogo $Client ($($cat.ottId), verificado $($cat.verified.date))" -ForegroundColor Cyan
$api = Get-OttApi $cat
Write-Host "    API: $($api.Url)"

$broken = 0
foreach ($e in $cat.content) {
    $r = Test-OttCatalogEntry $api $e
    if (-not $r.Ok) { $broken++ }
    $mark = $r.Ok ? 'ok  ' : 'NO  '
    Write-Host ('    {0}{1,-26} {2,-8} {3}' -f $mark, $e.key, $e.mediaType, ($r.Ok ? $r.Detail : $r.Reason)) -ForegroundColor ($r.Ok ? 'Green' : 'Red')
}

if ($Discover) {
    Write-Host "`n==> Lives (ahora, con programa en curso)" -ForegroundColor Cyan
    $lives = (Invoke-OttGraph $api 'query getAllLives{ getLives{ _id name } }' @{} 'getAllLives').data.getLives
    foreach ($l in $lives) {
        $r = Test-OttCatalogEntry $api ([pscustomobject]@{ kind = 'live'; contentId = $l._id })
        Write-Host ('    {0}  {1,-30} {2}' -f $l._id, $l.name, ($r.Ok ? $r.Detail : $r.Reason))
    }
    Write-Host "`n==> Shows por categoría (con su último episodio)" -ForegroundColor Cyan
    $q = 'query getAllCategories($limit:Int=30){ getCategoriesPaginated(page:{limit:$limit}){ data { ...on Category { name content(page:{limit:2}){ data { ...on Show { _id title lastEpisode{ _id } } } } } } } }'
    $cats = (Invoke-OttGraph $api $q @{ limit = 30 } 'getAllCategories').data.getCategoriesPaginated.data
    foreach ($c in $cats) {
        foreach ($s in @($c.content.data | Where-Object { $_ -and $_.PSObject.Properties['_id'] })) {
            $ep = $s.lastEpisode ? $s.lastEpisode._id : '-'
            Write-Host ('    {0,-24} show {1}  último episodio {2}  {3}' -f $c.name.Substring(0, [Math]::Min(24, $c.name.Length)), $s._id, $ep, $s.title)
        }
    }
}

Write-Host ''
if ($broken) { Write-Host "==> $broken entradas no sirven: reemplazarlas (probá -Discover)" -ForegroundColor Red; exit 1 }
Write-Host '==> Catálogo vigente' -ForegroundColor Green
