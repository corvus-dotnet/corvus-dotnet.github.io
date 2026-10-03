<#
.SYNOPSIS
Updates the stars, forks and primary language on each project card in index.html from GitHub.

.DESCRIPTION
Each card's footer names its repository (<footer data-repo="owner/name">). One GraphQL query reads every repository's
star and fork counts and primary language, and the footer's spans are rewritten in place: icon-stars, icon-forks, and
icon-lang unless the span has a data-languages attribute (a card that lists its languages by hand). Nothing else in the
file changes. Prints whether the file changed.

Needs the GitHub CLI (gh), authenticated (GH_TOKEN in GitHub Actions).

.PARAMETER Path
The page to update (default: index.html, next to this script).
#>
[CmdletBinding()]
param(
    [string] $Path = (Join-Path $PSScriptRoot "index.html")
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$html = [IO.File]::ReadAllText($Path)
$footer = '(?s)<footer data-repo="(?<repo>[^"]+)">(?<body>.*?)</footer>'
$repos = @([regex]::Matches($html, $footer) | ForEach-Object { $_.Groups["repo"].Value } | Select-Object -Unique)
if ($repos.Count -eq 0) {
    throw "No <footer data-repo=...> in $Path"
}

# One query for every repository, each under an alias (r0, r1, ...).
$fields = for ($i = 0; $i -lt $repos.Count; $i++) {
    $owner, $name = $repos[$i].Split("/")
    "r${i}: repository(owner: `"$owner`", name: `"$name`") { stargazerCount forkCount primaryLanguage { name } }"
}
$response = gh api graphql -f query="query { $($fields -join ' ') }" | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) {
    throw "The GitHub query failed"
}
$stats = @{}
for ($i = 0; $i -lt $repos.Count; $i++) {
    $repository = $response.data."r$i"
    if (-not $repository) {
        throw "GitHub returned nothing for $($repos[$i])"
    }
    $stats[$repos[$i]] = $repository
}

$updated = [regex]::Replace($html, $footer, {
    param($m)
    $s = $stats[$m.Groups["repo"].Value]
    $body = $m.Groups["body"].Value
    $body = $body -replace '(<span class="icon-stars">)[^<]*(</span>)', "`${1}$($s.stargazerCount)`${2}"
    $body = $body -replace '(<span class="icon-forks">)[^<]*(</span>)', "`${1}$($s.forkCount)`${2}"
    if ($s.primaryLanguage) {
        $body = $body -replace '(<span class="icon-lang">)[^<]*(</span>)', "`${1}$($s.primaryLanguage.name)`${2}"
    }
    "<footer data-repo=`"$($m.Groups['repo'].Value)`">$body</footer>"
})

foreach ($repo in $repos) {
    $s = $stats[$repo]
    Write-Host "$repo`: $($s.stargazerCount) stars, $($s.forkCount) forks, $(if ($s.primaryLanguage) { $s.primaryLanguage.name } else { 'no language' })"
}
if ($updated -ceq $html) {
    Write-Output "unchanged"
} else {
    [IO.File]::WriteAllText($Path, $updated)
    Write-Output "changed"
}
