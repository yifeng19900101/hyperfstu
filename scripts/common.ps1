# 公共函数：读取配置、SSH/SCP 封装、文件清单、同步实现
$ErrorActionPreference = 'Stop'

$script:ProjectRoot = Split-Path -Parent $PSScriptRoot
$script:LocalAppRoot = Join-Path $script:ProjectRoot 'MineAdmin'
$script:LocalFrontRoot = Join-Path $script:ProjectRoot 'MineAdmin-Vue'
$script:DeployDir = Join-Path $script:ProjectRoot 'deploy'

$configFile = Join-Path $PSScriptRoot 'deploy.config.ps1'
if (-not (Test-Path -LiteralPath $configFile)) {
    throw "缺少配置文件：$configFile`n请先执行：Copy-Item scripts\deploy.config.example.ps1 scripts\deploy.config.ps1，然后填写服务器信息。"
}
. $configFile

if (-not $RemoteHost -or -not $RemoteUser -or -not $RemotePath) {
    throw 'deploy.config.ps1 中 RemoteHost / RemoteUser / RemotePath 不能为空。'
}
if ($RemotePath -notmatch '^/(opt|srv|var/www|home|root|www)/[A-Za-z0-9._/-]+$') {
    throw "RemotePath 看起来不安全：$RemotePath。同步会删除远端多余文件，必须是 /opt/xxx、/www/wwwroot/xxx 这样的具体目录。"
}
$RemotePath = $RemotePath.TrimEnd('/')
if (-not $AppContainer) { $AppContainer = 'mineadmin-app' }

# 分支策略：全程只用 main，不允许切分支。
# 这里写死而不是放进 deploy.config.ps1，避免本地/服务器用不同分支导致「推了但没生效」。
$Branch = 'main'

# 原生部署用的 PHP（宝塔安装的版本）；docker 模式下不会用到
if (-not $PhpBin) { $PhpBin = '/www/server/php/83/bin/php' }

# 单仓库结构：服务器上 MineAdmin / MineAdmin-Vue / deploy 都在 $RemotePath 下
$script:RemoteAppRoot = "$RemotePath/MineAdmin"
$script:RemoteFrontRoot = "$RemotePath/MineAdmin-Vue"

$script:Target = "$RemoteUser@$RemoteHost"
$script:SshArgs = @('-p', "$RemotePort", '-o', 'ConnectTimeout=15', '-o', 'ServerAliveInterval=60')
$script:ScpArgs = @('-P', "$RemotePort", '-o', 'ConnectTimeout=15')
if ($IdentityFile) {
    $script:SshArgs += @('-i', $IdentityFile)
    $script:ScpArgs += @('-i', $IdentityFile)
}

$script:ComposeFile = "$RemotePath/deploy/docker-compose.yml"
$script:ComposeCmd = "docker compose -f '$($script:ComposeFile)'"

# 需要同步到服务器的目录/文件（相对于 MineAdmin/）
$script:SyncDirs = @(
    'app', 'config', 'databases', 'plugin', 'bin', 'tests',
    'storage/languages', 'storage/swagger', 'lab'
)
$script:SyncFiles = @(
    'composer.json', 'watch', 'kill',
    'phpunit.xml.dist', 'phpstan.neon.dist', '.env.example'
)
# 这些目录/文件永远不同步，也不会被删除
$script:SyncExcludes = @(
    'runtime', 'vendor', 'node_modules', '.git', '.idea', '.vscode',
    'web', 'public', 'storage/uploads'
)

function Write-Step {
    param([string]$Message)
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Info {
    param([string]$Message)
    Write-Host "    $Message" -ForegroundColor DarkGray
}

function Write-Ok {
    param([string]$Message)
    Write-Host "    $Message" -ForegroundColor Green
}

function Invoke-Ssh {
    param(
        [Parameter(Mandatory)][string]$Command,
        [switch]$Quiet,
        [switch]$AllowFail
    )
    $output = & ssh @script:SshArgs $script:Target $Command 2>&1
    $code = $LASTEXITCODE
    if ($code -ne 0 -and -not $AllowFail) {
        throw "SSH 执行失败（exit $code）`n命令：$Command`n输出：`n$($output | Out-String)"
    }
    if (-not $Quiet) {
        $output | ForEach-Object { Write-Host $_ }
    }
    return ($output | Out-String)
}

# 用于日志、tinker 等需要实时输出的场景
function Invoke-SshStream {
    param([Parameter(Mandatory)][string]$Command)
    & ssh @script:SshArgs $script:Target $Command
    if ($LASTEXITCODE -ne 0) {
        throw "远程命令失败（exit $LASTEXITCODE）：$Command"
    }
}

function Send-File {
    param(
        [Parameter(Mandatory)][string]$LocalPath,
        [Parameter(Mandatory)][string]$RemoteFilePath
    )
    & scp @script:ScpArgs $LocalPath "$($script:Target):$RemoteFilePath" 2>&1 | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) {
        throw "上传失败：$LocalPath -> $RemoteFilePath"
    }
}

function Test-SyncExcluded {
    param([string]$RelativePath)
    foreach ($pattern in $script:SyncExcludes) {
        if ($RelativePath -eq $pattern -or $RelativePath.StartsWith($pattern + '/')) {
            return $true
        }
    }
    return $false
}

function Get-SyncItems {
    param([switch]$IncludeEnv)
    $items = New-Object System.Collections.Generic.List[string]
    foreach ($dir in $script:SyncDirs) {
        $full = Join-Path $script:LocalAppRoot $dir
        if (-not (Test-Path -LiteralPath $full)) { continue }
        Get-ChildItem -LiteralPath $full -Recurse -File -Force | ForEach-Object {
            $rel = $_.FullName.Substring($script:LocalAppRoot.Length + 1).Replace('\', '/')
            if (-not (Test-SyncExcluded $rel)) { $items.Add($rel) }
        }
    }
    foreach ($file in $script:SyncFiles) {
        if (Test-Path -LiteralPath (Join-Path $script:LocalAppRoot $file)) { $items.Add($file) }
    }
    if ($IncludeEnv -and (Test-Path -LiteralPath (Join-Path $script:LocalAppRoot '.env'))) {
        $items.Add('.env')
    }
    return $items.ToArray()
}

function Sync-Project {
    param([switch]$IncludeEnv, [switch]$Quiet)

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $items = @(Get-SyncItems -IncludeEnv:$IncludeEnv)
    if ($items.Count -eq 0) { return }

    $listFile = Join-Path $env:TEMP 'mineadmin-sync-list.txt'
    $tarFile = Join-Path $env:TEMP 'mineadmin-sync.tar.gz'
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($listFile, ($items -join "`n"), $utf8)
    if (Test-Path -LiteralPath $tarFile) { Remove-Item -LiteralPath $tarFile -Force }

    & tar -czf $tarFile -C $script:LocalAppRoot -T $listFile 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'tar 打包失败（检查路径中是否有特殊字符）。'
    }

    $remoteTar = "/tmp/mineadmin-sync-$PID.tar.gz"
    Send-File $tarFile $remoteTar
    Invoke-Ssh "mkdir -p '$($script:RemoteAppRoot)' && tar -xzf '$remoteTar' -C '$($script:RemoteAppRoot)' && rm -f '$remoteTar'" -Quiet

    # 删除远端多余文件，保证和本地一致
    $remoteList = Invoke-Ssh "cd '$($script:RemoteAppRoot)' && find $($script:SyncDirs -join ' ') -type f 2>/dev/null" -Quiet -AllowFail
    $localSet = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($item in $items) { [void]$localSet.Add($item) }

    $toDelete = @()
    foreach ($line in ($remoteList -split "`r?`n")) {
        $rel = $line.Trim()
        if ($rel -eq '' -or $localSet.Contains($rel)) { continue }
        if (Test-SyncExcluded $rel) { continue }
        # Swagger 自动生成的 json 不删
        if ($rel -like 'storage/swagger/*.json') { continue }
        $toDelete += $rel
    }

    if ($toDelete.Count -gt 0) {
        for ($i = 0; $i -lt $toDelete.Count; $i += 40) {
            $end = [Math]::Min($i + 39, $toDelete.Count - 1)
            $batch = $toDelete[$i..$end]
            $quoted = ($batch | ForEach-Object { "'" + ($_ -replace "'", "'\''") + "'" }) -join ' '
            Invoke-Ssh "cd '$($script:RemoteAppRoot)' && rm -f -- $quoted" -Quiet
        }
    }

    Remove-Item -LiteralPath $tarFile, $listFile -Force -ErrorAction SilentlyContinue
    if (-not $Quiet) {
        Write-Ok ("同步完成：{0} 个文件，删除 {1} 个，耗时 {2:N1}s" -f $items.Count, $toDelete.Count, $sw.Elapsed.TotalSeconds)
    }
}

function Get-SyncSignature {
    $items = @(Get-SyncItems)
    $sb = New-Object System.Text.StringBuilder
    foreach ($rel in ($items | Sort-Object)) {
        $file = Get-Item -LiteralPath (Join-Path $script:LocalAppRoot $rel) -ErrorAction SilentlyContinue
        if ($null -ne $file) {
            [void]$sb.Append($rel).Append('|').Append($file.LastWriteTimeUtc.Ticks).Append('|').Append($file.Length).Append("`n")
        }
    }
    return $sb.ToString()
}

function Assert-RemoteReady {
    Write-Step '检查 SSH 连接'
    try {
        Invoke-Ssh 'echo connected' -Quiet | Out-Null
    }
    catch {
        throw "无法连接服务器 $script:Target。`n请确认：1) 服务器 IP/端口正确 2) 已配置 SSH 公钥（推荐） 3) 防火墙放行 SSH。`n原始错误：$_"
    }
    # 只创建项目根目录，不能预建 deploy/，否则首次 git clone 会认为目录非空
    Invoke-Ssh "mkdir -p '$RemotePath'" -Quiet | Out-Null
    Write-Ok "SSH 正常，远端目录：$RemotePath"
}

function Get-DeployEnvValue {
    param([string]$Key, [string]$Default = '')
    $file = Join-Path $script:DeployDir '.env'
    if (Test-Path -LiteralPath $file) {
        $match = Select-String -Path $file -Pattern "^$([regex]::Escape($Key))=(.*)$"
        if ($match) { return $match.Matches[0].Groups[1].Value.Trim() }
    }
    return $Default
}

function Get-PublicUrl {
    # 宝塔模式下入口是面板 Nginx，默认 80；docker 模式下看 WEB_PORT
    $useDockerNginx = Get-DeployEnvValue 'USE_DOCKER_NGINX' '1'
    $port = if ($useDockerNginx -eq '1') { Get-DeployEnvValue 'WEB_PORT' '80' } else { '80' }
    if ($port -eq '80') { return "http://$($RemoteHost)" }
    return "http://$($RemoteHost):$port"
}

function Test-UseDockerNginx {
    return ((Get-DeployEnvValue 'USE_DOCKER_NGINX' '1') -eq '1')
}

# 只允许在 main 上工作：发现切了分支就中止，避免提交/推送跑到别的分支上
function Assert-OnMainBranch {
    param([string]$RepoPath = $script:ProjectRoot)
    $current = (& git -C $RepoPath rev-parse --abbrev-ref HEAD 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $current) {
        throw "无法确定 $RepoPath 的当前分支（是不是还没 git init / 不是仓库？）"
    }
    if ($current -ne 'main') {
        throw @"
当前分支是「$current」，本项目只用 main。
先回到 main 再执行：
  git -C "$RepoPath" checkout main
如果是刚才误建的分支，删掉它（上面的修改会跟着过来）：
  git -C "$RepoPath" branch -D $current
"@
    }
    return $current
}
