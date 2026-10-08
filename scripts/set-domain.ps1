<#
  Moves the site to your own domain in one step.

  Usage (from the repo root), after you've bought the domain:
    powershell -ExecutionPolicy Bypass -File scripts\set-domain.ps1 -Domain findyourrecipe.com

  It rewrites the site address in index.html, js/config.js, sitemap.xml, robots.txt and 404.html,
  and writes the CNAME file GitHub Pages needs. Then commit, push, and finish the DNS steps in the README.
#>
param([Parameter(Mandatory)][string]$Domain)

$Domain = $Domain.Trim().ToLower() -replace '^https?://', '' -replace '/.*$', ''
$root = Split-Path -Parent $PSScriptRoot
$utf8 = New-Object System.Text.UTF8Encoding($false)
$newUrl = "https://$Domain/"

foreach ($file in 'index.html', 'js\config.js', 'sitemap.xml', 'robots.txt', '404.html', 'manifest.webmanifest') {
  $path = Join-Path $root $file
  if (-not (Test-Path $path)) { continue }
  $text = [IO.File]::ReadAllText($path, $utf8)
  $updated = $text -replace 'https://[a-z0-9.-]+\.github\.io/FindYourRecipe/', $newUrl `
                   -replace 'https://(?!fonts|cdn|challenges|gc\.)[a-z0-9-]+\.[a-z.]+/(?=sitemap\.xml)', $newUrl
  if ($file -eq '404.html') { $updated = $updated -replace '/FindYourRecipe/', '/' }
  if ($updated -ne $text) { [IO.File]::WriteAllText($path, $updated, $utf8); Write-Host "Updated $file" }
}

[IO.File]::WriteAllText((Join-Path $root 'CNAME'), "$Domain`n", $utf8)
Write-Host "Wrote CNAME for $Domain"
Write-Host "Next: commit and push, then follow 'Your own domain' in README.md."
