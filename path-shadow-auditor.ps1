[CmdletBinding()]
param(
  [string[]]$Command,
  [string]$CommandFile,
  [ValidateSet('Process', 'User', 'Machine', 'All')]
  [string]$Scope = 'All',
  [string]$JsonOut,
  [string]$MarkdownOut
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NormalizedPath {
  param([string]$PathValue)

  if ([string]::IsNullOrWhiteSpace($PathValue)) {
    return $null
  }

  $trimmed = $PathValue.Trim().Trim('"')
  if ([string]::IsNullOrWhiteSpace($trimmed)) {
    return $null
  }

  try {
    return [System.IO.Path]::GetFullPath($trimmed).TrimEnd('\').ToLowerInvariant()
  } catch {
    return $trimmed.TrimEnd('\').ToLowerInvariant()
  }
}

function Split-PathEntries {
  param(
    [string]$PathString,
    [string]$Source
  )

  $parts = @()
  if ([string]::IsNullOrWhiteSpace($PathString)) {
    return $parts
  }

  foreach ($segment in ($PathString -split ';')) {
    $raw = $segment.Trim()
    if (-not $raw) {
      continue
    }

    $clean = $raw.Trim('"')
    $exists = Test-Path -LiteralPath $clean -PathType Container
    $resolved = $null
    if ($exists) {
      try {
        $resolved = (Resolve-Path -LiteralPath $clean).Path
      } catch {
        $resolved = $clean
      }
    }

    $parts += [pscustomobject]@{
      Raw        = $raw
      Clean      = $clean
      Exists     = $exists
      Resolved   = $resolved
      Normalized = Get-NormalizedPath $clean
      Source     = $Source
    }
  }

  return $parts
}

function Get-SelectedPathEntries {
  param([string]$SelectedScope)

  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  $processPath = [Environment]::GetEnvironmentVariable('Path', 'Process')

  switch ($SelectedScope) {
    'User' { return @(Split-PathEntries -PathString $userPath -Source 'User') }
    'Machine' { return @(Split-PathEntries -PathString $machinePath -Source 'Machine') }
    'Process' { return @(Split-PathEntries -PathString $processPath -Source 'Process') }
    default {
      $merged = @()
      $merged += Split-PathEntries -PathString $machinePath -Source 'Machine'
      $merged += Split-PathEntries -PathString $userPath -Source 'User'

      $known = @{}
      foreach ($entry in $merged) {
        if ($entry.Normalized) {
          $known[$entry.Normalized] = $true
        }
      }

      foreach ($entry in (Split-PathEntries -PathString $processPath -Source 'Process')) {
        if (-not $entry.Normalized -or -not $known.ContainsKey($entry.Normalized)) {
          $entry.Source = 'Process extra'
          $merged += $entry
          if ($entry.Normalized) {
            $known[$entry.Normalized] = $true
          }
        }
      }

      return @($merged)
    }
  }
}

function Get-CommandTargets {
  param([string[]]$Requested, [string]$RequestedFile)

  $targets = @()
  if ($Requested) {
    foreach ($entry in $Requested) {
      $targets += $entry -split ','
    }
  }

  if ($RequestedFile) {
    if (-not (Test-Path -LiteralPath $RequestedFile -PathType Leaf)) {
      throw "Command file not found: $RequestedFile"
    }

    $targets += Get-Content -LiteralPath $RequestedFile |
      ForEach-Object { $_.Trim() } |
      Where-Object { $_ -and -not $_.StartsWith('#') }
  }

  if (-not @($targets).Count) {
    $targets = @('python', 'py', 'git', 'node', 'npm', 'cargo', 'rustc', 'go', 'java', 'javac', 'pwsh')
  }

  return $targets |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ } |
    Select-Object -Unique
}

function Get-CandidateNames {
  param([string]$Name)

  if ($Name.Contains('.')) {
    return @($Name)
  }

  $pathExtensions = if ($env:PATHEXT) { $env:PATHEXT } else { '.COM;.EXE;.BAT;.CMD;.PS1' }
  $extensions = ($pathExtensions -split ';') |
    Where-Object { $_ } |
    ForEach-Object { $_.ToLowerInvariant() }

  $names = @($Name)
  foreach ($extension in $extensions) {
    $names += "$Name$extension"
  }

  return $names | Select-Object -Unique
}

function Find-CommandHits {
  param([object[]]$Entries, [string]$CommandName)

  $hits = @()
  $candidates = Get-CandidateNames $CommandName

  for ($index = 0; $index -lt $Entries.Count; $index += 1) {
    $entry = $Entries[$index]
    if (-not $entry.Exists) {
      continue
    }

    foreach ($candidate in $candidates) {
      $candidatePath = Join-Path $entry.Clean $candidate
      if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
        $item = Get-Item -LiteralPath $candidatePath
        $hits += [pscustomobject]@{
          PathIndex  = $index + 1
          Directory  = $entry.Clean
          FileName   = $item.Name
          FullPath   = $item.FullName
          Extension  = $item.Extension
          LastWrite  = $item.LastWriteTime
        }
      }
    }
  }

  return $hits
}

function Convert-ToMarkdown {
  param([pscustomobject]$Report)

  $lines = @(
    '# Path Shadow Auditor Report',
    '',
    "- Generated: $($Report.generatedAt)",
    "- Scope: $($Report.scope)",
    "- PATH entries: $($Report.summary.totalEntries)",
    "- Missing directories: $($Report.summary.missingEntries)",
    "- Duplicate directories: $($Report.summary.duplicateEntryCount)",
    ''
  )

  if (@($Report.duplicates).Count) {
    $lines += '## Duplicate PATH Entries'
    $lines += ''
    foreach ($duplicate in $Report.duplicates) {
      $positions = ($duplicate.positions -join ', ')
      $lines += "- `$($duplicate.path)` at positions $positions from $($duplicate.sources -join ', ')"
    }
    $lines += ''
  }

  $lines += '## Command Resolution'
  $lines += ''

  foreach ($commandReport in $Report.commands) {
    $lines += "### $($commandReport.command)"
    if (@($commandReport.hits).Count -eq 0) {
      $lines += ''
      $lines += '- Not found on the selected PATH.'
      $lines += ''
      continue
    }

    $lines += ''
    $lines += ('- First hit: ' + $commandReport.primary.fullPath)
    $lines += ('- Shadowed copies: ' + $commandReport.shadowCount)
    foreach ($hit in $commandReport.hits) {
      $lines += ('  - [' + $hit.pathIndex + '] ' + $hit.fullPath)
    }
    $lines += ''
  }

  return $lines -join [Environment]::NewLine
}

$entries = @(Get-SelectedPathEntries $Scope)
$targets = Get-CommandTargets -Requested $Command -RequestedFile $CommandFile

$duplicates = $entries |
  Group-Object Normalized |
  Where-Object { $_.Name -and $_.Count -gt 1 } |
  ForEach-Object {
    [pscustomobject]@{
      path      = if ($_.Group[0].Resolved) { $_.Group[0].Resolved } else { $_.Group[0].Clean }
      positions = @($_.Group | ForEach-Object { [array]::IndexOf($entries, $_) + 1 })
      sources   = @($_.Group | ForEach-Object { $_.Source } | Select-Object -Unique)
      count     = $_.Count
    }
  }

$commandReports = foreach ($target in $targets) {
  $hits = @(Find-CommandHits -Entries $entries -CommandName $target)
  [pscustomobject]@{
    command     = $target
    primary     = if (@($hits).Count) { [pscustomobject]@{ fullPath = $hits[0].FullPath; pathIndex = $hits[0].PathIndex } } else { $null }
    shadowCount = [Math]::Max(0, @($hits).Count - 1)
    hits        = @($hits | ForEach-Object {
      [pscustomobject]@{
        pathIndex = $_.PathIndex
        directory = $_.Directory
        fileName  = $_.FileName
        fullPath  = $_.FullPath
        extension = $_.Extension
        lastWrite = $_.LastWrite
      }
    })
  }
}

$report = [pscustomobject]@{
  generatedAt = (Get-Date).ToString('s')
  scope       = $Scope
  summary     = [pscustomobject]@{
    totalEntries        = $entries.Count
    missingEntries      = @($entries | Where-Object { -not $_.Exists }).Count
    duplicateEntryCount = @($duplicates).Count
  }
  entries      = @($entries | ForEach-Object {
    [pscustomobject]@{
      raw      = $_.Raw
      clean    = $_.Clean
      exists   = $_.Exists
      resolved = $_.Resolved
      source   = $_.Source
    }
  })
  duplicates   = @($duplicates)
  commands     = @($commandReports)
}

Write-Host "PATH entries: $($report.summary.totalEntries)"
Write-Host "Missing directories: $($report.summary.missingEntries)"
Write-Host "Duplicate directories: $($report.summary.duplicateEntryCount)"

foreach ($commandReport in $report.commands) {
  if (-not $commandReport.primary) {
    Write-Host ("[missing] {0}" -f $commandReport.command)
    continue
  }

  Write-Host ("[{0}] {1} -> {2}" -f $commandReport.primary.pathIndex, $commandReport.command, $commandReport.primary.fullPath)
  if ($commandReport.shadowCount -gt 0) {
    Write-Host ("  shadowed copies: {0}" -f $commandReport.shadowCount)
  }
}

if ($JsonOut) {
  $jsonDir = Split-Path -Parent $JsonOut
  if ($jsonDir) {
    New-Item -ItemType Directory -Force -Path $jsonDir | Out-Null
  }
  $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $JsonOut -Encoding UTF8
}

if ($MarkdownOut) {
  $markdownDir = Split-Path -Parent $MarkdownOut
  if ($markdownDir) {
    New-Item -ItemType Directory -Force -Path $markdownDir | Out-Null
  }
  Convert-ToMarkdown -Report $report | Set-Content -LiteralPath $MarkdownOut -Encoding UTF8
}
