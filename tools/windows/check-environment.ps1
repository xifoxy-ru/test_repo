[CmdletBinding()]
param(
    [string]$Workspace = (Join-Path $PSScriptRoot '..\..'),
    [switch]$ApplyIdentity
)

$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false, $true)
$logWriter = $null
$reportedFailure = $false
$exitCode = 1

function Write-Status([string]$Message) {
    Write-Host $Message
    if ($null -ne $logWriter) {
        $logWriter.WriteLine($Message)
        $logWriter.Flush()
    }
}

function Stop-Check([string]$Message) {
    $script:reportedFailure = $true
    Write-Status "실패 — $Message"
    throw 'Check failed'
}

function Invoke-LocalGit([string[]]$GitArguments) {
    # Windows PowerShell can wrap native stderr in error records. Keep it private.
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& $gitPath --no-pager -C $root @GitArguments 2>$null)
        [pscustomobject]@{ Code = $LASTEXITCODE; Lines = $output }
    } catch {
        [pscustomobject]@{ Code = -1; Lines = @() }
    }
}

function Test-IdentityValue([string]$Key, [string]$Value) {
    if ($Value -match '[\x00-\x1F\x7F-\x9F"]' -or $Value.Trim() -cne $Value) {
        return $false
    }
    if ($Key -eq 'GIT_NAME') {
        return $Value.Length -gt 0 -and $Value -notmatch '[<>]' -and -not $Value.EndsWith('\')
    }
    return $Value -cmatch '^[A-Za-z0-9.!#$%&''*+/=?^_{|}~-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$'
}

function Read-Settings {
    $settings = @{ GIT_NAME = ''; GIT_EMAIL = ''; GIT_REPOSITORY = '' }
    $settingsPath = Join-Path $root '.user_info'
    try {
        $item = Get-Item -LiteralPath $settingsPath -Force
    } catch [System.Management.Automation.ItemNotFoundException] {
        return $settings
    } catch {
        Stop-Check '.user_info에 접근할 수 없습니다.'
    }
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        Stop-Check '.user_info는 이 폴더에 직접 저장한 일반 파일이어야 합니다.'
    }
    try {
        $content = $utf8.GetString([IO.File]::ReadAllBytes($settingsPath))
    } catch {
        Stop-Check '.user_info를 읽을 수 없습니다. UTF-8 일반 텍스트로 저장하세요.'
    }
    if ($content.StartsWith([string][char]0xFEFF, [StringComparison]::Ordinal)) {
        $content = $content.Substring(1)
    }

    $seen = @{}
    $lineNumber = 0
    foreach ($line in ($content -split '\r?\n')) {
        $lineNumber++
        if ($line -eq '') { continue }
        if ($line -cnotmatch '^(GIT_NAME|GIT_EMAIL|GIT_REPOSITORY)=(.*)$') {
            Stop-Check ".user_info의 $lineNumber 번째 줄에 예제의 키와 =를 사용하세요."
        }
        $key = $Matches[1]
        $rawValue = $Matches[2]
        if ($seen.ContainsKey($key)) {
            Stop-Check ".user_info에 $key 항목이 두 번 이상 있습니다."
        }
        if ($rawValue -match '[\x00-\x1F\x7F-\x9F]') {
            Stop-Check ".user_info의 $key 값에 제어 문자가 있습니다."
        }
        $value = $rawValue.Trim()
        if ($value.StartsWith('"') -and $value.EndsWith('"') -and $value.Length -ge 2) {
            $value = $value.Substring(1, $value.Length - 2).Trim()
        }
        if ($value.Length -gt 0) {
            if ($key -eq 'GIT_REPOSITORY') {
                if ($value -cnotmatch '^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
                    Stop-Check 'GIT_REPOSITORY에는 원시 GitHub HTTPS 저장소 주소를 쓰세요.'
                }
            } elseif (-not (Test-IdentityValue $key $value)) {
                Stop-Check ".user_info의 $key 값 형식을 확인하세요."
            }
        }
        $seen[$key] = $true
        $settings[$key] = $value
    }
    return $settings
}

function Get-GitIdentity([string]$Key, [string]$GitKey, [switch]$LocalOnly) {
    if ($LocalOnly) {
        $result = Invoke-LocalGit @('config', '--local', '--no-includes', '--null', '--get-all', '--', $GitKey)
    } else {
        $result = Invoke-LocalGit @('config', '--null', '--get', '--', $GitKey)
    }
    if ($result.Code -eq 1 -and $result.Lines.Count -eq 0) { return '' }
    if ($result.Code -ne 0 -or $result.Lines.Count -ne 1) {
        if (-not $LocalOnly) { return '' }
        Stop-Check "저장소 로컬 $GitKey 값을 한 개로 확인할 수 없습니다."
    }
    $parts = $result.Lines[0].Split([char]0)
    if ($parts.Count -ne 2 -or $parts[1] -ne '' -or -not (Test-IdentityValue $Key $parts[0])) {
        if (-not $LocalOnly) { return '' }
        Stop-Check "저장소 로컬 $GitKey 값이 비어 있거나 형식이 다릅니다. 로컬 설정을 확인하세요."
    }
    return $parts[0]
}

function Test-CommitIdentity([hashtable]$Expected) {
    # Git may infer values from the operating system. Compare both roles to
    # explicit configured or requested values without showing the native output.
    $consistent = $true
    foreach ($role in @('GIT_AUTHOR_IDENT', 'GIT_COMMITTER_IDENT')) {
        $result = Invoke-LocalGit @('var', $role)
        if ($result.Code -ne 0 -or $result.Lines.Count -ne 1 -or
            $result.Lines[0] -notmatch '^(.+) <([^<>]+)> -?[0-9]+ [+-][0-9]{4}$' -or
            $Matches[1] -cne $Expected.GIT_NAME -or $Matches[2] -cne $Expected.GIT_EMAIL) {
            $consistent = $false
        }
    }
    return $consistent
}

try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or
        $PSVersionTable.PSVersion -lt [version]'5.1') {
        Stop-Check 'Windows와 PowerShell 5.1 이상이 필요합니다.'
    }
    [Console]::OutputEncoding = $utf8
    try {
        $workspaceItem = Get-Item -LiteralPath $Workspace -Force
        if (-not $workspaceItem.PSIsContainer -or $workspaceItem.PSProvider.Name -ne 'FileSystem') {
            throw 'Workspace must be a filesystem directory'
        }
        $root = $workspaceItem.FullName
        for ($directory = $workspaceItem; $null -ne $directory; $directory = $directory.Parent) {
            if ([IO.File]::GetAttributes($directory.FullName) -band [IO.FileAttributes]::ReparsePoint) {
                throw 'Workspace ancestry contains a reparse point'
            }
        }
    } catch {
        Stop-Check '작업 폴더 또는 상위 경로를 확인할 수 없습니다. 링크·정션을 거치지 않는 실제 폴더를 지정하세요.'
    }

    $gitCommand = Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $gitCommand) {
        Stop-Check 'Git을 찾을 수 없습니다. 승인된 Git for Windows 설치를 확인하세요.'
    }
    $gitPath = $gitCommand.Source
    $version = Invoke-LocalGit @('--version')
    if ($version.Code -ne 0 -or $version.Lines.Count -ne 1 -or
        $version.Lines[0] -notmatch '^git version ([0-9][0-9A-Za-z.-]+)$') {
        Stop-Check 'Git을 실행하거나 버전을 확인할 수 없습니다.'
    }
    $gitVersion = $Matches[1]

    foreach ($contextKey in @('GIT_DIR', 'GIT_COMMON_DIR', 'GIT_WORK_TREE', 'GIT_CONFIG',
            'GIT_CONFIG_COUNT', 'GIT_CONFIG_PARAMETERS', 'GIT_IMPLICIT_WORK_TREE', 'GIT_INDEX_FILE')) {
        if ([Environment]::GetEnvironmentVariable($contextKey, 'Process')) {
            Stop-Check 'Git 경로 또는 설정을 바꾸는 환경 변수가 있습니다. 기본 환경에서 다시 실행하세요.'
        }
    }
    $top = Invoke-LocalGit @('rev-parse', '--show-toplevel')
    if ($top.Code -ne 0 -or $top.Lines.Count -ne 1 -or
        -not [string]::Equals([IO.Path]::GetFullPath($top.Lines[0]), $root,
            [StringComparison]::OrdinalIgnoreCase)) {
        Stop-Check '지정한 작업 폴더를 Git 저장소의 루트로 확인할 수 없습니다.'
    }

    try {
        $logDir = Join-Path $root 'logs'
        $logDirectory = [IO.Directory]::CreateDirectory($logDir)
        if ($logDirectory.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'Unexpected log directory'
        }
        $logName = 'windows-check-{0}.log' -f [guid]::NewGuid().ToString('N')
        $logStream = [IO.File]::Open((Join-Path $logDir $logName), 'CreateNew', 'Write', 'Read')
        try {
            $logWriter = [IO.StreamWriter]::new($logStream, $utf8)
        } catch {
            $logStream.Dispose()
            throw
        }
    } catch {
        Stop-Check 'logs 폴더에 새 로그를 만들 수 없습니다. 폴더 권한을 확인하세요.'
    }
    Write-Status "로그 — logs\$logName"
    Write-Status "정상 — Windows / PowerShell $($PSVersionTable.PSVersion)"
    Write-Status "정상 — Git $gitVersion"
    Write-Status '정상 — 작업 폴더와 Git 저장소 루트 일치'

    $probePath = Join-Path $root ('.windows-check-probe-{0}.log' -f [guid]::NewGuid().ToString('N'))
    try {
        $probeStream = [IO.File]::Open($probePath, 'CreateNew', 'Write', 'None')
        try {
            $probeStream.WriteByte(0)
        } finally {
            try { $probeStream.Dispose() } finally { [IO.File]::Delete($probePath) }
        }
    } catch {
        Stop-Check '작업 폴더 임시 파일을 만들거나 지우지 못했습니다. 폴더 권한을 확인하세요.'
    }
    Write-Status '정상 — 작업 폴더 쓰기 및 임시 파일 삭제'

    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        try {
            $principal = [Security.Principal.WindowsPrincipal]::new($identity)
            $admin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        } finally {
            $identity.Dispose()
        }
        if ($admin) { Write-Status '정보 — 현재 창에 관리자 권한이 있습니다.' }
        else { Write-Status '정보 — 현재 창은 일반 권한으로 실행 중입니다.' }
    } catch {
        Write-Status '정보 — 관리자 권한 여부를 확인할 수 없습니다.'
    }

    $ghCommand = Get-Command gh.exe -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $ghCommand) {
        Write-Status '선택 — gh가 없습니다. 로컬 작업은 계속할 수 있습니다.'
    } else {
        # --version does not consult authentication or contact GitHub.
        $ErrorActionPreference = 'Continue'
        try {
            $ghVersion = @(& $ghCommand.Source --version 2>$null)
            $ghExit = $LASTEXITCODE
        } catch {
            $ghVersion = @()
            $ghExit = -1
        } finally {
            $ErrorActionPreference = 'Stop'
        }
        if ($ghExit -eq 0 -and $ghVersion.Count -gt 0 -and
            $ghVersion[0] -match '^gh version ([0-9][0-9A-Za-z.-]+)(?: |$)') {
            Write-Status "선택 — gh $($Matches[1])"
        } else {
            Write-Status '선택 — gh가 있지만 버전을 확인할 수 없습니다.'
        }
    }
    Write-Status '미확인 — GitHub 로그인은 공유할 때 각자의 계정으로 확인하세요.'
    Write-Status 'NOT_CHECKED — 제품 런타임은 기술 선택 뒤 확인합니다.'

    $gitKeys = [ordered]@{ GIT_NAME = 'user.name'; GIT_EMAIL = 'user.email' }
    $local = @{}
    $effective = @{}
    foreach ($key in $gitKeys.Keys) {
        $local[$key] = Get-GitIdentity $key $gitKeys[$key] -LocalOnly
        $effective[$key] = Get-GitIdentity $key $gitKeys[$key]
    }
    $settings = Read-Settings
    if ($settings.GIT_REPOSITORY) { Write-Status '선택 — 공유 주소 항목이 있습니다.' }
    else { Write-Status '선택 — 공유 주소는 필요할 때만 기록하세요.' }

    $candidate = @{}
    $missing = @()
    $pending = @()
    $conflicts = @()
    foreach ($key in $gitKeys.Keys) {
        if ($local[$key]) {
            $candidate[$key] = $local[$key]
            if ($settings[$key] -and $settings[$key] -cne $local[$key]) { $conflicts += $key }
        } else {
            $pending += $key
            $candidate[$key] = $settings[$key]
            if (-not $candidate[$key]) {
                $candidate[$key] = $effective[$key]
            }
            if (-not $candidate[$key]) { $missing += $key }
        }
    }
    if ($conflicts.Count -gt 0) {
        Stop-Check ("로컬 Git 값과 설정 파일이 충돌합니다. 파일에서 확인할 항목 — " + ($conflicts -join ', '))
    }
    $roleConfig = Invoke-LocalGit @('config', '--name-only', '--get-regexp',
        '^(author|committer)\.(name|email)$')
    $override = $roleConfig.Code -ne 1 -or $roleConfig.Lines.Count -ne 0
    foreach ($key in @('GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_AUTHOR_DATE',
            'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL', 'GIT_COMMITTER_DATE')) {
        if ($null -ne [Environment]::GetEnvironmentVariable($key, 'Process')) {
            $override = $true
        }
    }
    $effectiveMatches = Test-CommitIdentity $effective
    if ($effective.GIT_NAME -and $effective.GIT_EMAIL -and -not $effectiveMatches) {
        $override = $true
    }
    $identityMatches = $effectiveMatches -and $effective.GIT_NAME -ceq $candidate.GIT_NAME -and
        $effective.GIT_EMAIL -ceq $candidate.GIT_EMAIL
    if ($override) {
        if ($ApplyIdentity) {
            Stop-Check '작성자·커미터 별도 설정이나 환경 변수가 있거나 확인할 수 없어 로컬 적용을 보류합니다.'
        }
        Write-Status '커밋 신원 미확인 — 작성자·커미터 별도 설정이나 환경 변수를 확인하세요.'
    }

    if ($ApplyIdentity -and $pending.Count -gt 0) {
        if ($missing.Count -gt 0) {
            Stop-Check ("로컬 설정을 적용하려면 .user_info에 입력하세요 — " + ($missing -join ', '))
        }

        # Exclude linked worktrees, redirected metadata and config includes before any config write.
        $dotGit = Join-Path $root '.git'
        $gitDir = Invoke-LocalGit @('rev-parse', '--absolute-git-dir')
        $dotGitItem = Get-Item -LiteralPath $dotGit -Force
        if (-not $dotGitItem.PSIsContainer -or ($dotGitItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            $gitDir.Code -ne 0 -or $gitDir.Lines.Count -ne 1 -or
            [IO.Path]::GetFullPath($gitDir.Lines[0]) -ne $dotGit -or
            (Test-Path -LiteralPath (Join-Path $dotGit 'commondir'))) {
            Stop-Check '이 폴더에 직접 있는 단독 Git 저장소만 적용할 수 있습니다.'
        }
        $configItem = Get-Item -LiteralPath (Join-Path $dotGit 'config') -Force
        if ($configItem.PSIsContainer -or ($configItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            Stop-Check '이 폴더의 일반 Git 설정 파일만 적용할 수 있습니다.'
        }
        $indirection = Invoke-LocalGit @('config', '--local', '--no-includes', '--name-only',
            '--get-regexp', '^(include\.|includeif\.|extensions\.worktreeconfig$)')
        if ($indirection.Code -ne 1 -or $indirection.Lines.Count -ne 0) {
            Stop-Check '간접 Git 설정을 사용하는 저장소에는 자동으로 적용할 수 없습니다.'
        }

        Write-Status '적용 시작 — 비어 있는 저장소 로컬 Git 항목만 추가합니다.'
        foreach ($key in $pending) {
            $gitKey = $gitKeys[$key]
            if (Get-GitIdentity $key $gitKey -LocalOnly) {
                Stop-Check "적용 도중 $key 상태가 바뀌었습니다. 적용 결과를 확인하세요."
            }
            $result = Invoke-LocalGit @('config', '--local', '--no-includes', '--add', '--', $gitKey, $candidate[$key])
            if ($result.Code -ne 0) {
                Stop-Check "$key 적용이 실패했습니다. 앞서 성공한 항목은 남습니다. 상태를 확인한 뒤 재시도하세요."
            }
            Write-Status "로컬 쓰기 완료 — $key"
            if ((Get-GitIdentity $key $gitKey -LocalOnly) -cne $candidate[$key]) {
                Stop-Check "$key 적용 결과를 확인할 수 없습니다. 적용 상태를 확인하세요."
            }
        }
        Write-Status '완료 — 요청한 저장소 로컬 Git 설정'
        $identityMatches = Test-CommitIdentity $candidate
    }

    if ($missing.Count -gt 0) {
        Write-Status ("커밋 신원 준비 대기 — 필요한 값 — " + ($missing -join ', '))
    } elseif (-not $override) {
        if ($identityMatches) {
            Write-Status '확인 — 유효한 Git 작성자·커미터가 준비된 값과 일치합니다.'
        } elseif ($ApplyIdentity) {
            Stop-Check '유효한 작성자·커미터를 확인하지 못했습니다. 이미 적용된 로컬 항목은 남습니다.'
        } else {
            Write-Status '커밋 신원 미확인 — 유효한 작성자·커미터가 준비된 값과 일치하는지 확인하세요.'
        }
    }

    Write-Status '완료 — 환경 점검'
    $exitCode = 0
} catch {
    if (-not $reportedFailure) {
        Write-Host '실패 — 환경 점검을 끝내지 못했습니다. 로그 쓰기 권한과 마지막 결과를 확인하세요.'
    }
} finally {
    if ($null -ne $logWriter) {
        try {
            $logWriter.Dispose()
        } catch {
            Write-Host '실패 — 로그를 끝까지 저장하지 못했습니다.'
            $exitCode = 1
        }
    }
}
exit $exitCode
