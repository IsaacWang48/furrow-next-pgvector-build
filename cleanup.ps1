Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$PSNativeCommandUseErrorActionPreference=$false
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:GITHUB_REPOSITORY -ne 'IsaacWang48/furrow-next-pgvector-build') { throw 'Remote dedicated repository only' }
$stateFile=Join-Path $PSScriptRoot 'out/state.json'
if (-not (Test-Path -LiteralPath $stateFile)) { Write-Output 'No task-owned cluster state'; $global:LASTEXITCODE=0; return }
$state=Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
$expected=[IO.Path]::GetFullPath((Join-Path $env:RUNNER_TEMP "pgvector-$($env:GITHUB_RUN_ID)-$($env:GITHUB_RUN_ATTEMPT)"))
if ([IO.Path]::GetFullPath($state.work) -ne $expected -or [IO.Path]::GetFullPath($state.data) -ne [IO.Path]::GetFullPath("$expected/data") -or [IO.Path]::GetFullPath($state.pgroot) -ne [IO.Path]::GetFullPath("$expected/pgsql") -or $state.port -ne '55437' -or $state.run -ne $env:GITHUB_RUN_ID -or $state.attempt -ne $env:GITHUB_RUN_ATTEMPT) { throw 'Ownership/path mismatch: refuse cleanup' }
$ctl=Join-Path $state.pgroot 'bin/pg_ctl.exe'
$status='NOT_INITIALIZED'
if (Test-Path -LiteralPath "$($state.data)/PG_VERSION") {
    & $ctl -D $state.data status 2>&1 | Out-File "$PSScriptRoot/out/package/provenance/cleanup-status.log" -Append
    if ($LASTEXITCODE -eq 0) { & $ctl -D $state.data -m fast -w -t 60 stop 2>&1 | Out-File "$PSScriptRoot/out/package/provenance/cleanup-status.log" -Append; if ($LASTEXITCODE -ne 0) { throw 'Stop failed' } }
    elseif ($LASTEXITCODE -ne 3) { throw 'Unexpected owned-cluster status' }
    & $ctl -D $state.data status 2>&1 | Out-File "$PSScriptRoot/out/package/provenance/cleanup-status.log" -Append
    if ($LASTEXITCODE -ne 3) { throw 'Owned cluster is not stopped' }
    $status='STOPPED_STATUS_3'
}
if (Get-NetTCPConnection -LocalPort 55437 -State Listen -ErrorAction SilentlyContinue) { throw 'Disposable port still listening; investigate, do not stop another owner' }
@{cluster=$status; port=55437; listener=$false; persistentServiceInstalled=$false; runnerDestruction='Expected GitHub ephemeral VM lifecycle; not independently observed'} | ConvertTo-Json | Set-Content -LiteralPath "$PSScriptRoot/out/package/provenance/cleanup.json" -Encoding utf8NoBOM
Write-Output "Cleanup: $status; no listener on disposable port"
$global:LASTEXITCODE=0
