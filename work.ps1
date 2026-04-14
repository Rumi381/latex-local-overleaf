param(
  [Parameter(Position = 0)]
  [string]$Command = "start",

  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$ArgsRemainder
)

$ErrorActionPreference = "Stop"

function Convert-ToWslPath {
  param([Parameter(Mandatory = $true)][string]$WindowsPath)
  $resolved = (Resolve-Path -LiteralPath $WindowsPath).Path
  if ($resolved -notmatch "^([A-Za-z]):\\(.*)$") {
    throw "Only drive-letter paths are supported: $resolved"
  }
  $drive = $matches[1].ToLowerInvariant()
  $rest = ($matches[2] -replace "\\", "/")
  return "/mnt/$drive/$rest"
}

function Quote-BashArg {
  param([Parameter(Mandatory = $true)][string]$Value)
  return "'" + ($Value -replace "'", "'""'""'") + "'"
}

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$wslRepoRoot = Convert-ToWslPath -WindowsPath $repoRoot
$url = "http://localhost:8080/launchpad"

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
  throw "wsl.exe is required on Windows to run toolkit bash scripts."
}

$bashArgs = @($Command) + ($ArgsRemainder | Where-Object { $_ -ne $null -and $_ -ne "" })
$quoted = @()
foreach ($arg in $bashArgs) {
  $quoted += Quote-BashArg -Value $arg
}

$noOpen = if ($Command -eq "start") { "WORK_NO_OPEN=1 " } else { "" }
$cmd = "cd $(Quote-BashArg -Value $wslRepoRoot) && ${noOpen}bash ./scripts/work.sh $($quoted -join ' ')"

wsl.exe -e bash -lc $cmd
if ($LASTEXITCODE -ne 0) {
  throw "work command failed (exit code $LASTEXITCODE)."
}

if ($Command -eq "start") {
  Start-Process $url
}
