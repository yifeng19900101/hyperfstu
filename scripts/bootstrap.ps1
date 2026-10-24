[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$SkipFrontend
)

. "$PSScriptRoot\common.ps1"

function New-RandomString {
    param([int]$Length = 24)
    $chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
    $bytes = New-Object byte[] $Length
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $result = ''
    foreach ($b in $bytes) { $result += $chars[$b % $chars.Length] }
    return $result
}

function New-RandomSecret {
    param([int]$Bytes = 64)
    $buffer = New-Object byte[] $Bytes
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($buffer)
    return [Convert]::ToBase64String($buffer)
}

function Wait-Healthy {
    param([string[]]$Containers, [int]$TimeoutSeconds = 180)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $allHealthy = $true
        foreach ($name in $Containers) {
            $status = (Invoke-Ssh "docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' $name" -Quiet -AllowFail).Trim()
            if ($status -ne 'healthy' -and $status -ne 'running') { $allHealthy = $false }
        }
        if ($allHealthy) { return $true }
        Start-Sleep -Seconds 3
    }
    return $false
}

if (-not $RepoUrl -or $RepoUrl -match 'your-name') {
    throw @"
deploy.config.ps1 里还没有填写 RepoUrl（GitHub 仓库地址）。
先在 GitHub 创建一个仓库（建议 private），然后填写，例如：
  `$RepoUrl = 'https://github.com/你的用户名/hyperfstu.git'
私有仓库需要先给服务器配置 Deploy Key，见 docs\08-GitHub部署与前端发布.md。
"@
}

Write-Step '1/7 检查服务器连接与 Docker'
Assert-RemoteReady

$composeVersion = Invoke-Ssh 'docker compose version' -Quiet -AllowFail
if ($composeVersion -notmatch 'Docker Compose') {
    throw "服务器上的 Docker Compose 不可用。请先安装 Docker（含 compose 插件）后重试。`n输出：$composeVersion"
}
Write-Ok 'Docker Compose 可用'

Write-Step "2/7 克隆 / 更新 GitHub 仓库（$Branch）"
$isRepo = (Invoke-Ssh "test -d '$RemotePath/.git' && echo yes || echo no" -Quiet -AllowFail).Trim()
if ($isRepo -eq 'yes') {
    Invoke-Ssh "cd '$RemotePath' && git fetch --prune origin && git pull --ff-only origin '$Branch'" -Quiet
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
        Invoke-Ssh "GIT_TERMINAL_PROMPT=0 git clone --branch '$Branch' '$RepoUrl' '$RemotePath'" -Quiet
    }
    catch {
        throw @"
无法 clone 仓库：$RepoUrl
1) 公开仓库：确认地址和分支（$Branch）正确
2) 私有仓库：需要给服务器配置 Deploy Key（docs\08-GitHub部署与前端发布.md）
3) 确认服务器能访问 github.com
原始错误：$_
"@
    }
    Write-Ok '仓库已克隆'
}

$head = (Invoke-Ssh "cd '$RemotePath' && git log -1 --oneline" -Quiet -AllowFail).Trim()
Write-Ok "当前提交：$head"
$composerJson = (Invoke-Ssh "test -f '$RemotePath/MineAdmin/composer.json' && echo yes || echo no" -Quiet -AllowFail).Trim()
if ($composerJson -ne 'yes') {
    throw "仓库里没有找到 MineAdmin/composer.json，请确认分支 $Branch 正确。"
}

Write-Step '3/7 准备 deploy/.env'
$deployEnvLocal = Join-Path $script:DeployDir '.env'
if (-not (Test-Path -LiteralPath $deployEnvLocal)) {
    # 本地没有时先尝试复用服务器上的密码，避免把已有数据库密码改掉
    $remoteEnv = Invoke-Ssh "cat '$RemotePath/deploy/.env' 2>/dev/null" -Quiet -AllowFail
    if ($remoteEnv -match '(?m)^DB_ROOT_PASSWORD=(.+)$') {
        $envText = ($remoteEnv -split "`r?`n" | Where-Object { $_ -match '^(WEB_PORT|APP_PORT|DB_ROOT_PASSWORD|DB_DATABASE|DB_EXPOSE_PORT|REDIS_EXPOSE_PORT)=' }) -join "`n"
        if ($envText -notmatch '(?m)^WEB_PORT=') { $envText = "WEB_PORT=80`n$envText" }
        [IO.File]::WriteAllText($deployEnvLocal, $envText, (New-Object System.Text.UTF8Encoding($false)))
        Write-Ok '已从服务器取回 deploy/.env'
    }
    else {
        $dbPassword = New-RandomString 24
        $content = @"
WEB_PORT=80
APP_PORT=9501
DB_ROOT_PASSWORD=$dbPassword
DB_DATABASE=mineadmin
DB_EXPOSE_PORT=13306
REDIS_EXPOSE_PORT=16379
"@
        [IO.File]::WriteAllText($deployEnvLocal, ($content -replace "`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
        Write-Ok '已生成 deploy/.env（数据库密码随机）'
    }
}
else {
    Write-Ok '沿用已有的 deploy/.env'
}

$dbPassword = Get-DeployEnvValue 'DB_ROOT_PASSWORD' 'root'
$webPort = Get-DeployEnvValue 'WEB_PORT' '80'
$appPort = Get-DeployEnvValue 'APP_PORT' '9501'
Send-File $deployEnvLocal "$RemotePath/deploy/.env"
Write-Ok "已上传 deploy/.env（WEB_PORT=$webPort）"

Write-Step '4/7 写入后端 MineAdmin/.env'
$appUrl = Get-PublicUrl
$remoteEnvExists = (Invoke-Ssh "test -f '$RemotePath/MineAdmin/.env' && echo yes || echo no" -Quiet -AllowFail).Trim()
if ($remoteEnvExists -eq 'yes' -and -not $Force) {
    Invoke-Ssh "sed -i 's|^APP_URL=.*|APP_URL=$appUrl|' '$RemotePath/MineAdmin/.env'; sed -i 's|^SWAGGER_ENABLED=.*|SWAGGER_ENABLED=true|' '$RemotePath/MineAdmin/.env'" -Quiet
    Write-Ok '服务器已有 .env，已校正 APP_URL / SWAGGER_ENABLED（加 -Force 可完全重建）'
}
else {
    $template = Get-Content -LiteralPath (Join-Path $script:LocalAppRoot '.env.example') -Raw
    $jwtSecret = New-RandomSecret 64

    $envText = $template
    # MineAdmin 3.2 的路由由 Swagger 注解注册，必须开启 SWAGGER_ENABLED，否则所有 /admin/* 都是 404
    $envText = [regex]::Replace($envText, '(?m)^APP_ENV=.*$', 'APP_ENV=dev')
    $envText = [regex]::Replace($envText, '(?m)^APP_DEBUG=.*$', 'APP_DEBUG=true')
    $envText = [regex]::Replace($envText, '(?m)^SWAGGER_ENABLED=.*$', 'SWAGGER_ENABLED=true')
    $envText = [regex]::Replace($envText, '(?m)^SWAGGER_AUTO_GENERATE=.*$', 'SWAGGER_AUTO_GENERATE=false')
    $envText = [regex]::Replace($envText, '(?m)^DB_HOST=.*$', 'DB_HOST=mysql')
    $envText = [regex]::Replace($envText, '(?m)^DB_PORT=.*$', 'DB_PORT=3306')
    $envText = [regex]::Replace($envText, '(?m)^DB_DATABASE=.*$', 'DB_DATABASE=mineadmin')
    $envText = [regex]::Replace($envText, '(?m)^DB_PASSWORD=.*$', "DB_PASSWORD=$dbPassword")
    $envText = [regex]::Replace($envText, '(?m)^REDIS_HOST=.*$', 'REDIS_HOST=redis')
    $envText = [regex]::Replace($envText, '(?m)^REDIS_PORT=.*$', 'REDIS_PORT=6379')
    $envText = [regex]::Replace($envText, '(?m)^JWT_SECRET=.*$', "JWT_SECRET=$jwtSecret")
    $envText = [regex]::Replace($envText, '(?m)^APP_URL=.*$', "APP_URL=$appUrl")
    $envText = $envText -replace "`r`n", "`n"

    $localEnv = Join-Path $env:TEMP 'mineadmin.env'
    [IO.File]::WriteAllText($localEnv, $envText, (New-Object System.Text.UTF8Encoding($false)))
    Send-File $localEnv "$RemotePath/MineAdmin/.env"
    Invoke-Ssh "chmod 600 '$RemotePath/MineAdmin/.env'" -Quiet | Out-Null
    Write-Ok "已生成 MineAdmin/.env（APP_DEBUG=true / SWAGGER_ENABLED=true / APP_URL=$appUrl）"
}

Write-Step '5/7 安装依赖、初始化数据库、构建前端（首次较慢）'
$updateArgs = '--skip-pull --init'
if ($SkipFrontend) { $updateArgs += ' --skip-frontend' }
Invoke-SshStream "cd '$RemotePath' && bash deploy/update.sh $updateArgs"

Write-Step '6/7 健康检查'
Start-Sleep -Seconds 5
$webCode = (Invoke-Ssh "curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:$webPort/" -Quiet -AllowFail).Trim()
$apiCode = (Invoke-Ssh "curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X POST -H 'Content-Type: application/json' -d '{}' http://127.0.0.1:$webPort/prod/admin/passport/login" -Quiet -AllowFail).Trim()
Write-Host "    前端 HTTP：$webCode    登录接口 HTTP：$apiCode"
if ($webCode -ne '200') {
    Write-Host '    前端不是 200，检查：docker compose -f deploy/docker-compose.yml logs nginx' -ForegroundColor Yellow
}
if ($apiCode -eq '502' -or $apiCode -eq '503') {
    Write-Host '    后端 502/503，检查：powershell -File scripts\remote.ps1 logs' -ForegroundColor Yellow
}

Write-Step '7/7 完成'
Write-Host ''
Write-Host '================ 部署完成 ================' -ForegroundColor Green
Write-Host "  前端地址 : $appUrl/"
Write-Host "  接口地址 : $appUrl/prod/admin/passport/login"
Write-Host "  默认账号 : admin / 123456"
Write-Host ''
Write-Host '  看实时日志 : powershell -ExecutionPolicy Bypass -File scripts\remote.ps1 logs'
Write-Host '  日常发布   : powershell -ExecutionPolicy Bypass -File scripts\publish.ps1 -Message "说明"'
Write-Host '  快速草稿   : powershell -ExecutionPolicy Bypass -File scripts\sync.ps1 -Watch'
Write-Host '  进容器     : powershell -ExecutionPolicy Bypass -File scripts\remote.ps1 shell'
Write-Host ''
Write-Host "  数据库端口 : 127.0.0.1:$((Get-DeployEnvValue 'DB_EXPOSE_PORT' '13306'))（SSH 隧道访问）"
