[CmdletBinding()]
param(
    # 数据库：宝塔面板 → 数据库 → 添加数据库 里创建好的信息
    [string]$DbHost = '127.0.0.1',
    [int]$DbPort = 3306,
    [string]$DbName = '',
    [string]$DbUser = '',
    [string]$DbPassword = '',

    # Redis：宝塔面板 → 软件商店 → Redis 里配置的密码（没设就留空）
    [string]$RedisHost = '127.0.0.1',
    [int]$RedisPort = 6379,
    [string]$RedisAuth = '',

    # 对外访问地址，例如 example.com / https://example.com
    # 留空则用 http://服务器IP
    [string]$Domain = '',

    # 宝塔安装的 PHP 可执行文件
    [string]$PhpBin = '',

    # 已有 .env 时是否完全重建
    [switch]$Force,
    [switch]$SkipFrontend,
    # 只安装不启动（之后用宝塔进程守护管理器托管）
    [switch]$SkipStart
)

. "$PSScriptRoot\common.ps1"

if (-not $PhpBin) { $PhpBin = $script:PhpBin }
if (-not $PhpBin) { $PhpBin = '/www/server/php/83/bin/php' }

function New-RandomSecret {
    param([int]$Bytes = 64)
    $buffer = New-Object byte[] $Bytes
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($buffer)
    return [Convert]::ToBase64String($buffer)
}

function Set-EnvValue {
    param([string]$Text, [string]$Key, [string]$Value)
    $pattern = "(?m)^$([regex]::Escape($Key))=.*$"
    if ($Text -match $pattern) {
        $k = $Key; $v = $Value
        return [regex]::Replace($Text, $pattern, { param($m) "$k=$v" })
    }
    if (-not $Text.EndsWith("`n")) { $Text += "`n" }
    return $Text + "$Key=$Value"
}

function Get-EnvValue {
    param([string]$Text, [string]$Key)
    $m = [regex]::Match($Text, "(?m)^$([regex]::Escape($Key))=(.*)$")
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return ''
}

if (-not $RepoUrl -or $RepoUrl -match 'your-name') {
    throw @"
deploy.config.ps1 里还没有填写 RepoUrl（GitHub 仓库地址）。
先按 docs/08-GitHub部署与前端发布.md 配置好仓库地址再运行。
"@
}

Write-Step '1/6 检查服务器与 PHP 环境'
Assert-RemoteReady

$phpVersion = (Invoke-Ssh "'$PhpBin' -r 'echo PHP_VERSION;'" -Quiet -AllowFail).Trim()
if (-not $phpVersion -or $phpVersion -match 'not found|No such file') {
    throw @"
在服务器上找不到 PHP：$PhpBin
1) 宝塔面板 → 软件商店 → 安装 PHP 8.3
2) 命令行确认路径：ls /www/server/php/
3) 用 -PhpBin 指定，例如 -PhpBin /www/server/php/83/bin/php
"@
}
Write-Ok "PHP $phpVersion（$PhpBin）"

$extList = (Invoke-Ssh "'$PhpBin' -m" -Quiet -AllowFail).ToLower()
$missing = @()
foreach ($ext in @('swoole', 'redis', 'pdo_mysql', 'fileinfo', 'json', 'openssl', 'mbstring')) {
    if ($extList -notmatch "(?m)^$ext\s*$") { $missing += $ext }
}
if ($missing.Count -gt 0) {
    throw @"
PHP 缺少扩展：$($missing -join ', ')
在宝塔面板 → 软件商店 → PHP-8.3 → 设置 → 安装扩展 中安装。
swoole 需要 >= 5.0（推荐 5.1 / 6.x），redis 是 phpredis。
装完再跑一次，文档：docs/11-不用Docker启动.md
"@
}
Write-Ok '扩展检查通过（swoole / redis / pdo_mysql / fileinfo / json / openssl / mbstring）'

$swooleShort = (Invoke-Ssh "'$PhpBin' -r 'echo ini_get(\"swoole.use_shortname\");'" -Quiet -AllowFail).Trim()
if ($swooleShort -and $swooleShort -notmatch '^(off|false|0|)$') {
    throw @"
swoole.use_shortname 当前是「$swooleShort」，Hyperf 要求必须为 Off。
在 /www/server/php/83/etc/php.ini 末尾加一行：
  swoole.use_shortname=Off
然后在宝塔 PHP 设置里保存（会重载），再重试。
"@
}

Write-Step '2/6 克隆 / 更新 GitHub 仓库（只用 main 分支）'
$isRepo = (Invoke-Ssh "test -d '$RemotePath/.git' && echo yes || echo no" -Quiet -AllowFail).Trim()
if ($isRepo -eq 'yes') {
    $remoteBranch = (Invoke-Ssh "cd '$RemotePath' && git rev-parse --abbrev-ref HEAD" -Quiet -AllowFail).Trim()
    if ($remoteBranch -ne 'main') {
        throw "服务器仓库当前在分支「$remoteBranch」，本项目只用 main。`n在服务器上执行：cd $RemotePath，然后 git checkout main"
    }
    Invoke-Ssh "cd '$RemotePath' && git fetch --prune origin && git pull --ff-only origin main" -Quiet
    Write-Ok '仓库已更新到最新'
}
else {
    $hasFiles = (Invoke-Ssh "test -d '$RemotePath' && ls -A '$RemotePath' 2>/dev/null | head -n 1" -Quiet -AllowFail).Trim()
    if ($hasFiles) {
        throw "服务器目录 $RemotePath 已有文件，但不是 Git 仓库。请先备份/移走它（例如 mv $RemotePath ${RemotePath}.bak），再重新运行。"
    }
    $parent = $RemotePath.Substring(0, $RemotePath.LastIndexOf('/'))
    Invoke-Ssh "mkdir -p '$parent'" -Quiet | Out-Null
    try {
        Invoke-Ssh "GIT_TERMINAL_PROMPT=0 git clone --single-branch --branch main '$RepoUrl' '$RemotePath'" -Quiet
    }
    catch {
        throw @"
无法 clone 仓库：$RepoUrl
1) 公开仓库：确认地址正确、且仓库里有 main 分支（本项目只用 main）
2) 私有仓库：需要给服务器配置 Deploy Key（docs/08-GitHub部署与前端发布.md）
3) 确认服务器能访问 github.com
原始错误：$_
"@
    }
    Write-Ok '仓库已克隆'
}
Write-Ok "当前提交：$((Invoke-Ssh "cd '$RemotePath' && git log -1 --oneline" -Quiet -AllowFail).Trim())"

Write-Step '3/6 生成 MineAdmin/.env'
$appUrl = if ($Domain) {
    $d = $Domain.TrimEnd('/')
    if ($d -match '^https?://') { $d } else { "http://$d" }
}
else { "http://$RemoteHost" }

$remoteEnv = (Invoke-Ssh "cat '$RemotePath/MineAdmin/.env' 2>/dev/null" -Quiet -AllowFail)
$remoteEnvExists = [bool]$remoteEnv

if ($remoteEnvExists -and -not $Force) {
    if (-not $DbPassword) { $DbPassword = Get-EnvValue $remoteEnv 'DB_PASSWORD' }
    if (-not $DbUser) { $DbUser = Get-EnvValue $remoteEnv 'DB_USERNAME' }
    if (-not $DbName) { $DbName = Get-EnvValue $remoteEnv 'DB_DATABASE' }
    if (-not $RedisAuth) { $RedisAuth = Get-EnvValue $remoteEnv 'REDIS_AUTH' }
    Write-Ok '检测到已有 .env，将只更新连接配置（JWT_SECRET 保留；加 -Force 完全重建）'
}
if (-not $DbName) { $DbName = 'mineadmin' }
if (-not $DbUser) { $DbUser = 'mineadmin' }
if (-not $DbPassword) {
    throw @"
缺少数据库密码。先在宝塔面板创建数据库，然后重跑并带上参数，例如：
  powershell -ExecutionPolicy Bypass -File scripts\bootstrap-native.ps1 -DbUser mineadmin -DbPassword '你的密码'
"@
}

$template = Get-Content -LiteralPath (Join-Path $script:LocalAppRoot '.env.example') -Raw
$envText = $template -replace "`r`n", "`n"

$jwtSecret = if ($remoteEnvExists -and -not $Force) { Get-EnvValue $remoteEnv 'JWT_SECRET' } else { '' }
if (-not $jwtSecret) { $jwtSecret = New-RandomSecret 64 }

# 生产模式；SWAGGER_ENABLED 必须 true，MineAdmin 3.2 的路由靠注解扫描注册
$envText = Set-EnvValue $envText 'APP_ENV' 'prod'
$envText = Set-EnvValue $envText 'APP_DEBUG' 'false'
$envText = Set-EnvValue $envText 'SWAGGER_ENABLED' 'true'
$envText = Set-EnvValue $envText 'SWAGGER_AUTO_GENERATE' 'false'

$envText = Set-EnvValue $envText 'DB_DRIVER' 'mysql'
$envText = Set-EnvValue $envText 'DB_HOST' $DbHost
$envText = Set-EnvValue $envText 'DB_PORT' "$DbPort"
$envText = Set-EnvValue $envText 'DB_DATABASE' $DbName
$envText = Set-EnvValue $envText 'DB_USERNAME' $DbUser
$envText = Set-EnvValue $envText 'DB_PASSWORD' $DbPassword

$envText = Set-EnvValue $envText 'REDIS_HOST' $RedisHost
$envText = Set-EnvValue $envText 'REDIS_PORT' "$RedisPort"
$envText = Set-EnvValue $envText 'REDIS_AUTH' $RedisAuth

$envText = Set-EnvValue $envText 'APP_URL' $appUrl
$envText = Set-EnvValue $envText 'JWT_SECRET' $jwtSecret

# 原生部署只监听本机，由宝塔 Nginx 反代；避免 9501 绕过 Nginx 暴露到公网
$envText = Set-EnvValue $envText 'SERVER_HOST' '127.0.0.1'

$localEnv = Join-Path $env:TEMP 'mineadmin-native.env'
[IO.File]::WriteAllText($localEnv, $envText, (New-Object System.Text.UTF8Encoding($false)))
Send-File $localEnv "$RemotePath/MineAdmin/.env"
Invoke-Ssh "chmod 600 '$RemotePath/MineAdmin/.env'" -Quiet | Out-Null
Write-Ok "已写入 .env（APP_ENV=prod / DB=${DbHost}:${DbPort}/${DbName} / APP_URL=$appUrl）"

Write-Step '4/6 安装依赖、迁移、初始化数据（首次较慢）'
$installArgs = "--php-bin='$PhpBin'"
if ($SkipFrontend) { $installArgs += ' --skip-frontend' }
Invoke-SshStream "cd '$RemotePath' && bash deploy/native/install.sh $installArgs"

if (-not $SkipStart) {
    Write-Step '5/6 启动 Hyperf'
    Invoke-SshStream "cd '$RemotePath' && bash deploy/native/manage.sh start"
}
else {
    Write-Step '5/6 已跳过启动（-SkipStart）'
}

Write-Step '6/6 健康检查'
if (-not $SkipStart) {
    Start-Sleep -Seconds 2
    $apiCode = (Invoke-Ssh "curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X POST -H 'Content-Type: application/json' -d '{}' http://127.0.0.1:9501/admin/passport/login" -Quiet -AllowFail).Trim()
    Write-Host "    后端直连 HTTP：$apiCode（422 = 正常，参数校验失败）"
    if ($apiCode -ne '422' -and $apiCode -ne '200' -and $apiCode -ne '401') {
        Write-Host '    后端没正常响应，看日志：powershell -File scripts\remote.ps1 -Native logs' -ForegroundColor Yellow
    }
}

Write-Host ''
Write-Host '================ 原生部署完成 ================' -ForegroundColor Green
Write-Host "  后端直连 : http://127.0.0.1:9501（只在服务器本机）"
Write-Host "  对外地址 : $appUrl/"
Write-Host '  默认账号 : admin / 123456'
Write-Host ''
Write-Host '  还差最后一步：在宝塔面板建站并反代' -ForegroundColor Cyan
Write-Host '    1) 网站 → 添加站点 → PHP 版本选「纯静态」'
Write-Host "    2) 网站目录改成：$RemotePath/MineAdmin/web"
Write-Host '    3) 设置 → 配置文件，把 deploy/bt/nginx-site.conf 粘进 server { }'
Write-Host "    4) chmod o+x $RemotePath $RemotePath/MineAdmin"
Write-Host '    详见 docs/11-不用Docker启动.md'
Write-Host ''
Write-Host '  看日志 : powershell -File scripts\remote.ps1 -Native logs'
Write-Host '  重启   : powershell -File scripts\remote.ps1 -Native restart'
Write-Host '  发布   : powershell -File scripts\publish.ps1 -Native -Message "说明"'
