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
# File redirection prevents a server descendant from retaining a pipe that
# ReadToEndAsync would otherwise wait on after its parent pg_ctl exits.
$script:buildDeadline=[DateTimeOffset]::UtcNow.AddMinutes(23)
$processRunner=@'
"""Windows commands: direct files, suspended job assignment, bounded tree cleanup."""
import ctypes as C
from ctypes import wintypes as W
import datetime
import json
import msvcrt
import os
import subprocess
import sys
import time
from pathlib import Path


class Limits(C.Structure):
    _fields_ = [("process_time", C.c_longlong), ("job_time", C.c_longlong),
                ("flags", W.DWORD), ("min_working", C.c_size_t),
                ("max_working", C.c_size_t), ("active_limit", W.DWORD),
                ("affinity", C.c_size_t), ("priority", W.DWORD), ("scheduling", W.DWORD)]


class IO(C.Structure):
    _fields_ = [(n, C.c_ulonglong) for n in ("read_ops", "write_ops", "other_ops",
                                          "read_bytes", "write_bytes", "other_bytes")]


class Extended(C.Structure):
    _fields_ = [("basic", Limits), ("io", IO), ("process_memory", C.c_size_t),
                ("job_memory", C.c_size_t), ("peak_process", C.c_size_t), ("peak_job", C.c_size_t)]


class Accounting(C.Structure):
    _fields_ = [(n, C.c_longlong) for n in ("user", "kernel", "period_user", "period_kernel")] + [
        (n, W.DWORD) for n in ("page_faults", "total", "active", "terminated")]


class Startup(C.Structure):
    _fields_ = [("cb", W.DWORD), ("reserved", W.LPWSTR), ("desktop", W.LPWSTR),
                ("title", W.LPWSTR)] + [(n, W.DWORD) for n in (
                    "x", "y", "x_size", "y_size", "x_chars", "y_chars", "fill", "flags")] + [
        ("show", W.WORD), ("reserved_size", W.WORD), ("reserved_bytes", C.POINTER(C.c_byte)),
        ("stdin", W.HANDLE), ("stdout", W.HANDLE), ("stderr", W.HANDLE)]


class Process(C.Structure):
    _fields_ = [("process", W.HANDLE), ("thread", W.HANDLE),
                ("pid", W.DWORD), ("tid", W.DWORD)]


class StartupEx(C.Structure):
    _fields_ = [("startup", Startup), ("attributes", C.c_void_p)]


k = C.WinDLL("kernel32", use_last_error=True)
for name, args, result in [
    ("CreateJobObjectW", [C.c_void_p, W.LPCWSTR], W.HANDLE),
    ("SetInformationJobObject", [W.HANDLE, C.c_int, C.c_void_p, W.DWORD], W.BOOL),
    ("QueryInformationJobObject", [W.HANDLE, C.c_int, C.c_void_p, W.DWORD, C.c_void_p], W.BOOL),
    ("AssignProcessToJobObject", [W.HANDLE, W.HANDLE], W.BOOL),
    ("TerminateJobObject", [W.HANDLE, W.UINT], W.BOOL),
    ("TerminateProcess", [W.HANDLE, W.UINT], W.BOOL),
    ("CloseHandle", [W.HANDLE], W.BOOL),
    ("ResumeThread", [W.HANDLE], W.DWORD),
    ("WaitForSingleObject", [W.HANDLE, W.DWORD], W.DWORD),
    ("GetExitCodeProcess", [W.HANDLE, C.POINTER(W.DWORD)], W.BOOL),
    ("InitializeProcThreadAttributeList", [C.c_void_p, W.DWORD, W.DWORD, C.POINTER(C.c_size_t)], W.BOOL),
    ("UpdateProcThreadAttribute", [C.c_void_p, W.DWORD, C.c_size_t, C.c_void_p,
                                   C.c_size_t, C.c_void_p, C.POINTER(C.c_size_t)], W.BOOL),
    ("DeleteProcThreadAttributeList", [C.c_void_p], None),
    ("CreateProcessW", [W.LPCWSTR, W.LPWSTR, C.c_void_p, C.c_void_p, W.BOOL,
                        W.DWORD, C.c_void_p, W.LPCWSTR, C.POINTER(Startup), C.POINTER(Process)], W.BOOL),
]:
    fn = getattr(k, name)
    fn.argtypes, fn.restype = args, result


def require(ok):
    if not ok:
        raise C.WinError(C.get_last_error())


def active(job):
    value = Accounting()
    require(k.QueryInformationJobObject(job, 1, C.byref(value), C.sizeof(value), None))
    return value.active


def stop_tree(job, code):
    require(k.TerminateJobObject(job, code))
    deadline = time.monotonic() + 5
    while active(job):
        if time.monotonic() >= deadline:
            raise RuntimeError("Owned command job still has active processes after termination")
        time.sleep(0.02)


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


cfg = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8-sig"))
assert isinstance(cfg["timeoutSeconds"], (int, float)) and 0 < cfg["timeoutSeconds"] <= 1440
start, clock = now(), time.monotonic()
result = {"exe": cfg["exe"], "args": cfg["args"], "cwd": cfg["cwd"], "started": start,
          "timeoutSeconds": cfg["timeoutSeconds"], "timedOut": False, "treeCleanup": "NOT_STARTED"}
job, proc, assigned, attributes = None, Process(), False, None
try:
    with open(os.devnull, "rb") as stdin, open(cfg["stdout"], "xb") as stdout, open(cfg["stderr"], "xb") as stderr:
        job = k.CreateJobObjectW(None, None)
        require(job)
        limits = Extended()
        limits.basic.flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE; no breakaway allowance.
        require(k.SetInformationJobObject(job, 9, C.byref(limits), C.sizeof(limits)))
        startup = StartupEx()
        startup.startup.cb, startup.startup.flags, startup.startup.show = C.sizeof(startup), 0x101, 0
        handles = [msvcrt.get_osfhandle(f.fileno()) for f in (stdin, stdout, stderr)]
        for handle in handles:
            os.set_handle_inheritable(handle, True)
        startup.startup.stdin, startup.startup.stdout, startup.startup.stderr = handles
        # Restrict inheritance to these three files. Passing every inheritable
        # handle would let a server retain the supervisor's own output pipe.
        size = C.c_size_t()
        if k.InitializeProcThreadAttributeList(None, 1, 0, C.byref(size)) or C.get_last_error() != 122:
            raise RuntimeError("Unexpected process attribute-list sizing result")
        attribute_buffer = C.create_string_buffer(size.value)
        attributes = C.cast(attribute_buffer, C.c_void_p)
        require(k.InitializeProcThreadAttributeList(attributes, 1, 0, C.byref(size)))
        inherited = (W.HANDLE * 3)(*handles)
        require(k.UpdateProcThreadAttribute(attributes, 0, 0x20002, C.byref(inherited),
                                            C.sizeof(inherited), None, None))
        startup.attributes = attributes
        command = C.create_unicode_buffer(subprocess.list2cmdline([cfg["exe"], *cfg["args"]]))
        # Assign while suspended, before a child can spawn an escaping descendant.
        require(k.CreateProcessW(cfg["exe"], command, None, None, True, 0x08080004,
                                None, cfg["cwd"], C.byref(startup.startup), C.byref(proc)))
        result["pid"] = proc.pid
        require(k.AssignProcessToJobObject(job, proc.process))
        assigned = True
        if k.ResumeThread(proc.thread) == 0xFFFFFFFF:
            raise C.WinError(C.get_last_error())
        state = k.WaitForSingleObject(proc.process, int(cfg["timeoutSeconds"] * 1000))
        if state == 258:
            result.update(exit=124, timedOut=True)
            stop_tree(job, 124)
            result.update(treeCleanup="TERMINATED_ZERO_ACTIVE", remainingActive=active(job))
        elif state == 0:
            code = W.DWORD()
            require(k.GetExitCodeProcess(proc.process, C.byref(code)))
            result["exit"] = C.c_int32(code.value).value
            if result["exit"] not in cfg.get("allowed", [0]):
                stop_tree(job, 125)
                result.update(treeCleanup="TERMINATED_ZERO_ACTIVE", remainingActive=active(job))
            else:
                # Successful pg_ctl is allowed to leave its server running until
                # the existing separately owned PostgreSQL cleanup stops it.
                limits.basic.flags = 0
                require(k.SetInformationJobObject(job, 9, C.byref(limits), C.sizeof(limits)))
                result.update(treeCleanup="PRESERVED_AFTER_ALLOWED_PARENT_EXIT", activeAtParentExit=active(job))
        else:
            raise C.WinError(C.get_last_error())
except Exception as error:
    result.update(exit=125, infrastructureError=str(error))
    try:
        if job and assigned:
            stop_tree(job, 125)
            result.update(treeCleanup="TERMINATED_ZERO_ACTIVE", remainingActive=active(job))
        elif proc.process:
            require(k.TerminateProcess(proc.process, 125))
            if k.WaitForSingleObject(proc.process, 5000) != 0:
                raise RuntimeError("Unassigned suspended process did not terminate")
            result["treeCleanup"] = "UNASSIGNED_SUSPENDED_PROCESS_TERMINATED"
    except Exception as cleanup_error:
        result.update(exit=126, cleanupError=str(cleanup_error), treeCleanup="FAILED")
finally:
    if attributes:
        k.DeleteProcThreadAttributeList(attributes)
    for handle in (proc.thread, proc.process, job):
        if handle:
            k.CloseHandle(handle)
result.update(ended=now(), elapsedSeconds=time.monotonic() - clock)
with open(cfg["receipt"], "x", encoding="utf-8") as receipt:
    json.dump(result, receipt, indent=2)
    receipt.write("\n")
print(json.dumps({"command": cfg["name"], "exit": result["exit"], "timedOut": result["timedOut"],
                  "treeCleanup": result["treeCleanup"], "elapsedSeconds": result["elapsedSeconds"]}), flush=True)
'@
[IO.File]::WriteAllText("$logs/process-runner.py",$processRunner)
function Read-CommandLog($File) {
    $stream=[IO.FileStream]::new($File,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    $reader=[IO.StreamReader]::new($stream)
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}
function Run($Exe, [string[]]$Arguments, $Name, [int[]]$Allowed = @(0)) {
    $remaining=[int][Math]::Floor(($script:buildDeadline-[DateTimeOffset]::UtcNow).TotalSeconds)
    if ($remaining -le 0) { throw 'Build deadline reached; reserve cleanup and diagnostics' }
    $limit=if($Name -eq 'upstream-regression'){900}else{180}
    $limit=[Math]::Min($limit,$remaining)
    [Console]::WriteLine("COMMAND_BEGIN $Name; timeout=$limit seconds")
    Save-Json "$Name.input.json" @{name=$Name; exe=$Exe; args=@($Arguments); allowed=@($Allowed); cwd=(Get-Location).Path; stdout="$logs/$Name.stdout.log"; stderr="$logs/$Name.stderr.log"; receipt="$logs/$Name.command.json"; timeoutSeconds=$limit}
    $supervisorOutput=@(& $script:processRunnerPython -I "$logs/process-runner.py" "$logs/$Name.input.json")
    $supervisorExit=$LASTEXITCODE
    foreach($line in $supervisorOutput){[Console]::WriteLine([string]$line)}
    if($supervisorExit -ne 0){throw "Command supervisor failed: $Name"}
    $result=Get-Content -LiteralPath "$logs/$Name.command.json" -Raw | ConvertFrom-Json
    $text=(Read-CommandLog "$logs/$Name.stdout.log")+(Read-CommandLog "$logs/$Name.stderr.log")
    [IO.File]::WriteAllText("$logs/$Name.log",$text)
    [Console]::WriteLine("COMMAND_END $Name; exit=$($result.exit); timeout=$($result.timedOut)")
    if ($result.timedOut -or $Allowed -notcontains $result.exit) { throw "$Name failed ($($result.exit)); inspect retained command/log" }
    return $text
}
function Download($Spec, $Path) {
    [Console]::WriteLine("DOWNLOAD_BEGIN $($Spec.url)")
    & curl.exe --fail --location --proto '=https' --proto-redir '=https' --connect-timeout 30 --max-time 180 --output $Path $Spec.url
    if($LASTEXITCODE -ne 0){throw 'Bounded public dependency download failed; no retry'}
    if ((Get-Item -LiteralPath $Path).Length -ne $Spec.bytes -or (Hash $Path) -ne $Spec.sha256) { throw 'Public archive size/hash mismatch' }
    [Console]::WriteLine("DOWNLOAD_VERIFIED $($Spec.sha256)")
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
    $script:processRunnerPython=$tools['python.exe'].path
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
