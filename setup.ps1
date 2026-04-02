#requires -Version 5.1
<#!
Windows Terminal Modernization Script

Fresh-install bootstrap for a modern cmd.exe experience:
- Installs or upgrades: Clink + Starship (winget)
- Integrates: Starship into cmd via Clink Lua
- Adds: clink-completions (git clone + clink installscripts)
- Installs: Nerd Font (FiraCode Nerd Font v3.4.0) per-user
- Applies: Starship preset theme + enforces add_newline = false
- Applies: Minimal Clink settings overrides from ./configs/clink.overrides.txt (optional)
- Optional: sets Windows Terminal default profile to cmd.exe

Repository layout (expected):
  ./setup-clink-starship.ps1
  ./run-setup.cmd
  ./configs/
      clink.overrides.txt        (optional) key=value per line, e.g. clink.logo=none

Notes:
- This script requires Git to be installed (used to fetch clink-completions).
- If Git is missing, the script stops immediately.
- PowerShell 5.1+ is supported.
!#>

[CmdletBinding()]
param(
  [string]$StarshipPreset,
  [switch]$SkipFonts,
  [switch]$SkipTerminalProfile,
  [switch]$SkipCompletions,
  [switch]$SkipPackageInstall,
  [switch]$NonInteractive,
  [string]$LogPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:LogPath = $null
$script:TranscriptPath = $null
$script:TranscriptStarted = $false

function Fail {
  param([Parameter(Mandatory)][string]$Message)
  Write-Host ""
  Write-Host ("ERROR: {0}" -f $Message) -ForegroundColor Red
  if ($script:LogPath) {
    Write-Host ("     Log file: {0}" -f $script:LogPath) -ForegroundColor Yellow
  }
  if ($script:TranscriptStarted -and $script:TranscriptPath) {
    Write-Host ("     Transcript: {0}" -f $script:TranscriptPath) -ForegroundColor Yellow
  }
  Write-Log ("ERROR: {0}" -f $Message)
  exit 1
}

function Write-Section {
  param([Parameter(Mandatory)][string]$Title)
  Write-Host ''
  Write-Host ('=' * 72) -ForegroundColor DarkGray
  Write-Host ("  {0}" -f $Title) -ForegroundColor White
  Write-Host ('=' * 72) -ForegroundColor DarkGray
  Write-Log ("SECTION: {0}" -f $Title)
}

function Write-Step {
  param([Parameter(Mandatory)][string]$Message)
  Write-Host ("[>] {0}" -f $Message) -ForegroundColor Cyan
  Write-Log ("STEP : {0}" -f $Message)
}

function Write-Ok {
  param([Parameter(Mandatory)][string]$Message)
  Write-Host ("[OK] {0}" -f $Message) -ForegroundColor Green
  Write-Log ("OK   : {0}" -f $Message)
}

function Write-Skip {
  param([Parameter(Mandatory)][string]$Message)
  Write-Host ("[SKIP] {0}" -f $Message) -ForegroundColor Yellow
  Write-Log ("SKIP : {0}" -f $Message)
}

function Write-Detail {
  param([Parameter(Mandatory)][string]$Message)
  Write-Host ("     {0}" -f $Message) -ForegroundColor DarkGray
  Write-Log ("INFO : {0}" -f $Message)
}

function Write-Info {
  param([Parameter(Mandatory)][string]$Message)
  Write-Step $Message
}

function Write-WarnMsg {
  param([Parameter(Mandatory)][string]$Message)
  Write-Skip $Message
}
function Write-Log {
  param([Parameter(Mandatory)][string]$Message)
  if (-not [string]::IsNullOrWhiteSpace($script:LogPath)) {
    try {
      Add-Content -LiteralPath $script:LogPath -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
    } catch {
      Write-WarnMsg "Could not write to log file '$script:LogPath': $($_.Exception.Message)"
    }
  }
}


function Assert-CommandExists {
  param([Parameter(Mandatory)][string]$Name, [string]$Hint = "")
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    $msg = "'$Name' was not found on PATH."
    if ($Hint) { $msg += " $Hint" }
    Fail $msg
  }
}

function Ensure-Directory {
  param([Parameter(Mandatory)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function Assert-ExternalSuccess {
  param([Parameter(Mandatory)][string]$What)
  if ($LASTEXITCODE -ne 0) {
    Fail "$What failed with exit code $LASTEXITCODE."
  }
}

function Invoke-External {
  param(
    [Parameter(Mandatory)][string]$FilePath,
    [Parameter()][string[]]$ArgumentList = @(),
    [Parameter(Mandatory)][string]$What,
    [int[]]$IgnoreExitCodes = @(),
    [string[]]$SuccessPatterns = @()
  )

  $commandText = if ($ArgumentList.Count -gt 0) {
    '"' + $FilePath + '" ' + (($ArgumentList | ForEach-Object {
      if ($_ -match '\s') { '"' + $_ + '"' } else { $_ }
    }) -join ' ')
  } else {
    '"' + $FilePath + '"'
  }

  Write-Log "RUN  : $commandText"
  $output = & $FilePath @ArgumentList 2>&1
  $exitCode = $LASTEXITCODE
  $outputText = ($output | Out-String)

  if ($output) {
    foreach ($line in ($outputText -split "`r?`n")) {
      if (-not [string]::IsNullOrWhiteSpace($line)) {
        Write-Log "OUT  : $line"
      }
    }
  }

  Write-Log "EXIT : $exitCode ($What)"

  if ($exitCode -eq 0) {
    return
  }

  if ($IgnoreExitCodes -contains $exitCode) {
    Write-WarnMsg "$What returned exit code $exitCode; continuing by policy."
    return
  }

  foreach ($pattern in $SuccessPatterns) {
    if ($outputText -match $pattern) {
      Write-WarnMsg "$What reported an already-applied state; continuing."
      Write-Log "INFO : Matched benign pattern: $pattern"
      return
    }
  }

  Fail "$What failed with exit code $exitCode."
}

function Refresh-ProcessPathFromRegistry {
  $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  $user    = [Environment]::GetEnvironmentVariable('Path', 'User')

  if ([string]::IsNullOrWhiteSpace($machine) -and [string]::IsNullOrWhiteSpace($user)) {
    return
  }

  if ([string]::IsNullOrWhiteSpace($machine)) {
    $env:Path = $user
  } elseif ([string]::IsNullOrWhiteSpace($user)) {
    $env:Path = $machine
  } else {
    $env:Path = "$machine;$user"
  }
}

function Get-UninstallRegistryInstallLocations {
  param([Parameter(Mandatory)][string[]]$MatchPatterns)

  $locations = New-Object System.Collections.Generic.List[string]
  $roots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
  )

  foreach ($root in $roots) {
    $items = Get-ItemProperty -Path $root -ErrorAction SilentlyContinue
    foreach ($item in $items) {
      $haystacks = @($item.DisplayName, $item.PSChildName, $item.Publisher) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
      $matched = $false
      foreach ($pattern in $MatchPatterns) {
        foreach ($hay in $haystacks) {
          if ($hay -like $pattern) {
            $matched = $true
            break
          }
        }
        if ($matched) { break }
      }
      if (-not $matched) { continue }

      foreach ($prop in @('InstallLocation','DisplayIcon','UninstallString')) {
        $value = $item.$prop
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        $locations.Add($value)
      }
    }
  }

  return $locations.ToArray()
}

function Resolve-CommandPath {
  param(
    [Parameter(Mandatory)][string]$Name,
    [string[]]$ExtraCandidates = @(),
    [string[]]$SearchRoots = @(),
    [string[]]$AlternativeLeafNames = @(),
    [string[]]$RegistryMatchPatterns = @()
  )

  $allLeafNames = New-Object System.Collections.Generic.List[string]
  foreach ($leaf in @("$Name.exe", "$Name.bat", $Name, "$Name.cmd") + $AlternativeLeafNames) {
    if (-not [string]::IsNullOrWhiteSpace($leaf) -and -not $allLeafNames.Contains($leaf)) {
      $allLeafNames.Add($leaf)
    }
  }

  $commandsToTry = New-Object System.Collections.Generic.List[string]
  $commandsToTry.Add($Name)
  foreach ($leaf in $allLeafNames) {
    $commandsToTry.Add($leaf)
  }

  foreach ($cmdName in $commandsToTry) {
    $cmd = Get-Command $cmdName -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) {
      return $cmd.Source
    }
  }

  foreach ($candidate in $ExtraCandidates) {
    if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate)) {
      return $candidate
    }
  }

  foreach ($pattern in $RegistryMatchPatterns) {
    foreach ($loc in Get-UninstallRegistryInstallLocations -MatchPatterns @($pattern)) {
      if ([string]::IsNullOrWhiteSpace($loc)) { continue }
      $resolvedLoc = $loc.Trim('"')
      if (Test-Path -LiteralPath $resolvedLoc -PathType Leaf) {
        return $resolvedLoc
      }
      foreach ($leaf in $allLeafNames) {
        $candidate = Join-Path $resolvedLoc $leaf
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
          return $candidate
        }
      }
    }
  }

  foreach ($root in $SearchRoots) {
    if ([string]::IsNullOrWhiteSpace($root)) { continue }
    if (-not (Test-Path -LiteralPath $root)) { continue }

    foreach ($leaf in $allLeafNames) {
      $match = Get-ChildItem -Path $root -Recurse -File -Filter $leaf -ErrorAction SilentlyContinue |
        Select-Object -First 1
      if ($match) {
        return $match.FullName
      }
    }
  }

  return $null
}

function Winget-EnsurePackage {
  param([Parameter(Mandatory)][string]$Id)

  Write-Step ("Package: {0}" -f $Id)

  $listOutput = & winget list --id $Id -e 2>&1
  $listExit = $LASTEXITCODE
  $listText = ($listOutput | Out-String)

  foreach ($line in ($listText -split "`r?`n")) {
    if (-not [string]::IsNullOrWhiteSpace($line)) {
      Write-Log "OUT  : $line"
    }
  }

  if ($listExit -eq 0 -and $listText -match [regex]::Escape($Id)) {
    Write-Detail 'Installed; checking for updates...'
    $upgradeOutput = & winget upgrade --id $Id -e --accept-package-agreements --accept-source-agreements 2>&1
    $upgradeExit = $LASTEXITCODE
    $upgradeText = ($upgradeOutput | Out-String)

    foreach ($line in ($upgradeText -split "`r?`n")) {
      if (-not [string]::IsNullOrWhiteSpace($line)) {
        Write-Log "OUT  : $line"
      }
    }

    if ($upgradeExit -eq 0) {
      Write-Ok ("{0} is installed and ready." -f $Id)
      return
    }

    $benignUpgradePatterns = @(
      'No available upgrade found',
      'No newer package versions are available',
      'No applicable upgrade found'
    )

    foreach ($pattern in $benignUpgradePatterns) {
      if ($upgradeText -match [regex]::Escape($pattern)) {
        Write-Ok ("{0} is already up to date." -f $Id)
        return
      }
    }

    Fail ("winget upgrade {0} failed with exit code {1}." -f $Id, $upgradeExit)
  }

  Write-Detail 'Not installed; installing...'
  $installOutput = & winget install -e --id $Id --accept-package-agreements --accept-source-agreements 2>&1
  $installExit = $LASTEXITCODE
  $installText = ($installOutput | Out-String)

  foreach ($line in ($installText -split "`r?`n")) {
    if (-not [string]::IsNullOrWhiteSpace($line)) {
      Write-Log "OUT  : $line"
    }
  }

  if ($installExit -eq 0) {
    Write-Ok ("{0} installed successfully." -f $Id)
    return
  }

  $benignInstallPatterns = @(
    'Found an existing package already installed',
    'Package is already installed',
    'No available upgrade found',
    'No newer package versions are available'
  )

  foreach ($pattern in $benignInstallPatterns) {
    if ($installText -match [regex]::Escape($pattern)) {
      Write-Ok ("{0} is already installed and current." -f $Id)
      return
    }
  }

  Fail ("winget install {0} failed with exit code {1}." -f $Id, $installExit)
}

function Upsert-TomlKey {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Key,
    [Parameter(Mandatory)][string]$Value
  )

  if (Test-Path -LiteralPath $Path) {
    $txt = Get-Content -LiteralPath $Path -Raw
  } else {
    $txt = ""
  }

  $pattern = "(?m)^\s*$([regex]::Escape($Key))\s*=\s*.*$"
  if ($txt -match $pattern) {
    $txt = [regex]::Replace($txt, $pattern, "$Key = $Value")
  } elseif ([string]::IsNullOrWhiteSpace($txt)) {
    $txt = "$Key = $Value`r`n"
  } else {
    $txt = "$Key = $Value`r`n$txt"
  }

  Set-Content -LiteralPath $Path -Value $txt -Encoding UTF8
}

function Apply-ClinkOverrides {
  param(
    [Parameter(Mandatory)][string]$OverridesPath,
    [Parameter(Mandatory)][string]$ClinkExe
  )

  if (-not (Test-Path -LiteralPath $OverridesPath)) { return }

  $lines = Get-Content -LiteralPath $OverridesPath
  foreach ($line in $lines) {
    $t = $line.Trim()
    if (-not $t) { continue }
    if ($t.StartsWith('#')) { continue }

    $idx = $t.IndexOf('=')
    if ($idx -lt 1) {
      Write-WarnMsg "Skipping malformed override line: $line"
      continue
    }

    $key = $t.Substring(0, $idx).Trim()
    $val = $t.Substring($idx + 1).Trim()
    if (-not $key) {
      Write-WarnMsg "Skipping malformed override line: $line"
      continue
    }

    Write-Step ("Clink setting: {0}" -f $key)
    Write-Detail ("Value: {0}" -f $val)
    try {
      Invoke-External -FilePath $ClinkExe -ArgumentList @('set', $key, $val) -What "clink set $key"
    }
    catch {
      $msg = $_.Exception.Message
      if ($msg -match "Setting '.+' not found" -or $msg -match "failed with exit code 1") {
        Write-WarnMsg "Skipping unsupported Clink setting: $key"
        continue
      }
      throw
    }
  }
}

function Install-NerdFontZipPerUser {
  param([Parameter(Mandatory)][string]$ZipUrl)

  $tmp = Join-Path $env:TEMP ("nerd-font-" + [Guid]::NewGuid().ToString('N'))
  Ensure-Directory $tmp
  $zipPath = Join-Path $tmp 'font.zip'

  try {
    Write-Step 'Downloading Nerd Font package'
    Invoke-WebRequest -Uri $ZipUrl -OutFile $zipPath -UseBasicParsing

    $extract = Join-Path $tmp 'unzipped'
    Ensure-Directory $extract
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extract -Force

    $userFontsDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
    Ensure-Directory $userFontsDir
    $fontRegPath = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'

    $fontFiles = Get-ChildItem -LiteralPath $extract -Recurse -File |
      Where-Object { $_.Extension -in @('.ttf', '.otf') }

    if (-not $fontFiles) {
      Fail 'No .ttf/.otf files found inside the font zip.'
    }

    Write-Step 'Installing fonts (per-user)'
    Write-Detail ("Target: {0}" -f $userFontsDir)
    foreach ($f in $fontFiles) {
      $dest = Join-Path $userFontsDir $f.Name
      $alreadyPresent = Test-Path -LiteralPath $dest

      if ($alreadyPresent) {
        Write-Skip ("Font already present: {0}" -f $f.Name)
      }
      else {
        try {
          Copy-Item -LiteralPath $f.FullName -Destination $dest -Force -ErrorAction Stop
          Write-Ok ("Installed font file: {0}" -f $f.Name)
        }
        catch [System.IO.IOException] {
          if (Test-Path -LiteralPath $dest) {
            Write-WarnMsg "Font file is already present and appears to be locked/in use; continuing: $($f.Name)"
          }
          else {
            throw
          }
        }
      }

      try {
        New-ItemProperty -Path $fontRegPath -Name $f.BaseName -PropertyType String -Value $dest -Force | Out-Null
      }
      catch {
        Write-WarnMsg "Failed to update font registry entry for $($f.Name): $($_.Exception.Message)"
      }
    }

    Write-Ok 'Fonts are ready. Restart Windows Terminal to pick them up.'
  }
  finally {
    if (Test-Path -LiteralPath $tmp) {
      Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

function Backup-File {
  param([Parameter(Mandatory)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $backup = "$Path.$stamp.bak"
  Copy-Item -LiteralPath $Path -Destination $backup -Force
  return $backup
}

function Setup-WindowsTerminalDefaultCmdProfile {
  param(
    [Parameter(Mandatory)][string]$CommandLine,
    [string]$StartingDirectory = $env:USERPROFILE,
    [string]$FontFace = "FiraCode Nerd Font Mono",
    [int]$FontSize = 11
  )

  $wtCandidates = @(
    (Join-Path $env:LOCALAPPDATA "Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"),
    (Join-Path $env:LOCALAPPDATA "Microsoft\Windows Terminal\settings.json")
  )
  $wtSettings = $wtCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
  if (-not $wtSettings) {
    Write-Skip 'Windows Terminal settings.json was not found; skipping Terminal profile update.'
    return
  }

  function Test-NoteProperty {
    param([object]$Object, [string]$PropertyName)
    if ($null -eq $Object) { return $false }
    return ($Object.PSObject.Properties.Match($PropertyName).Count -gt 0)
  }

  Backup-File -Path $wtSettings
  Write-Step 'Updating Windows Terminal profile'
  Write-Detail ("Settings file: {0}" -f $wtSettings)

  $raw = Get-Content -LiteralPath $wtSettings -Raw -Encoding UTF8
  $settings = $raw | ConvertFrom-Json

  if (-not (Test-NoteProperty $settings 'profiles') -or $null -eq $settings.profiles) {
    $settings | Add-Member -NotePropertyName profiles -NotePropertyValue ([pscustomobject]@{ list = @() }) -Force
  }
  if (-not (Test-NoteProperty $settings.profiles 'list') -or $null -eq $settings.profiles.list) {
    $settings.profiles | Add-Member -NotePropertyName list -NotePropertyValue @() -Force
  }

  $profiles = @($settings.profiles.list)

  $cmdProfile = $profiles | Where-Object {
    ((Test-NoteProperty $_ 'commandline') -and $_.commandline -eq $CommandLine) -or
    ((Test-NoteProperty $_ 'name') -and $_.name -eq 'Command Prompt')
  } | Select-Object -First 1

  if (-not $cmdProfile) {
    $guid = "{" + [guid]::NewGuid().ToString() + "}"
    $cmdProfile = [pscustomobject]@{
      guid = $guid
      name = "Command Prompt"
      commandline = $CommandLine
      hidden = $false
    }
    $settings.profiles.list = @($profiles) + @($cmdProfile)
    Write-Log "INFO : Created new Windows Terminal Command Prompt profile with guid $guid"
  }

  if (-not (Test-NoteProperty $cmdProfile 'guid') -or [string]::IsNullOrWhiteSpace([string]$cmdProfile.guid)) {
    $cmdProfile | Add-Member -NotePropertyName guid -NotePropertyValue ("{" + [guid]::NewGuid().ToString() + "}") -Force
  }

  if (-not (Test-NoteProperty $cmdProfile 'name')) {
    $cmdProfile | Add-Member -NotePropertyName name -NotePropertyValue 'Command Prompt' -Force
  } else {
    $cmdProfile.name = 'Command Prompt'
  }

  if (-not (Test-NoteProperty $cmdProfile 'commandline')) {
    $cmdProfile | Add-Member -NotePropertyName commandline -NotePropertyValue $CommandLine -Force
  } else {
    $cmdProfile.commandline = $CommandLine
  }

  if (-not (Test-NoteProperty $cmdProfile 'startingDirectory')) {
    $cmdProfile | Add-Member -NotePropertyName startingDirectory -NotePropertyValue $StartingDirectory -Force
  } else {
    $cmdProfile.startingDirectory = $StartingDirectory
  }

  if (-not (Test-NoteProperty $cmdProfile 'font') -or $null -eq $cmdProfile.font) {
    $cmdProfile | Add-Member -NotePropertyName font -NotePropertyValue ([pscustomobject]@{}) -Force
  }

  if (-not (Test-NoteProperty $cmdProfile.font 'face')) {
    $cmdProfile.font | Add-Member -NotePropertyName face -NotePropertyValue $FontFace -Force
  } else {
    $cmdProfile.font.face = $FontFace
  }

  if (-not (Test-NoteProperty $cmdProfile.font 'size')) {
    $cmdProfile.font | Add-Member -NotePropertyName size -NotePropertyValue $FontSize -Force
  } else {
    $cmdProfile.font.size = $FontSize
  }

  if (-not (Test-NoteProperty $settings 'defaultProfile')) {
    $settings | Add-Member -NotePropertyName defaultProfile -NotePropertyValue $cmdProfile.guid -Force
  } else {
    $settings.defaultProfile = $cmdProfile.guid
  }

  $json = $settings | ConvertTo-Json -Depth 100
  [System.IO.File]::WriteAllText($wtSettings, $json, [System.Text.UTF8Encoding]::new($false))
  Write-Ok 'Windows Terminal Command Prompt profile updated.'
}

function Prompt-StarshipPresetSelection {
  $presets = @(
    [pscustomobject]@{Name='Nerd Font Symbols';    Id='nerd-font-symbols'},
    [pscustomobject]@{Name='No Nerd Fonts';        Id='no-nerd-font'},
    [pscustomobject]@{Name='Bracketed Segments';   Id='bracketed-segments'},
    [pscustomobject]@{Name='Plain Text Symbols';   Id='plain-text-symbols'},
    [pscustomobject]@{Name='No Runtime Versions';  Id='no-runtimes'},
    [pscustomobject]@{Name='No Empty Icons';       Id='no-empty-icons'},
    [pscustomobject]@{Name='Pure Prompt';          Id='pure-preset'},
    [pscustomobject]@{Name='Pastel Powerline';     Id='pastel-powerline'},
    [pscustomobject]@{Name='Tokyo Night';          Id='tokyo-night'},
    [pscustomobject]@{Name='Gruvbox Rainbow';      Id='gruvbox-rainbow'},
    [pscustomobject]@{Name='Jetpack';              Id='jetpack'},
    [pscustomobject]@{Name='Catppuccin Powerline'; Id='catppuccin-powerline'}
  )

  $defaultId = 'gruvbox-rainbow'

  if ($NonInteractive) {
    return $defaultId
  }

  Write-Host ''
  Write-Host 'Starship preset selection'
  Write-Host 'Choose a theme preset by number. Press Enter for the default (Gruvbox Rainbow).'
  Write-Host ''

  for ($i = 0; $i -lt $presets.Count; $i++) {
    $n = $i + 1
    Write-Host ('  {0,2}) {1} ({2})' -f $n, $presets[$i].Name, $presets[$i].Id)
  }

  $choice = Read-Host ("`nEnter selection (1-{0})" -f $presets.Count)
  if ([string]::IsNullOrWhiteSpace($choice)) {
    return $defaultId
  }

  $num = 0
  if (-not [int]::TryParse($choice.Trim(), [ref]$num)) {
    return $defaultId
  }
  if ($num -lt 1 -or $num -gt $presets.Count) {
    return $defaultId
  }

  return $presets[$num - 1].Id
}

function Resolve-RequiredTools {
  Refresh-ProcessPathFromRegistry

  $clinkDir = Join-Path ${env:ProgramFiles(x86)} 'clink'
  $starshipDir = Join-Path $env:ProgramFiles 'starship\bin'

  # Prefer known stable install locations first, based on common winget layouts.
  # On this machine Clink is installed in C:\Program Files (x86)\clink and exposes
  # clink_x64.exe plus clink.bat, while Starship is at C:\Program Files\starship\bin\starship.exe.
  $clinkCandidates = @(
    (Join-Path $clinkDir 'clink_x64.exe'),
    (Join-Path $clinkDir 'clink.bat'),
    (Join-Path $clinkDir 'clink_x86.exe'),
    (Join-Path $clinkDir 'clink.exe'),
    (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\clink.exe'),
    (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\clink.bat'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Clink\clink_x64.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Clink\clink.bat')
  ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

  $starshipCandidates = @(
    (Join-Path $starshipDir 'starship.exe'),
    (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\starship.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\starship\starship.exe')
  ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

  $clinkResolved = $null
  foreach ($candidate in $clinkCandidates) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      $clinkResolved = $candidate
      break
    }
  }

  if (-not $clinkResolved -and (Test-Path -LiteralPath $clinkDir)) {
    $clinkMatch = Get-ChildItem -Path $clinkDir -Recurse -File -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -in @('clink_x64.exe', 'clink.bat', 'clink_x86.exe', 'clink.exe') } |
      Sort-Object @{ Expression = {
        switch ($_.Name.ToLowerInvariant()) {
          'clink_x64.exe' { 0 }
          'clink.bat'     { 1 }
          'clink_x86.exe' { 2 }
          'clink.exe'     { 3 }
          default         { 99 }
        }
      }} |
      Select-Object -First 1

    if ($clinkMatch) {
      $clinkResolved = $clinkMatch.FullName
    }
  }

  $starshipResolved = $null
  foreach ($candidate in $starshipCandidates) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      $starshipResolved = $candidate
      break
    }
  }

  if (-not $starshipResolved) {
    $starshipCmd = Get-Command 'starship' -ErrorAction SilentlyContinue
    if ($starshipCmd -and $starshipCmd.Source) {
      $starshipResolved = $starshipCmd.Source
    }
  }

  if (-not $starshipResolved -and (Test-Path -LiteralPath $env:ProgramFiles)) {
    $starshipMatch = Get-ChildItem -Path $env:ProgramFiles -Recurse -File -Filter 'starship.exe' -ErrorAction SilentlyContinue |
      Select-Object -First 1
    if ($starshipMatch) {
      $starshipResolved = $starshipMatch.FullName
    }
  }

  if (-not $clinkResolved) {
    Fail "Clink appears installed, but no usable executable was found under '$clinkDir'."
  }

  if (-not $starshipResolved) {
    Fail "Starship appears installed, but no usable executable was found."
  }

  return [pscustomobject]@{
    Clink = $clinkResolved
    Starship = $starshipResolved
  }
}

# ---------------------------
# Hard stop early if prerequisites are missing
# ---------------------------
Assert-CommandExists -Name 'git' -Hint 'Install Git for Windows, then re-run.'
Assert-CommandExists -Name 'winget' -Hint 'Winget is required (App Installer). Then re-run.'

# ---------------------------
# Logging
# ---------------------------
if ([string]::IsNullOrWhiteSpace($LogPath)) {
  $logsDir = Join-Path $PSScriptRoot 'logs'
  Ensure-Directory $logsDir
  $LogPath = Join-Path $logsDir ('setup-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
}
$script:LogPath = $LogPath
$script:TranscriptPath = [System.IO.Path]::ChangeExtension($script:LogPath, '.transcript.txt')
New-Item -ItemType File -Path $script:LogPath -Force | Out-Null
Write-Log 'Script started.'
Write-Log ("INFO : Transcript path: " + $script:TranscriptPath)

try {
  Start-Transcript -LiteralPath $script:TranscriptPath -Append -Force | Out-Null
  $script:TranscriptStarted = $true
} catch {
  Write-WarnMsg "Could not start transcript logging: $($_.Exception.Message)"
  Write-Log ("WARN : Start-Transcript failed: " + $_.Exception.Message)
}

# ---------------------------
# Check repo config folder
# ---------------------------
$configsDir = Join-Path $PSScriptRoot 'configs'
if (-not (Test-Path -LiteralPath $configsDir)) {
  Fail "Missing folder: $configsDir (expected ./configs next to this script)."
}
$clinkOverrides = Join-Path $configsDir 'clink.overrides.txt'

Write-Section 'Repository configuration'
Write-Ok ("Config folder detected: {0}" -f $configsDir)
if (Test-Path -LiteralPath $clinkOverrides) {
  Write-Detail ("Clink overrides: {0}" -f $clinkOverrides)
} else {
  Write-Skip 'clink.overrides.txt not found; only applying clink.logo=none'
}

# ---------------------------
# Install packages
# ---------------------------
Write-Section 'Packages'
if (-not $SkipPackageInstall) {
  Winget-EnsurePackage -Id 'chrisant996.Clink'
  Winget-EnsurePackage -Id 'Starship.Starship'
} else {
  Write-Skip 'Skipping package installation by request.'
}

$tools = Resolve-RequiredTools
$clinkExe = $tools.Clink
$starshipExe = $tools.Starship

Write-Section 'Resolved tools'
Write-Ok ("Clink executable: {0}" -f $clinkExe)
Write-Ok ("Starship executable: {0}" -f $starshipExe)

# ---------------------------
# Configure Clink + Starship integration
# ---------------------------
Write-Section 'Clink + Starship integration'
$clinkState = Join-Path $env:LOCALAPPDATA 'clink'
Ensure-Directory $clinkState

Write-Step 'Configuring Clink autorun'
Invoke-External -FilePath $clinkExe -ArgumentList @('autorun', 'install') -What 'clink autorun install'
Write-Ok 'Clink autorun is configured.'

$starshipLuaPath = Join-Path $clinkState 'starship.lua'
$escapedStarshipPath = $starshipExe.Replace("'", "''")
$starshipLua = 'load(io.popen([["' + $starshipExe + '" init cmd]]):read("*a"))()'
Set-Content -LiteralPath $starshipLuaPath -Value $starshipLua -Encoding ASCII
Write-Ok 'Starship Lua bridge written.'

Write-Step 'Applying base Clink settings'
Invoke-External -FilePath $clinkExe -ArgumentList @('set', 'clink.logo', 'none') -What 'clink set clink.logo none'
Write-Ok 'Clink logo disabled.'

# ---------------------------
# Install clink-completions
# ---------------------------
Write-Section 'Shell completions'
if (-not $SkipCompletions) {
  $ccDir = Join-Path $clinkState 'clink-completions'
  if (Test-Path -LiteralPath $ccDir) {
    Write-Step 'Updating clink-completions'
    Invoke-External -FilePath 'git' -ArgumentList @('-C', $ccDir, 'pull', '--ff-only') -What 'git pull clink-completions'
  } else {
    Write-Step 'Cloning clink-completions'
    Invoke-External -FilePath 'git' -ArgumentList @('clone', 'https://github.com/vladimir-kotikov/clink-completions', $ccDir) -What 'git clone clink-completions'
  }

  Write-Step 'Registering clink-completions scripts'
  Invoke-External -FilePath $clinkExe -ArgumentList @('installscripts', $ccDir) -What 'clink installscripts' -SuccessPatterns @(
    'already installed',
    'Script path .* is already installed'
  )
} else {
  Write-Skip 'Skipping clink-completions by request.'
}

# ---------------------------
# Fonts
# ---------------------------
Write-Section 'Fonts'
if (-not $SkipFonts) {
  Install-NerdFontZipPerUser -ZipUrl 'https://github.com/ryanoasis/nerd-fonts/releases/download/v3.4.0/FiraCode.zip'
} else {
  Write-Skip 'Skipping Nerd Font installation by request.'
}

# ---------------------------
# Apply Clink overrides (optional)
# ---------------------------
Write-Section 'Clink settings'
Apply-ClinkOverrides -OverridesPath $clinkOverrides -ClinkExe $clinkExe

# ---------------------------
# Starship preset + overrides
# ---------------------------
Write-Section 'Starship theme'
$cfgDir = Join-Path $env:USERPROFILE '.config'
Ensure-Directory $cfgDir

$starshipToml = Join-Path $cfgDir 'starship.toml'
$starshipOverrides = Join-Path $configsDir 'starship_overrides.txt'
$tempPreset = Join-Path $cfgDir 'starship.preset.toml'

if ([string]::IsNullOrWhiteSpace($StarshipPreset)) {
  $StarshipPreset = Prompt-StarshipPresetSelection
}
if ([string]::IsNullOrWhiteSpace($StarshipPreset)) {
  $StarshipPreset = 'gruvbox-rainbow'
}

Write-Step 'Applying Starship preset'
Write-Detail ("Preset: {0}" -f $StarshipPreset)

Invoke-External -FilePath $starshipExe -ArgumentList @('preset', $StarshipPreset, '-o', $tempPreset) -What "starship preset $StarshipPreset"

if (-not (Test-Path -LiteralPath $tempPreset)) {
  & $starshipExe preset $StarshipPreset -o $tempPreset
}

if (-not (Test-Path -LiteralPath $tempPreset)) {
  Fail "Starship preset file was not created: $tempPreset"
}

if (-not (Test-Path -LiteralPath $tempPreset)) {
  Fail "Starship preset file was not created: $tempPreset"
}

$utf8 = [System.Text.Encoding]::UTF8
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$presetText = [System.IO.File]::ReadAllText($tempPreset, $utf8)

$overrideText = ''
if (Test-Path -LiteralPath $starshipOverrides) {
  Write-Detail ("Overrides: {0}" -f $starshipOverrides)
  $overrideText = [System.IO.File]::ReadAllText($starshipOverrides, $utf8).Trim()
}

if (-not [string]::IsNullOrWhiteSpace($overrideText)) {
  $finalText = $overrideText + "`r`n`r`n" + $presetText
} else {
  $finalText = $presetText
}

[System.IO.File]::WriteAllText($starshipToml, $finalText, $utf8NoBom)

Remove-Item -LiteralPath $tempPreset -Force -ErrorAction SilentlyContinue

# ---------------------------
# Optional: Windows Terminal default cmd profile
# ---------------------------
Write-Section 'Windows Terminal profile'
if (-not $SkipTerminalProfile) {
  Setup-WindowsTerminalDefaultCmdProfile -CommandLine '%SystemRoot%\System32\cmd.exe /q /k cls' -StartingDirectory $env:USERPROFILE
} else {
  Write-Skip 'Skipping Windows Terminal default profile update by request.'
}

Write-Section 'Completed'
Write-Ok 'Setup finished successfully.'
Write-Detail 'Open a NEW Windows Terminal tab to see Clink + Starship + completions.'
Write-Detail 'If fonts do not apply immediately, restart Windows Terminal (or sign out/in).'
Write-Detail ("Log file: {0}" -f $script:LogPath)
if ($script:TranscriptStarted -and $script:TranscriptPath) {
  Write-Detail ("Transcript: {0}" -f $script:TranscriptPath)
}
Write-Log 'Script completed successfully.'
if ($script:TranscriptStarted) {
  try { Stop-Transcript | Out-Null } catch {}
}
