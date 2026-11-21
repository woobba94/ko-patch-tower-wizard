Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)

function Get-Sha256([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
    } finally {
        $algorithm.Dispose()
        $stream.Dispose()
    }
}

function Get-VdfField([string]$Vdf, [string]$Name) {
    $pattern = '(?m)^\s*"' + [regex]::Escape($Name) + '"\s*"([^"\r\n]*)"'
    $match = [regex]::Match($Vdf, $pattern)
    if ($match.Success) { return $match.Groups[1].Value }
    return ''
}

function Get-SteamRoots {
    $registry = @(
        @{ Path = 'HKCU:\Software\Valve\Steam'; Property = 'SteamPath' }
        @{ Path = 'HKLM:\Software\WOW6432Node\Valve\Steam'; Property = 'InstallPath' }
        @{ Path = 'HKLM:\Software\Valve\Steam'; Property = 'InstallPath' }
    )
    foreach ($entry in $registry) {
        $value = Get-ItemPropertyValue -LiteralPath $entry.Path -Name $entry.Property -ErrorAction SilentlyContinue
        if ($value) { $value }
    }
    $programFiles = [Environment]::GetFolderPath('ProgramFilesX86')
    if ($programFiles) { Join-Path $programFiles 'Steam' }
}

function Find-SteamGames([string[]]$SteamRoots) {
    $libraries = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($root in $SteamRoots) {
        if (!(Test-Path -LiteralPath $root -PathType Container)) { continue }
        $resolved = (Resolve-Path -LiteralPath $root).ProviderPath
        [void]$libraries.Add($resolved)
        $vdf = Join-Path $resolved 'steamapps/libraryfolders.vdf'
        if (!(Test-Path -LiteralPath $vdf -PathType Leaf)) { continue }
        $body = [IO.File]::ReadAllText($vdf, [Text.Encoding]::UTF8)
        # The numeric form is used by older Steam clients.
        foreach ($match in [regex]::Matches($body, '(?m)^\s*"(?:path|\d+)"\s+"([^"\r\n]+)"')) {
            $path = $match.Groups[1].Value.Replace('\\', '\')
            if ([IO.Path]::IsPathRooted($path) -and (Test-Path -LiteralPath $path -PathType Container)) {
                [void]$libraries.Add((Resolve-Path -LiteralPath $path).ProviderPath)
            }
        }
    }
    foreach ($library in $libraries) {
        $appManifest = Join-Path $library 'steamapps/appmanifest_3372980.acf'
        if (!(Test-Path -LiteralPath $appManifest -PathType Leaf)) { continue }
        $body = [IO.File]::ReadAllText($appManifest, [Text.Encoding]::UTF8)
        if ((Get-VdfField $body 'appid') -ne '3372980') { continue }
        $leaf = Get-VdfField $body 'installdir'
        if (!$leaf -or $leaf -in '.', '..' -or $leaf.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) { continue }
        $dir = Join-Path (Join-Path $library 'steamapps/common') $leaf
        $build = Get-VdfField $body 'buildid'
        $game = Get-GameLocation $dir $build
        if ($null -ne $game -and $seen.Add($game.Directory)) { $game }
    }
}

function Get-GameLocation([string]$Directory, [string]$SteamBuild) {
    if (!(Test-Path -LiteralPath $Directory -PathType Container)) { return $null }
    $resolved = (Resolve-Path -LiteralPath $Directory).ProviderPath
    $pck = Join-Path $resolved 'Tower Wizard.pck'
    $runtime = Join-Path $resolved 'Tower Wizard.exe'
    if (!(Test-Path -LiteralPath $pck -PathType Leaf) -or !(Test-Path -LiteralPath $runtime -PathType Leaf)) {
        return $null
    }
    if (!$SteamBuild) {
        $steamApps = Split-Path -Parent (Split-Path -Parent $resolved)
        $appManifest = Join-Path $steamApps 'appmanifest_3372980.acf'
        if (Test-Path -LiteralPath $appManifest -PathType Leaf) {
            $SteamBuild = Get-VdfField ([IO.File]::ReadAllText($appManifest, [Text.Encoding]::UTF8)) 'buildid'
        }
    }
    [pscustomobject]@{ Directory = $resolved; Pck = $pck; Runtime = $runtime; SteamBuild = $SteamBuild }
}

function Read-Choice([string]$Prompt) {
    if ([Console]::IsInputRedirected) {
        return [Console]::ReadLine()
    }
    return Read-Host $Prompt
}

function Select-Game {
    if ($env:TWKO_EXPLICIT_GAME) {
        $game = Get-GameLocation $env:TWKO_EXPLICIT_GAME ''
        if ($null -eq $game) {
            throw "지정한 폴더에 Tower Wizard.exe와 Tower Wizard.pck가 없습니다. $($env:TWKO_EXPLICIT_GAME)"
        }
        return $game
    }
    $games = @(Find-SteamGames @(Get-SteamRoots))
    if ($games.Count -eq 0) {
        throw 'Steam에서 Tower Wizard 설치 폴더를 찾지 못했습니다. Steam의 설치 파일 찾아보기에서 폴더를 확인해 주세요.'
    }
    if ($games.Count -eq 1) { return $games[0] }
    Write-Host 'Tower Wizard가 설치된 폴더가 여러 곳입니다.'
    for ($i = 0; $i -lt $games.Count; $i++) {
        Write-Host ('  {0}. {1}' -f ($i + 1), $games[$i].Directory)
    }
    $selected = 0
    $choice = Read-Choice '설치 폴더 번호'
    if (![int]::TryParse($choice, [ref]$selected) -or $selected -lt 1 -or $selected -gt $games.Count) {
        throw '올바른 설치 폴더 번호를 선택해 주세요.'
    }
    $games[$selected - 1]
}

function Get-PckState($Game) {
    $hash = Get-Sha256 $Game.Pck
    $receipt = $Game.Pck + '.ko-receipt.' + $hash
    $baseHash = $hash
    $status = 'candidate'
    if ([IO.File]::Exists($receipt)) {
        if ([IO.FileInfo]::new($receipt).Length -ne 64) { throw '패치 적용 기록이 손상되었습니다.' }
        $baseHash = [IO.File]::ReadAllText($receipt)
        if ($baseHash -cnotmatch '\A[0-9a-f]{64}\z' -or $baseHash -eq $hash) { throw '패치 적용 기록이 손상되었습니다.' }
        $status = 'patched'
    } elseif ($hash -in $script:Catalog.legacy.patched_sha256) {
        $baseHash = $script:Catalog.legacy.base_sha256
        $status = 'legacy'
    } elseif ($hash -eq $script:Catalog.legacy.base_sha256) {
        $status = 'stock'
    }
    return [pscustomobject]@{
        Status = $status
        CurrentHash = $hash
        BaseHash = $baseHash
        Backup = $Game.Pck + '.ko-original.' + $baseHash.Substring(0, 12)
    }
}

function Assert-GameClosed($Game) {
    $active = @(Get-Process -Name 'Tower Wizard' -ErrorAction SilentlyContinue |
        Where-Object { !$_.Path -or $_.Path -eq $Game.Runtime })
    if ($active.Count -gt 0) { throw 'Tower Wizard를 종료한 뒤 다시 실행해 주세요.' }
}

function Assert-CurrentPck($Game, $State) {
    Assert-GameClosed $Game
    if ((Get-Sha256 $Game.Pck) -ne $State.CurrentHash) {
        throw '진행 중 Steam 설치 파일이 변경되었습니다. 메뉴에서 다시 확인해 주세요.'
    }
}

function New-TempPath([string]$Directory, [string]$Suffix) {
    Join-Path $Directory ('.twko-' + [Guid]::NewGuid().ToString('N') + $Suffix)
}

function Get-VerifiedArchive($Build) {
    $local = [Environment]::GetFolderPath('LocalApplicationData')
    $cache = Join-Path $local 'ko-patch-tower-wizard/cache'
    [void][IO.Directory]::CreateDirectory($cache)
    $cached = Join-Path $cache ($Build.archive_sha256 + '.zip')
    if ((Test-Path -LiteralPath $cached -PathType Leaf) -and (Get-Sha256 $cached) -eq $Build.archive_sha256) {
        return $cached
    }
    $temporary = New-TempPath $cache '.download'
    $url = $script:Catalog.release_base + $Build.archive
    try {
        Write-Host 'GitHub 릴리스에서 번역 데이터와 갈무리 글꼴을 받는 중입니다.'
        try {
            $curl = Join-Path $env:SystemRoot 'System32/curl.exe'
            if ([IO.File]::Exists($curl)) {
                & $curl --fail --location --silent --show-error --max-redirs 5 --max-time 45 --output $temporary $url
                if ($LASTEXITCODE -ne 0) { throw "curl 종료 코드 $LASTEXITCODE" }
            } else {
                [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
                Invoke-WebRequest -Uri $url -UseBasicParsing -MaximumRedirection 5 -TimeoutSec 45 -OutFile $temporary
            }
        } catch {
            throw "GitHub 릴리스 파일을 받지 못했습니다. $url`n$($_.Exception.Message)"
        }
        if ((Get-Sha256 $temporary) -ne $Build.archive_sha256) {
            throw '다운로드한 ZIP의 SHA-256이 다릅니다. 공식 릴리스의 파일인지 확인해 주세요.'
        }
        try {
            if ([IO.File]::Exists($cached)) {
                [IO.File]::Replace($temporary, $cached, [NullString]::Value)
            } else {
                [IO.File]::Move($temporary, $cached)
            }
        } catch {
            if (!(Test-Path -LiteralPath $cached -PathType Leaf) -or (Get-Sha256 $cached) -ne $Build.archive_sha256) { throw }
        }
        return $cached
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Read-ZipEntry($Zip, [string]$Name, [long]$Limit) {
    $entry = $Zip.GetEntry($Name)
    if ($null -eq $entry -or $entry.Length -le 0 -or $entry.Length -gt $Limit) {
        throw "배포 ZIP의 필수 데이터가 없거나 비정상입니다. $Name"
    }
    $source = $entry.Open()
    $memory = [IO.MemoryStream]::new()
    try {
        $source.CopyTo($memory)
        if ($memory.Length -ne $entry.Length) { throw "배포 ZIP 항목이 손상되었습니다. $Name" }
        return ,$memory.ToArray()
    } finally {
        $memory.Dispose()
        $source.Dispose()
    }
}

function Get-Bundle([string]$Path, $Package) {
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $stream = [IO.File]::OpenRead($Path)
    try {
        if ((Get-Sha256 $Path) -ne $Package.archive_sha256) { throw '검증한 ZIP 파일이 변경되었습니다.' }
        $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Read, $true)
        try {
            $recipe = Read-ZipEntry $zip 'recipe.json' 4194304
            [void](Read-ZipEntry $zip 'Galmuri-OFL-1.1.txt' 65536)
            [void](Read-ZipEntry $zip 'KeyDot-MIT.txt' 65536)
            return [pscustomobject]@{
                Recipe = [Text.Encoding]::UTF8.GetString($recipe)
                Font9 = Read-ZipEntry $zip 'Galmuri9.res' 4194304
                Font11 = Read-ZipEntry $zip 'Galmuri11.res' 4194304
                Extra = Read-ZipEntry $zip 'extra.ko.translation' 131072
                KeyDot = Read-ZipEntry $zip 'keydot.exe' 1048576
            }
        } finally {
            $zip.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

function Get-GameKey($Game, $Bundle) {
    $temporary = New-TempPath ([IO.Path]::GetTempPath()) '.exe'
    try {
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $stream.Write($Bundle.KeyDot, 0, $Bundle.KeyDot.Length)
        } finally {
            $stream.Dispose()
        }
        $lines = & $temporary $Game.Runtime
        if ($LASTEXITCODE -ne 0) { throw 'KeyDot에서 게임 실행 파일의 PCK 키를 읽지 못했습니다.' }
        $match = [regex]::Match(($lines -join ' '), '\b[a-fA-F0-9]{64}\b')
        if (!$match.Success) { throw '게임 실행 파일의 PCK 키를 찾지 못했습니다.' }
        return $match.Value
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Protect-Original($Game, $State) {
    if (![IO.File]::Exists($State.Backup) -and ($State.Status -in 'stock', 'candidate')) {
        $temporary = New-TempPath $Game.Directory '.backup'
        try {
            [IO.File]::Copy($Game.Pck, $temporary)
            if ((Get-Sha256 $temporary) -ne $State.BaseHash) { throw '백업한 원본 PCK가 예상과 다릅니다.' }
            [IO.File]::Move($temporary, $State.Backup)
        } finally {
            if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
        }
    }
    if (![IO.File]::Exists($State.Backup)) {
        throw "원본 백업을 찾을 수 없습니다. $($State.Backup)"
    }
    if ((Get-Sha256 $State.Backup) -ne $State.BaseHash) {
        throw "원본 백업이 손상되었거나 다른 빌드입니다. $($State.Backup)"
    }
}

function Register-Patch($Game, $State, [string]$PatchedHash) {
    $receipt = $Game.Pck + '.ko-receipt.' + $PatchedHash
    if ([IO.File]::Exists($receipt)) {
        if ([IO.File]::ReadAllText($receipt) -cne $State.BaseHash) { throw '동일한 패치의 적용 기록이 현재 백업과 다릅니다.' }
        return
    }
    $temporary = New-TempPath $Game.Directory '.receipt'
    try {
        [IO.File]::WriteAllText($temporary, $State.BaseHash, [Text.Encoding]::ASCII)
        [IO.File]::Move($temporary, $receipt)
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Invoke-PatchChange($Game, [bool]$Restore) {
    Assert-GameClosed $Game
    $lock = [IO.FileStream]::new($Game.Pck + '.ko-lock', [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::None, 4096, [IO.FileOptions]::DeleteOnClose)
    $temporary = New-TempPath $Game.Directory '.pck.tmp'
    try {
        $state = Get-PckState $Game
        Write-Host "설치 경로 $($Game.Directory)"
        if ($Game.SteamBuild) { Write-Host "설치된 Steam 빌드 $($Game.SteamBuild)" }
        if ($Restore) {
            if ($state.Status -in 'stock', 'candidate') {
                Write-Host '현재 PCK에 적용 기록이 없어 파일을 그대로 두었습니다.'
                return
            }
            Protect-Original $Game $state
            [IO.File]::Copy($state.Backup, $temporary)
            if ((Get-Sha256 $temporary) -ne $state.BaseHash) { throw '복구용 원본 사본이 손상되었습니다.' }
        } else {
            $archive = Get-VerifiedArchive $script:Catalog.package
            $bundle = Get-Bundle $archive $script:Catalog.package
            Assert-CurrentPck $Game $state
            $original = $Game.Pck
            if ($state.Status -in 'patched', 'legacy') {
                Protect-Original $Game $state
                $original = $state.Backup
            }
            try {
                $key = Get-GameKey $Game $bundle
                if (!('TowerWizardKorean.Installer' -as [type])) {
                    Add-Type -TypeDefinition $script:InstallerSource -ReferencedAssemblies 'System.dll','System.Core.dll','System.Web.Extensions.dll'
                }
                $english = [TowerWizardKorean.Installer]::Build($original, $temporary, $key, $bundle.Recipe,
                    $bundle.Font9, $bundle.Font11, $bundle.Extra)
            } catch {
                $details = $_.Exception.GetBaseException().Message
                throw ("이 설치본에서 번역 리소스의 호환성을 확인하지 못했습니다. 게임 파일은 그대로입니다." +
                    [Environment]::NewLine + "현재 PCK SHA-256 $($state.CurrentHash)" + [Environment]::NewLine + $details)
            }
            Assert-CurrentPck $Game $state
            Protect-Original $Game $state
            Register-Patch $Game $state (Get-Sha256 $temporary)
        }
        Assert-CurrentPck $Game $state
        [IO.File]::Replace($temporary, $Game.Pck, [NullString]::Value)
        if ($Restore) {
            Write-Host '원본 PCK를 복구했습니다.' -ForegroundColor Green
        } else {
            Write-Host '한국어 패치를 적용했습니다. Steam에서 게임을 실행하면 됩니다.' -ForegroundColor Green
            if ($english -gt 0) {
                Write-Host "원문이 달라졌거나 번역을 확인할 수 없는 ${english}개 항목은 영어로 표시합니다."
            }
        }
        Write-Host "원본 백업 $($state.Backup)"
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
        $lock.Dispose()
    }
}

function Show-Compatibility {
    Write-Host 'Steam 빌드 번호와 관계없이 설치 과정에서 번역 리소스의 호환성을 확인합니다.'
    Write-Host "실행 검증을 마친 Steam 빌드 $($script:Catalog.legacy.steam_build)"
    $games = if ($env:TWKO_EXPLICIT_GAME) { Get-GameLocation $env:TWKO_EXPLICIT_GAME '' } else { Find-SteamGames @(Get-SteamRoots) }
    foreach ($game in $games) {
        Write-Host "감지된 설치 경로 $($game.Directory)"
        if ($game.SteamBuild) { Write-Host "설치된 Steam 빌드 $($game.SteamBuild)" }
        try {
            $state = Get-PckState $game
            $labels = @{ stock = '검증된 원본'; patched = '한국어 적용됨'; legacy = '이전 한국어 패치 적용됨'; candidate = '한국어 적용 시 호환성을 확인합니다.' }
            Write-Host "  $($labels[$state.Status])"
            Write-Host "  현재 PCK SHA-256 $($state.CurrentHash)"
        } catch {
            Write-Host $_.Exception.Message
        }
    }
}

function Invoke-Menu {
    $exitCode = 0
    while ($true) {
        Write-Host "`nTower Wizard 비공식 한국어 패치 $($script:Catalog.tag)"
        Write-Host '1. 한국어 적용 / 재설치'
        Write-Host '2. 원본 복구'
        Write-Host '3. 설치 상태 확인'
        Write-Host '0. 종료'
        $choice = Read-Choice '번호 선택'
        if ($null -eq $choice -or $choice.Trim() -eq '0') { return $exitCode }
        switch ($choice.Trim()) {
            '3' { Show-Compatibility }
            { $_ -in '1', '2' } {
                try {
                    $game = Select-Game
                    Invoke-PatchChange $game ($_ -eq '2')
                    $exitCode = 0
                } catch {
                    Write-Host ('오류: ' + $_.Exception.Message) -ForegroundColor Red
                    $exitCode = 1
                }
            }
            default { Write-Host '0~3 중 하나를 선택해 주세요.' }
        }
    }
}

exit (Invoke-Menu)
