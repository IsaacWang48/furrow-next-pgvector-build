# Remote-only. Requires the separately approved dedicated public repository.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$lock = Get-Content -LiteralPath "$PSScriptRoot/lock.json" -Raw | ConvertFrom-Json -AsHashtable
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:RUNNER_OS -ne 'Windows' -or $env:RUNNER_ARCH -ne 'X64') { throw 'Requires a GitHub-hosted Windows x64 runner; never run on the local PC' }
if ($env:GITHUB_REPOSITORY -ne $lock.repository -or $env:GITHUB_REF -ne 'refs/heads/main' -or $env:GITHUB_EVENT_NAME -ne 'workflow_dispatch') { throw 'Wrong repository/ref/event' }
if ((Get-Content -LiteralPath $env:GITHUB_EVENT_PATH -Raw | ConvertFrom-Json).repository.private) { throw 'Public standard-runner build only; no paid fallback' }
$publication = Get-Content -LiteralPath "$PSScriptRoot/PUBLICATION-ALLOWLIST.json" -Raw | ConvertFrom-Json
foreach ($entry in $publication.files) {
    $file=Join-Path $PSScriptRoot $entry.file
    if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() -ne $entry.sha256) { throw "Reviewed publication hash mismatch: $($entry.file)" }
}
$expectedFiles=@($publication.files.file) + 'PUBLICATION-ALLOWLIST.json'
$tracked=@(& git -C $PSScriptRoot ls-files)
if ($LASTEXITCODE -ne 0 -or (Compare-Object ($tracked | Sort-Object) ($expectedFiles | Sort-Object))) { throw 'Unexpected repository files/history publication; refuse build' }
$out = Join-Path $PSScriptRoot 'out'
if (Test-Path -LiteralPath $out) { throw 'Fresh checkout required' }
$null = New-Item -ItemType Directory -Path "$out/package/provenance"
$logs = "$out/package/provenance"
$work = Join-Path $env:RUNNER_TEMP "pgvector-$($env:GITHUB_RUN_ID)-$($env:GITHUB_RUN_ATTEMPT)"
if (Test-Path -LiteralPath $work) { throw 'Fresh task-owned work directory required' }
$null = New-Item -ItemType Directory -Path $work
function Save-Json($Name, $Value) { $Value | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath "$logs/$Name" -Encoding utf8NoBOM }
function Hash($Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Run($Exe, [string[]]$Arguments, $Name, [int[]]$Allowed = @(0)) {
    $start = Get-Date
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $Exe
    $info.WorkingDirectory = (Get-Location).Path
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($arg in $Arguments) { $info.ArgumentList.Add($arg) }
    $process = [Diagnostics.Process]::Start($info)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $text = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
    [IO.File]::WriteAllText("$logs/$Name.log", $text)
    Save-Json "$Name.command.json" @{exe=$Exe; args=$Arguments; cwd=(Get-Location).Path; exit=$process.ExitCode; started=$start.ToUniversalTime().ToString('o'); ended=(Get-Date).ToUniversalTime().ToString('o')}
    if ($Allowed -notcontains $process.ExitCode) { throw "$Name failed ($($process.ExitCode)); inspect retained command/log" }
    return $text
}
function Download($Spec, $Path) {
    Invoke-WebRequest -Uri $Spec.url -OutFile $Path
    if ((Get-Item -LiteralPath $Path).Length -ne $Spec.bytes -or (Hash $Path) -ne $Spec.sha256) { throw 'Public archive size/hash mismatch' }
}
function Expand-Checked($Archive, $Destination, [string[]]$Prefixes) {
    $root = [IO.Path]::GetFullPath($Destination) + [IO.Path]::DirectorySeparatorChar
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        foreach ($entry in $zip.Entries) {
            if ($entry.FullName.Contains('\') -or $entry.FullName.StartsWith('/') -or (($entry.ExternalAttributes -shr 16) -band 0xf000) -eq 0xa000) { throw 'Unsafe archive entry' }
            $target = [IO.Path]::GetFullPath((Join-Path $Destination $entry.FullName))
            if (-not $target.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw 'Archive traversal' }
            $selected = $false
            foreach ($prefix in $Prefixes) { if ($entry.FullName.StartsWith($prefix, [StringComparison]::Ordinal)) { $selected = $true } }
            if (-not $selected -or $entry.FullName.EndsWith('/')) { continue }
            $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $false)
        }
    } finally { $zip.Dispose() }
}
$env:PGROOT = "$work/pgsql"
$env:PGHOST = '127.0.0.1'
$env:PGPORT = '55437'
$env:PGUSER = 'pgvector_build'
$env:PGDATABASE = 'postgres'
# No user/service connection configuration is accepted by this disposable test.
foreach ($key in @('PGSERVICE','PGSERVICEFILE','PGPASSWORD','PGPASSFILE','PGOPTIONS','PGSSLMODE','PGSSLROOTCERT','PGDATABASE','PGHOSTADDR')) { Remove-Item "Env:$key" -ErrorAction SilentlyContinue }
$env:PGDATABASE = 'postgres'
# Do not inherit unreviewed compiler overrides from a future runner image.
foreach ($key in @('CC','CFLAGS','CPPFLAGS','LDFLAGS','PG_CFLAGS','OPTFLAGS','NMAKEFLAGS','MAKEFLAGS','CL','_CL_','LINK','_LINK_','INIT')) { Remove-Item "Env:$key" -ErrorAction SilentlyContinue }
$env:CC='cl'
$env:VSCMD_SKIP_SENDTELEMETRY='1'
$data = "$work/data"
@{work=$work; pgroot=$env:PGROOT; data=$data; port=$env:PGPORT; run=$env:GITHUB_RUN_ID; attempt=$env:GITHUB_RUN_ATTEMPT} | ConvertTo-Json | Set-Content -LiteralPath "$out/state.json" -Encoding utf8NoBOM
$passed = $false
try {
    if (Get-NetTCPConnection -LocalPort ([int]$env:PGPORT) -State Listen -ErrorAction SilentlyContinue) { throw 'Disposable port occupied; do not stop its owner' }
    Download $lock.postgres "$work/postgresql.zip"
    Download $lock.source "$work/pgvector.zip"
    Expand-Checked "$work/postgresql.zip" $work @('pgsql/bin/','pgsql/lib/','pgsql/share/','pgsql/include/')
    Expand-Checked "$work/pgvector.zip" $work @("$($lock.source.prefix)/")
    foreach ($file in $lock.postgres.files.Keys) { if ((Hash "$env:PGROOT/$file") -ne $lock.postgres.files[$file]) { throw "Prepared runtime/development file mismatch: $file" } }
    $source = Join-Path $work $lock.source.prefix
    $sourceFiles = @(Get-ChildItem -LiteralPath $source -Recurse -File | ForEach-Object { @{file=[IO.Path]::GetRelativePath($source,$_.FullName).Replace('\','/'); sha256=(Hash $_.FullName); bytes=$_.Length} })
    Save-Json 'source-files.json' $sourceFiles
    $vswhere = "${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
    if (-not (Test-Path -LiteralPath $vswhere)) { throw 'Preinstalled Visual Studio discovery absent; no installation permitted' }
    $vs = (& $vswhere -latest -version '[17.0,18.0)' -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath).Trim()
    if (-not $vs) { throw 'Preinstalled VS2022 C++ tools absent' }
    $dev = Join-Path $vs 'Common7/Tools/VsDevCmd.bat'
    # Capture to memory only. Never log the full runner environment or tokens.
    $line = '"' + $dev + '" -no_logo -arch=x64 -host_arch=x64 -vcvars_ver=' + $lock.toolchain.vcvars + ' -winsdk=' + $lock.toolchain.sdk + ' >nul && set'
    $lines = & $env:ComSpec /d /s /c $line
    if ($LASTEXITCODE -ne 0) { throw 'Preinstalled toolchain initialization failed' }
    $allowed = @('PATH','INCLUDE','LIB','LIBPATH','VCToolsInstallDir','VCToolsVersion','WindowsSdkDir','WindowsSDKVersion','VSCMD_VER','VSCMD_ARG_TGT_ARCH','UCRTVersion','UniversalCRTSdkDir')
    foreach ($line in $lines) { if ($line -match '^([^=]+)=(.*)$' -and $allowed -contains $Matches[1]) { [Environment]::SetEnvironmentVariable($Matches[1],$Matches[2],'Process') } }
    if ($env:VCToolsVersion -notlike '14.44.*' -or $env:WindowsSDKVersion.TrimEnd('\') -ne $lock.toolchain.sdk -or $env:VSCMD_ARG_TGT_ARCH -ne 'x64') { throw 'Unreviewed toolchain version/architecture' }
    $tools = @{}
    foreach ($tool in @('cl.exe','nmake.exe','dumpbin.exe','python.exe','gh.exe')) { $file=(Get-Command $tool -CommandType Application).Source; $tools[$tool]=@{path=$file; sha256=(Hash $file); version=(Get-Item -LiteralPath $file).VersionInfo.FileVersion} }
    Save-Json 'toolchain.json' @{imageOS=$env:ImageOS; imageVersion=$env:ImageVersion; runnerOS=$env:RUNNER_OS; runnerArch=$env:RUNNER_ARCH; os=[Environment]::OSVersion.VersionString; visualStudio=$vs; vcTools=$env:VCToolsVersion; sdk=$env:WindowsSDKVersion; implicitOptions=@{CL=$env:CL; _CL_=$env:_CL_; LINK=$env:LINK; _LINK_=$env:_LINK_; INIT=$env:INIT}; tools=$tools}
    Copy-Item -LiteralPath "$PSScriptRoot/lock.json" -Destination "$logs/lock.json"
    $null = Run $tools['cl.exe'].path @('/Bv') 'compiler-version' @(0,2)
    $null = Run $tools['python.exe'].path @('--version') 'python-version'
    $null = Run "$env:PGROOT/bin/postgres.exe" @('--version') 'postgres-version'
    Push-Location $source
    try {
        $null = Run $tools['nmake.exe'].path @('/NOLOGO','/F','Makefile.win') 'build'
        foreach ($file in $sourceFiles) { if ((Hash (Join-Path $source $file.file)) -ne $file.sha256) { throw 'Upstream source changed during compilation' } }
        $null = Run $tools['dumpbin.exe'].path @('/headers','/imports','/exports',"$source/vector.dll") 'dumpbin'
        $null = Run $tools['python.exe'].path @('-I',"$PSScriptRoot/inspect_pe.py","$source/vector.dll","$env:PGROOT/bin/postgres.exe","$PSScriptRoot/lock.json","$logs/pe.json") 'pe-inspection'
        $null = Run $tools['nmake.exe'].path @('/NOLOGO','/F','Makefile.win','install') 'install-remote-private-runtime'
        if ((Hash "$source/vector.dll") -ne (Hash "$env:PGROOT/lib/vector.dll")) { throw 'Installed DLL differs from built DLL' }
        $null = Run "$env:PGROOT/bin/initdb.exe" @('-D',$data,'-U',$env:PGUSER,'-A','trust','--encoding=UTF8','--locale=C','--no-instructions') 'initdb'
        $options = "-h 127.0.0.1 -p $env:PGPORT -c shared_preload_libraries= -c max_connections=20"
        $null = Run "$env:PGROOT/bin/pg_ctl.exe" @('-D',$data,'-l',"$logs/server.log",'-o',$options,'-w','-t','60','start') 'start'
        $null = Run "$env:PGROOT/bin/psql.exe" @('-X','-w','-v','ON_ERROR_STOP=1','-f',"$PSScriptRoot/smoke.sql") 'smoke'
        $null = Run $tools['nmake.exe'].path @('/NOLOGO','/F','Makefile.win','installcheck') 'upstream-regression'
        if ((Get-Content -LiteralPath "$logs/smoke.log" -Raw) -notmatch 'PGVECTOR_REMOTE_SMOKE_PASS') { throw 'Smoke sentinel missing' }
        $expected = @('bit','btree','cast','copy','halfvec','hnsw_bit','hnsw_halfvec','hnsw_sparsevec','hnsw_vector','ivfflat_bit','ivfflat_halfvec','ivfflat_vector','sparsevec','vector_type')
        $actual = Get-Content -LiteralPath "$logs/upstream-regression.log" -Raw
        foreach ($case in $expected) { if ($actual -notmatch ('(?m)^test\s+' + [regex]::Escape($case) + '\s+\.\.\.\s+ok')) { throw "Missing upstream PASS: $case" } }
        foreach ($file in $sourceFiles) { if ((Hash (Join-Path $source $file.file)) -ne $file.sha256) { throw 'Upstream source changed during regression tests' } }
        if ((Hash "$source/sql/vector.sql") -ne (Hash "$source/sql/vector--0.8.2.sql")) { throw 'Generated installation SQL differs from upstream' }
        if ((Hash "$source/vector.dll") -ne (Hash "$env:PGROOT/lib/vector.dll")) { throw 'Tested DLL differs from packaged DLL' }
        Save-Json 'tests.json' @{smoke='PASS'; upstream=$expected; upstreamCount=$expected.Count; connectedAcceptance='NOT_TESTED'; applicationData='NONE'; substitutedBoundary='Synthetic remote standalone PostgreSQL, not hosted application/voice acceptance'}
        $null = New-Item -ItemType Directory -Path "$out/package/extension/sql"
        Copy-Item -LiteralPath "$source/vector.dll" -Destination "$out/package/extension/vector.dll"
        Copy-Item -LiteralPath "$source/vector.control" -Destination "$out/package/extension/vector.control"
        Copy-Item -LiteralPath "$source/LICENSE" -Destination "$out/package/extension/LICENSE"
        Get-ChildItem -LiteralPath "$source/sql" -Filter 'vector--*.sql' -File | Copy-Item -Destination "$out/package/extension/sql"
        $passed = $true
    } finally {
        # Preserve actual failures before the runner is destroyed. The success
        # path and failure diagnostic transport retain the same original bytes.
        if (Test-Path -LiteralPath "$source/results") {
            $null=New-Item -ItemType Directory -Path "$logs/regression-results" -Force
            Get-ChildItem -LiteralPath "$source/results" -Filter '*.out' -File | Copy-Item -Destination "$logs/regression-results"
        }
        foreach ($name in @('regression.out','regression.diffs')) { if (Test-Path -LiteralPath "$source/$name") { Copy-Item -LiteralPath "$source/$name" -Destination "$logs/$name" } }
        Pop-Location
    }
} finally { & "$PSScriptRoot/cleanup.ps1" }
if (-not $passed) { throw 'Build/tests incomplete' }
$null = New-Item -ItemType Directory -Path "$logs/build-instructions"
foreach ($file in @('build.ps1','cleanup.ps1','emit-log.ps1','inspect_pe.py','smoke.sql','lock.json','README.md','PUBLICATION-ALLOWLIST.json','.github/workflows/build.yml','.gitattributes','.gitignore')) {
    $target=Join-Path "$logs/build-instructions" $file
    $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $target
}
Save-Json 'build.json' @{repository=$env:GITHUB_REPOSITORY; sourceCommit=$env:GITHUB_SHA; ref=$env:GITHUB_REF; workflowRef=$env:GITHUB_WORKFLOW_REF; runId=$env:GITHUB_RUN_ID; attempt=$env:GITHUB_RUN_ATTEMPT; runUrl="https://github.com/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID"; dependencySource=$lock.source; postgres=$lock.postgres; bitReproducibility='NOT_CLAIMED: hosted image and default MSVC timestamps may change'; result='BUILD_STATIC_RUNTIME_REGRESSION_CLEANUP_PASS'}
$files = @(Get-ChildItem -LiteralPath "$out/package" -Recurse -File | Sort-Object FullName | ForEach-Object { @{file=[IO.Path]::GetRelativePath("$out/package",$_.FullName).Replace('\','/'); bytes=$_.Length; sha256=(Hash $_.FullName)} })
$files | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath "$out/package/manifest.json" -Encoding utf8NoBOM
[IO.Compression.ZipFile]::CreateFromDirectory("$out/package", "$out/pgvector-0.8.2-edb17.11-win-x64.zip")
Write-Output "Tested package SHA256: $(Hash "$out/pgvector-0.8.2-edb17.11-win-x64.zip")"
