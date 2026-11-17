# install-skill.ps1 - give Claude Code the /wow-story skill.
#
#     .\install-skill.ps1            link skill\ into ~\.claude\skills\wow-story
#     .\install-skill.ps1 -Remove    take the link away again
#
# A junction, like install.ps1 does for the game: edits in skill\SKILL.md are used at once.

param([switch]$Remove)

$ErrorActionPreference = 'Stop'
$skills = Join-Path $env:USERPROFILE '.claude\skills'
$link = Join-Path $skills 'wow-story'
$existing = Get-Item $link -ErrorAction SilentlyContinue

if ($existing -and $existing.LinkType -ne 'Junction') { throw "$link is a real folder, not a link. Left alone." }
if ($existing) { [IO.Directory]::Delete($link) }
if ($Remove) { if ($existing) { Write-Host "Removed  $link" }; return }

New-Item -ItemType Directory -Force $skills | Out-Null
New-Item -ItemType Junction -Path $link -Target (Join-Path $PSScriptRoot 'skill') | Out-Null
Write-Host "Linked   $link -> $(Join-Path $PSScriptRoot 'skill'). Start a new Claude Code session and run /wow-story."
