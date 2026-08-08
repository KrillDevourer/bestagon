# BESTAGON - the whole gate, one command.
#
#   powershell -File tools/verify.ps1
#   powershell -File tools/verify.ps1 soak      # adds an 11-minute fixed-step run
#
# ASCII ONLY, deliberately: Windows PowerShell 5.1 reads a .ps1 as ANSI unless it
# has a BOM, so a single em-dash in a comment is a parser error. Learned the hard
# way while writing this file.
#
# Exists because of review finding 29. The documented smoke command was
#   <console.exe> --headless --path . --quit-after 300
# and run/main_scene is title.tscn, so it booted the TITLE SCREEN, sat there, and
# exited 0 no matter what was broken in gameplay. It could not fail on a gameplay
# error because it never loaded main.tscn. Every "smoke passed" before this
# script was evidence of nothing.
#
# Two further traps encoded here so nobody has to remember them:
#   * gameplay smoke must name main.tscn EXPLICITLY, and must assert the
#     "BESTAGON boot OK" line actually appeared. Exit 0 alone proves nothing.
#   * --dev-autopick takes the call_deferred+break path in _check_level_up and
#     therefore NEVER calls LevelUpPanel.show_offers, so a soak with autopick
#     leaves the level-up screen untested. The no-autopick pass below covers it.

# A positional STRING, not a [switch]: powershell.exe -File passes every argument
# as a string, so a switch parameter cannot bind and the script dies before it
# runs a single step.
param([string]$Mode = "")

$ErrorActionPreference = "Continue"
$root   = Split-Path -Parent $PSScriptRoot
# $env:GODOT, then the workspace engine\ folder, then PATH - and on a miss it
# prints every location it tried. See tools/find_godot.ps1 for why this is not
# the one hardcoded path it used to be.
. (Join-Path $PSScriptRoot "find_godot.ps1")
$godot  = Assert-Godot -Root $root
$script:failed = @()

# Teardown noise that is genuinely benign, matched as narrowly as possible. The
# audio server holds every stream that played past the leak check, and the
# renderer/physics dummies release their last RIDs after it. Anything else
# containing ERROR is a real failure.
$benign = @(
  'resources still in use at exit',
  'RID allocations of type'
)

# THE one definition of "this line is an error". Every stage's verdict comes from
# here, and so does the self-test below - a self-test that re-states the pattern
# instead of calling this would only ever test its own copy.
#
# -cmatch, NOT -match, on the engine's tokens: PowerShell's -match is
# CASE-INSENSITIVE, so a bare 'ERROR' matched the class name `GutErrorTracker` in
# the importer's `update_scripts_classes` output. That output only appears on a
# COLD import - once .godot/ exists the step is silent - so it was invisible on
# any machine that had already built once, and fired on exactly the case nobody
# here ever runs: a fresh clone's first verify. Found 2026-08-04 while testing
# whether this repo can actually be forked. Godot writes ERROR:/SCRIPT ERROR:/
# USER ERROR: uppercase and with the colon. The mixed-case English phrases below
# stay case-insensitive because Godot does not shout those.
function Test-IsErrorLine {
  param([string]$Line)
  $hit = ($Line -cmatch 'SCRIPT ERROR|ERROR:|Parse Error') -or
         ($Line  -match 'Failed to load|Cannot call')
  if (-not $hit) { return $false }
  foreach ($b in $benign) { if ($Line -match [regex]::Escape($b)) { return $false } }
  return $true
}

# SELF-TEST. This runs first because every other stage's pass/fail is decided by
# the function above, so if it is wrong, nothing below it means anything. The
# real-error strings are copied verbatim from a deliberately sabotaged build.
Write-Host ""
Write-Host "=== error filter self-test ===" -ForegroundColor Cyan
$filterCases = @(
  @{ Want = $true;  Line = 'ERROR: Failed to instantiate an autoload, script ''res://scripts/meta.gd'' does not inherit from ''Node''.' },
  @{ Want = $true;  Line = 'ERROR: Failed to load script "res://scripts/meta.gd" with error "Parse error".' },
  @{ Want = $true;  Line = 'SCRIPT ERROR: Invalid access to property or key ''unlocked'' on a base object of type ''Nil''.' },
  @{ Want = $true;  Line = 'SCRIPT ERROR: Parse Error: Function "nope()" not found in base self.' },
  @{ Want = $true;  Line = 'USER ERROR: pushed from game code' },
  @{ Want = $false; Line = '[  23% ] update_scripts_classes | GutErrorTracker' },
  @{ Want = $false; Line = '[  31% ] update_scripts_classes | GutTrackedError' },
  @{ Want = $false; Line = 'WARNING: 3 resources still in use at exit.' },
  @{ Want = $false; Line = 'ERROR: 2 RID allocations of type ''N13TextServerAdv'' were leaked at exit.' }
)
$filterBad = @($filterCases | Where-Object { (Test-IsErrorLine $_.Line) -ne $_.Want })
if ($filterBad.Count -gt 0) {
  $script:failed += "error filter self-test ($($filterBad.Count) wrong)"
  $filterBad | ForEach-Object {
    Write-Host ("  expected {0}, got {1}: {2}" -f $_.Want, (Test-IsErrorLine $_.Line), $_.Line) -ForegroundColor Red
  }
} else {
  Write-Host "  ok ($($filterCases.Count) cases)" -ForegroundColor Green
}

function Invoke-Step {
  param([string]$Name, [string[]]$GodotArgs, [string]$MustContain)

  Write-Host ""
  Write-Host "=== $Name ===" -ForegroundColor Cyan

  # Start-Process with real file redirection, NOT `& exe 2>&1`. In Windows
  # PowerShell 5.1 merging a native command's stderr into the pipeline wraps
  # every line in an ErrorRecord whose text contains "NativeCommandError" - which
  # this function's own error filter then matched, so the gate failed itself on
  # three steps that had actually passed.
  $so = [IO.Path]::GetTempFileName()
  $se = [IO.Path]::GetTempFileName()
  $proc = Start-Process -FilePath $godot -ArgumentList $GodotArgs -NoNewWindow -Wait `
    -PassThru -RedirectStandardOutput $so -RedirectStandardError $se
  $code = $proc.ExitCode
  $out = ((Get-Content $so -Raw) + "`n" + (Get-Content $se -Raw))
  Remove-Item $so, $se -Force -ErrorAction SilentlyContinue

  # Test-IsErrorLine is the single definition, self-tested at the top of this file.
  $errors = $out -split "`r?`n" | Where-Object { Test-IsErrorLine $_ }

  if ($code -ne 0) { $script:failed += "$Name (exit $code)" }
  if ($errors) {
    $script:failed += "$Name (errors)"
    $errors | Select-Object -First 8 | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
  }
  if ($MustContain -and ($out -notmatch [regex]::Escape($MustContain))) {
    $script:failed += "$Name (missing '$MustContain' - did it actually run?)"
  }
  if ((-not $errors) -and $code -eq 0) { Write-Host "  ok" -ForegroundColor Green }
  return $out
}

# BOTH GUARDS BELOW ARE ONLY AS REAL AS git IS.
#
# Each one used to iterate `@(& git -C $root ls-files ...)` directly. When git is
# not installed that expression is an EMPTY ARRAY: no paths to scan, so no
# violations found, so "ok" in green. The guard does not fail, it EVAPORATES.
#
# Measured 2026-08-07 on a clean Windows box with Godot present and git not on
# PATH: both guards printed ok while PowerShell wrote CommandNotFoundException to
# stderr underneath each of them, and VERIFY PASSED at the end. The two checks
# that exist to defend this public repo's central promise - no absolute paths, no
# tracked build artifacts - were the only two stages in the gate that could not
# fail, on exactly the machine most likely to be a stranger's fresh clone.
#
# This is the same class of bug as review finding 29 (a smoke test that booted the
# title screen and so could not fail) and as the Test-IsErrorLine case-sensitivity
# bug directly above. find_godot.ps1 was written because a missing ENGINE produced
# five failures that never said "engine"; nobody then asked what a missing git
# produced. It produced silence, which is worse.
#
# Returns $null when git could not answer, which is a DIFFERENT thing from an
# empty list and is what the callers now branch on.
function Get-TrackedFiles {
  param([string[]]$Spec = @())

  if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
    return $null
  }
  $out = & git -C $root ls-files @Spec
  # A non-zero exit means "not a repository", a broken index, or a bad pathspec.
  # All of those must fail loudly rather than read as a clean scan.
  if ($LASTEXITCODE -ne 0) { return $null }
  return @($out)
}

# What a guard prints when it could not run at all. Named so both callers say the
# same thing - the point of the fix is that this state is never mistaken for ok.
function Write-GuardUnavailable {
  param([string]$Name)

  $script:failed += "$Name (COULD NOT RUN - git unavailable)"
  Write-Host "  CANNOT RUN: git is not on PATH, or this is not a git checkout." -ForegroundColor Red
  Write-Host "  This guard scans TRACKED files, so it needs git to know what is tracked." -ForegroundColor Red
  Write-Host "  It is reported as a FAILURE and not as ok, because a guard that did not" -ForegroundColor Red
  Write-Host "  run has proven nothing. Install git, or run the gate from a real clone." -ForegroundColor Red
}

# ABSOLUTE PATH GUARD. This repo is PUBLIC, and an absolute path in it is never a
# local convenience - it is a claim that only works on one machine, and it is
# invisible to the person who wrote it. tools/build_music.py carried a hardcoded
# path into a private repo for months while the README promised the .ogg files
# were regenerable build artifacts. It was true for exactly one computer on
# earth. (This comment describes it rather than quoting it, because the guard
# below has no exemption for examples - which is the point of it.)
#
# CODE ONLY (.gd/.py/.ps1/.mjs) and tracked files only - prose legitimately shows
# example paths, and node_modules is gitignored so it never reaches this. The
# lookbehind is what keeps https:// , res:// and user:// from matching.
Write-Host ""
Write-Host "=== absolute path guard ===" -ForegroundColor Cyan
$pattern = '(?<![A-Za-z])[A-Za-z]:[\\/]|[\\/](Users|home)[\\/]'
$code = Get-TrackedFiles @('--', '*.gd', '*.py', '*.ps1', '*.mjs')
if ($null -eq $code) {
  Write-GuardUnavailable "absolute path guard"
} elseif ($code.Count -eq 0) {
  # git answered, and said this repo tracks no code at all. That is not a clean
  # scan either - it means the pathspec stopped matching, and the guard would go
  # on printing ok forever while covering nothing.
  $script:failed += "absolute path guard (matched 0 tracked source files)"
  Write-Host "  NO FILES MATCHED: the pathspec covers nothing, so this proved nothing." -ForegroundColor Red
} else {
  $hits = @()
  foreach ($rel in $code) {
    $full = Join-Path $root $rel
    if (-not (Test-Path $full)) { continue }
    foreach ($m in (Select-String -Path $full -Pattern $pattern -AllMatches)) {
      $hits += ("  {0}:{1}: {2}" -f $rel, $m.LineNumber, $m.Line.Trim())
    }
  }
  if ($hits.Count -gt 0) {
    $script:failed += "absolute path guard ($($hits.Count) found)"
    $hits | Select-Object -First 8 | ForEach-Object { Write-Host $_ -ForegroundColor Red }
  } else {
    Write-Host "  ok ($($code.Count) tracked source files)" -ForegroundColor Green
  }
}

# BUILD ARTIFACT GUARD. The guard above reads text, so a COMPILED artifact walks
# straight past it. tools/__pycache__/build_music.cpython-310.pyc was tracked in
# this PUBLIC repo for 3 commits carrying a baked-in absolute path to an unrelated
# project on the author's disk - the exact string the guard above exists to catch,
# in a file it never opened. Found 2026-08-04 by cloning the public URL and reading
# the bytecode; the history was rewritten to purge it.
#
# .gitignore did not save it either: `__pycache__/` was added AFTER the file was
# already tracked, and ignore rules do not apply to tracked files. So the guard is
# on what is TRACKED, which is the thing that actually ships.
Write-Host ""
Write-Host "=== build artifact guard ===" -ForegroundColor Cyan
$tracked = Get-TrackedFiles
if ($null -eq $tracked) {
  Write-GuardUnavailable "build artifact guard"
} elseif ($tracked.Count -eq 0) {
  $script:failed += "build artifact guard (0 tracked files)"
  Write-Host "  NO FILES TRACKED: nothing was scanned, so this proved nothing." -ForegroundColor Red
} else {
  $artifacts = @($tracked | Where-Object {
    $_ -match '(^|/)__pycache__/' -or $_ -match '\.py[co]$' -or $_ -match '(^|/)node_modules/'
  })
  if ($artifacts.Count -gt 0) {
    $script:failed += "build artifact guard ($($artifacts.Count) tracked)"
    Write-Host "  tracked build artifacts - untrack these, they are not source:" -ForegroundColor Red
    $artifacts | Select-Object -First 8 | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
  } else {
    Write-Host "  ok ($($tracked.Count) tracked files)" -ForegroundColor Green
  }
}

Invoke-Step "import" @('--headless','--import','--path',$root) | Out-Null

$tests = Invoke-Step "unit tests" @('--headless','--path',$root,'-d','-s',
  'addons/gut/gut_cmdln.gd','-gdir=res://tests','-ginclude_subdirs','-gexit') "Passing Tests"
($tests -split "`r?`n" | Select-String 'Tests\s+\d|Passing|Failing') | ForEach-Object { Write-Host "  $_" }

# The level-up panel only exists on the no-autopick path - see the header.
#
# --dev-noprofile does nothing to gameplay; it only redirects the save. Without
# it this step banked into the REAL profile on every run, because the save
# redirect keys off any --dev- flag and this is the one step that deliberately
# carries none. The title screen was advertising "best 00:08" off seven bot runs.
Invoke-Step "gameplay smoke (level-up panel reachable)" @('--headless','--path',$root,
  '--fixed-fps','60','res://scenes/main/main.tscn','--quit-after','2400','--',
  '--dev-noprofile') "BESTAGON boot OK" | Out-Null

$layout = Invoke-Step "pause layout" @('--headless','--path',$root,
  'res://scenes/dev/pause_layout_check.tscn','--quit-after','600') "FAILURES=0"
($layout -split "`r?`n" | Select-String 'FAILURES') | ForEach-Object { Write-Host "  $_" }

# The 2026-08-03 release freeze: an orphaned LOOPING tween (the Legendary card
# pulse, panel-bound, animating a button show_offers frees) loops in zero time.
# Godot's detector for that is DEBUG-only, so a debug run prints "ERROR:
# Infinite loop detected" - which the generic error grep above turns into a
# failure - while a release build locks the main thread forever. MustContain
# proves the harness reached its second card screen: its first version passed
# vacuously because the WHEN_PAUSED panel never processed in an unpaused tree.
Invoke-Step "tween orphan (legendary pulse regression)" @('--headless','--path',$root,
  'res://scenes/dev/tween_orphan_check.tscn','--quit-after','600') "screen 2 up" | Out-Null

if ($Mode -eq "soak") {
  # 40000 frames at a fixed 60fps = 11:06 of game time, which clears BOTH boss
  # events. The --dev- flags redirect the save (finding 12), so this cannot
  # pollute the real profile.
  $soak = Invoke-Step "11-minute soak (both boss events)" @('--headless','--path',$root,
    '--fixed-fps','60','res://scenes/main/main.tscn','--quit-after','40000','--',
    '--dev-godmode','--dev-autopick','--dev-autocontinue','--dev-unlocks','--dev-stats') "[boss]"
  ($soak -split "`r?`n" | Select-String '\[boss\]|\[victory\]') | ForEach-Object { Write-Host "  $_" }
}

Write-Host ""
if ($script:failed.Count -gt 0) {
  Write-Host "VERIFY FAILED:" -ForegroundColor Red
  $script:failed | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
  exit 1
}
Write-Host "VERIFY PASSED" -ForegroundColor Green
exit 0
