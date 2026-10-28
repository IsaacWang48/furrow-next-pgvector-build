param([switch]$DiagnosticsOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:GITHUB_REPOSITORY -ne 'IsaacWang48/furrow-next-pgvector-build') { throw 'Remote dedicated repository only' }
$out=Join-Path $PSScriptRoot 'out'
if ($DiagnosticsOnly) {
    $delivery=Join-Path $out 'package/provenance'
    if (-not (Test-Path -LiteralPath $delivery)) { Write-Output 'No public diagnostic files created'; return }
    $transport=Join-Path $out 'failed-diagnostics.zip'
    $prefix='PGVECTOR_FAILED_TRANSPORT_'
} else {
    $delivery=Join-Path $out 'delivery'
    $null=New-Item -ItemType Directory -Path $delivery
    foreach ($file in @('pgvector-0.8.2-edb17.11-win-x64.zip','attestation.jsonl','attestation-verification.json','attestation-verification.log')) { Copy-Item -LiteralPath (Join-Path $out $file) -Destination $delivery }
    $transport=Join-Path $out 'transport.zip'
    $prefix='PGVECTOR_TRANSPORT_'
}
[IO.Compression.ZipFile]::CreateFromDirectory($delivery,$transport)
$bytes=[IO.File]::ReadAllBytes($transport)
# This limit protects the documented delivery channel, not local worker resources.
# Stop rather than switch to billed artifact storage if output becomes oversized.
if ($bytes.Length -gt 10MB) { throw 'Reviewed log delivery limited to 10MiB; no paid fallback' }
$sha=(Get-FileHash -LiteralPath $transport -Algorithm SHA256).Hash.ToLowerInvariant()
$text=[Convert]::ToBase64String($bytes)
$chunks=[int][Math]::Ceiling($text.Length/4096.0)
[Console]::WriteLine("$($prefix)BEGIN $($bytes.Length) $sha $chunks")
for ($i=0;$i -lt $chunks;$i++) { $piece=$text.Substring($i*4096,[Math]::Min(4096,$text.Length-$i*4096)); [Console]::WriteLine("$($prefix)CHUNK $i $piece") }
[Console]::WriteLine("$($prefix)END $sha")
