$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot
$scriptPosix = ($scriptDir -replace '\\', '/')

$bashCandidates = @(
  'C:\Program Files\Git\bin\bash.exe',
  'C:\Program Files\Git\usr\bin\bash.exe'
)

$bash = $bashCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $bash) {
  Write-Error 'xui-sync: Git Bash was not found.'
  exit 1
}

$command = 'cd ''' + $scriptPosix + ''' && exec ./xui-sync.sh "$@"'

& $bash --login -lc $command xui-sync @args
exit $LASTEXITCODE
