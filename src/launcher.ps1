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

function Get-BytesSha256([byte[]]$Bytes) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $algorithm.Dispose()
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
    foreach ($build in $script:Catalog.builds) {
        $status = ''
        if ($hash -eq $build.base_sha256) { $status = 'stock' }
        elseif ($hash -eq $build.patched_sha256) { $status = 'patched' }
        elseif ($hash -in $build.legacy_sha256) { $status = 'legacy' }
        if ($status) {
            return [pscustomobject]@{
                Status = $status
                CurrentHash = $hash
                Build = $build
                Backup = $Game.Pck + '.ko-original.' + $build.base_sha256.Substring(0, 12)
            }
        }
    }
    $number = if ($Game.SteamBuild) { $Game.SteamBuild } else { '확인할 수 없음' }
    throw ("미지원 설치본입니다. PCK가 현재 지원되는 원본 또는 패치와 일치하지 않습니다." +
           "`n설치된 Steam 빌드 $number" +
           "`n현재 PCK SHA-256 $hash" +
           "`n메뉴 3에서 지원 빌드를 확인할 수 있습니다.")
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

function Get-Bundle([string]$Path, $Build) {
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $stream = [IO.File]::OpenRead($Path)
    try {
        if ((Get-Sha256 $Path) -ne $Build.archive_sha256) { throw '검증한 ZIP 파일이 변경되었습니다.' }
        $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Read, $true)
        try {
            $raw = Read-ZipEntry $zip 'manifest.json' 1048576
            $manifest = [Text.Encoding]::UTF8.GetString($raw) | ConvertFrom-Json
            if ($manifest.schema -ne 2 -or $manifest.steam_build -ne $Build.steam_build -or
                $manifest.base_sha256 -ne $Build.base_sha256 -or $manifest.patched_sha256 -ne $Build.patched_sha256) {
                throw '배포 ZIP이 선택한 게임 빌드용이 아닙니다.'
            }
            $header = Read-ZipEntry $zip 'header.bin' 5242880
            $literal = Read-ZipEntry $zip 'literal.bin' 33554432
            [void](Read-ZipEntry $zip 'Galmuri-OFL-1.1.txt' 65536)
            if ((Get-BytesSha256 $header) -ne $manifest.header_sha256 -or (Get-BytesSha256 $literal) -ne $manifest.literal_sha256) {
                throw '번역·글꼴 또는 PCK 헤더 데이터의 SHA-256이 다릅니다.'
            }
            return [pscustomobject]@{ Manifest = $manifest; Header = $header; Literal = $literal }
        } finally {
            $zip.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

function Copy-BaseRange($Base, $Target, [long]$Offset, [long]$Length, [byte[]]$Buffer) {
    if ($Offset -lt 0 -or $Length -lt 0 -or $Offset -gt $Base.Length - $Length) {
        throw '패치 데이터의 원본 복사 범위가 올바르지 않습니다.'
    }
    $Base.Position = $Offset
    while ($Length -gt 0) {
        $read = $Base.Read($Buffer, 0, [int][Math]::Min($Length, $Buffer.Length))
        if ($read -eq 0) { throw '원본 PCK를 읽는 중 파일이 끝났습니다.' }
        $Target.Write($Buffer, 0, $read)
        $Length -= $read
    }
}

function Write-PatchedFile([string]$Original, [string]$Path, $Bundle, [string]$ExpectedSha) {
    $base = [IO.File]::OpenRead($Original)
    try {
        $m = $Bundle.Manifest
        if ($base.Length -ne $m.base_length -or $m.stock_tail_offset -lt 140 -or $m.stock_tail_offset -ge $base.Length) {
            throw '원본 PCK 길이 또는 데이터 시작 위치가 일치하지 않습니다.'
        }
        $output = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $buffer = [byte[]]::new(1048576)
            $output.Write($Bundle.Header, 0, $Bundle.Header.Length)
            Copy-BaseRange $base $output $m.stock_tail_offset ($base.Length - $m.stock_tail_offset) $buffer
            foreach ($op in $m.operations) {
                $offset = [long]$op.offset
                $length = [long]$op.length
                if ($op.source -eq 'base') {
                    Copy-BaseRange $base $output $offset $length $buffer
                } elseif ($op.source -eq 'literal' -and $offset -ge 0 -and $length -gt 0 -and $offset -le $Bundle.Literal.Length - $length) {
                    $output.Write($Bundle.Literal, [int]$offset, [int]$length)
                } else {
                    throw '패치 데이터의 추가 범위가 올바르지 않습니다.'
                }
            }
            $output.Flush($true)
        } finally {
            $output.Dispose()
        }
    } finally {
        $base.Dispose()
    }
    if ((Get-Sha256 $Path) -ne $ExpectedSha) { throw '조립한 PCK의 SHA-256이 예상과 다릅니다.' }
}

function Protect-Original($Game, $State) {
    if (![IO.File]::Exists($State.Backup) -and $State.Status -eq 'stock') {
        $temporary = New-TempPath $Game.Directory '.backup'
        try {
            [IO.File]::Copy($Game.Pck, $temporary)
            if ((Get-Sha256 $temporary) -ne $State.Build.base_sha256) { throw '백업한 원본 PCK가 예상과 다릅니다.' }
            [IO.File]::Move($temporary, $State.Backup)
        } finally {
            if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
        }
    }
    if (![IO.File]::Exists($State.Backup)) {
        throw "원본 백업을 찾을 수 없습니다. $($State.Backup)"
    }
    if ((Get-Sha256 $State.Backup) -ne $State.Build.base_sha256) {
        throw "원본 백업이 손상되었거나 다른 빌드입니다. $($State.Backup)"
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
        Write-Host "지원 Steam 빌드 $($state.Build.steam_build) · 게임 $($state.Build.game_version)"
        if ($Restore) {
            if ($state.Status -eq 'stock') {
                Write-Host '이미 원본 상태입니다.' -ForegroundColor Green
                return
            }
            Protect-Original $Game $state
            [IO.File]::Copy($state.Backup, $temporary)
            if ((Get-Sha256 $temporary) -ne $state.Build.base_sha256) { throw '복구용 원본 사본이 손상되었습니다.' }
        } else {
            $archive = Get-VerifiedArchive $state.Build
            $bundle = Get-Bundle $archive $state.Build
            Assert-CurrentPck $Game $state
            Protect-Original $Game $state
            Write-PatchedFile $state.Backup $temporary $bundle $state.Build.patched_sha256
        }
        Assert-CurrentPck $Game $state
        [IO.File]::Replace($temporary, $Game.Pck, [NullString]::Value)
        if ($Restore) {
            Write-Host '원본 PCK를 복구했습니다.' -ForegroundColor Green
        } else {
            Write-Host '한국어 패치를 적용했습니다. Steam에서 게임을 실행하면 됩니다.' -ForegroundColor Green
        }
        Write-Host "원본 백업 $($state.Backup)"
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
        $lock.Dispose()
    }
}

function Show-SupportedBuilds {
    Write-Host "`nCMD 릴리스 $($script:Catalog.tag)"
    foreach ($build in $script:Catalog.builds) {
        Write-Host "Steam 빌드 $($build.steam_build) · 게임 $($build.game_version)"
        Write-Host "  원본 PCK SHA-256 $($build.base_sha256)"
    }
    $games = if ($env:TWKO_EXPLICIT_GAME) { Get-GameLocation $env:TWKO_EXPLICIT_GAME '' } else { Find-SteamGames @(Get-SteamRoots) }
    foreach ($game in $games) {
        Write-Host "감지된 설치 경로 $($game.Directory)"
        try {
            $state = Get-PckState $game
            $labels = @{ stock = '지원되는 원본'; patched = '한국어 적용됨'; legacy = '이전 한국어 패치 적용됨' }
            Write-Host "  $($labels[$state.Status])"
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
        Write-Host '3. 지원 빌드 확인'
        Write-Host '0. 종료'
        $choice = Read-Choice '번호 선택'
        if ($null -eq $choice -or $choice.Trim() -eq '0') { return $exitCode }
        switch ($choice.Trim()) {
            '3' { Show-SupportedBuilds }
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
