[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$SkipFrontend,
    # 宝塔 / 1Panel 等面板已占用 80 端口时加这个开关：
    # 不启动 docker nginx，入口交给面板的 Nginx 反代到 127.0.0.1:9501
    [switch]$BtPanel
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

Write-Step '2/7 克隆 / 更新 GitHub 仓库（只用 main 分支）'
$isRepo = (Invoke-Ssh "test -d '$RemotePath/.git' && echo yes || echo no" -Quiet -AllowFail).Trim()
if ($isRepo -eq 'yes') {
    # 服务器也必须待在 main 上，否则 pull 会静默失败或拉到别的分支
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
    throw "仓库里没有找到 MineAdmin/composer.json，请确认仓库的 main 分支内容完整。"
}

Write-Step '3/7 准备 deploy/.env'
$deployEnvLocal = Join-Path $script:DeployDir '.env'

function Set-DeployEnvValue {
    param([string]$File, [string]$Key, [string]$Value)
    $text = [IO.File]::ReadAllText($File, [Text.Encoding]::UTF8)
    if ($text -match "(?m)^$([regex]::Escape($Key))=") {
        $text = [regex]::Replace($text, "(?m)^$([regex]::Escape($Key))=.*$", "$Key=$Value")
    }
    else {
        if (-not $text.EndsWith("`n")) { $text += "`n" }
        $text += "$Key=$Value`n"
    }
    [IO.File]::WriteAllText($File, ($text -replace "`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
}

if (-not (Test-Path -LiteralPath $deployEnvLocal)) {
    # 本地没有时先尝试复用服务器上的密码，避免把已有数据库密码改掉
    $remoteEnv = Invoke-Ssh "cat '$RemotePath/deploy/.env' 2>/dev/null" -Quiet -AllowFail
    if ($remoteEnv -match '(?m)^DB_ROOT_PASSWORD=(.+)$') {
        $envText = ($remoteEnv -split "`r?`n" | Where-Object { $_ -match '^(USE_DOCKER_NGINX|WEB_PORT|APP_PORT|DB_ROOT_PASSWORD|DB_DATABASE|DB_EXPOSE_PORT|REDIS_EXPOSE_PORT)=' }) -join "`n"
        if ($envText -notmatch '(?m)^WEB_PORT=') { $envText = "WEB_PORT=80`n$envText" }
        if ($envText -notmatch '(?m)^USE_DOCKER_NGINX=') { $envText = "USE_DOCKER_NGINX=1`n$envText" }
        if ($envText -notmatch '(?m)^FRONTEND_MODE=') { $envText = "FRONTEND_MODE=repo`n$envText" }
        [IO.File]::WriteAllText($deployEnvLocal, $envText, (New-Object System.Text.UTF8Encoding($false)))
        Write-Ok '已从服务器取回 deploy/.env'
    }
    else {
        $dbPassword = New-RandomString 24
        $content = @"
USE_DOCKER_NGINX=1
# 前端产物：repo = dist 已提交在仓库里，站点根目录直接指向 MineAdmin-Vue/dist
#           build = 服务器上构建
FRONTEND_MODE=repo
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

# 宝塔模式：不启动 docker nginx，80 端口留给面板
if ($BtPanel) {
    Set-DeployEnvValue -File $deployEnvLocal -Key 'USE_DOCKER_NGINX' -Value '0'
    Write-Ok '宝塔模式：已设置 USE_DOCKER_NGINX=0（入口交给面板 Nginx）'
}

$dbPassword = Get-DeployEnvValue 'DB_ROOT_PASSWORD' 'root'
$webPort = Get-DeployEnvValue 'WEB_PORT' '80'
$appPort = Get-DeployEnvValue 'APP_PORT' '9501'
$useDockerNginx = Get-DeployEnvValue 'USE_DOCKER_NGINX' '1'
Send-File $deployEnvLocal "$RemotePath/deploy/.env"
Write-Ok "已上传 deploy/.env（USE_DOCKER_NGINX=$useDockerNginx, WEB_PORT=$webPort, APP_PORT=$appPort）"

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
if ($useDockerNginx -eq '1') {
    $webCode = (Invoke-Ssh "curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:$webPort/" -Quiet -AllowFail).Trim()
    $apiCode = (Invoke-Ssh "curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X POST -H 'Content-Type: application/json' -d '{}' http://127.0.0.1:$webPort$ApiPrefix/admin/passport/login" -Quiet -AllowFail).Trim()
    Write-Host "    前端 HTTP：$webCode    登录接口 HTTP：$apiCode"
    if ($webCode -ne '200') {
        Write-Host '    前端不是 200，检查：docker compose -f deploy/docker-compose.yml logs nginx' -ForegroundColor Yellow
    }
    if ($apiCode -eq '502' -or $apiCode -eq '503') {
        Write-Host '    后端 502/503，检查：powershell -File scripts\remote.ps1 logs' -ForegroundColor Yellow
    }
}
else {
    # 宝塔模式：容器已启动，但站点还没在面板里配置，先只验证后端直连
    $appCode = (Invoke-Ssh "curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X POST -H 'Content-Type: application/json' -d '{}' http://127.0.0.1:$appPort/admin/passport/login" -Quiet -AllowFail).Trim()
    $webBuilt = (Invoke-Ssh "test -f '$RemotePath/MineAdmin-Vue/dist/index.html' && echo yes || echo no" -Quiet -AllowFail).Trim()
    Write-Host "    后端直连 HTTP：$appCode    MineAdmin-Vue/dist/index.html：$webBuilt"
    if ($appCode -eq '000' -or $appCode -eq '502') {
        Write-Host '    后端没起来，检查：powershell -File scripts\remote.ps1 logs' -ForegroundColor Yellow
    }
    if ($webBuilt -ne 'yes') {
        Write-Host '    前端产物缺失，检查 update.sh 的前端构建步骤' -ForegroundColor Yellow
    }
}

Write-Step '7/7 完成'
Write-Host ''
Write-Host '================ 部署完成 ================' -ForegroundColor Green
if ($useDockerNginx -eq '1') {
    Write-Host "  前端地址 : $appUrl/"
    Write-Host "  接口地址 : $appUrl$ApiPrefix/admin/passport/login"
}
else {
    Write-Host '  还需要在宝塔面板完成两步（只做一次）：'
    Write-Host '    1) 网站 → 添加站点（域名/临时域名都行）→ PHP 版本选「纯静态」'
    Write-Host "    2) 网站目录改成：$RemotePath/MineAdmin-Vue/dist"
    Write-Host '    3) 设置 → 配置文件，把 deploy/bt/nginx-site.conf 里的内容粘进 server { }'
    Write-Host '    4) Nginx 需要能读产物：'
    Write-Host "         chmod o+x $RemotePath $RemotePath/MineAdmin $RemotePath/MineAdmin-Vue"
    Write-Host "         chmod -R o+rX $RemotePath/MineAdmin-Vue/dist $RemotePath/MineAdmin/storage/uploads"
    Write-Host ''
    Write-Host "  配好后的访问地址 : http://<你的域名>/"
    Write-Host "  后端直连（调试） : http://127.0.0.1:$appPort （只能在服务器上访问）"
    Write-Host "  绑了域名后记得改 : MineAdmin/.env 的 APP_URL=http://你的域名"
    Write-Host '  完整步骤文档     : docs/10-宝塔面板部署.md'
}
Write-Host "  默认账号 : admin / 123456"
Write-Host ''
Write-Host '  看实时日志 : powershell -ExecutionPolicy Bypass -File scripts\remote.ps1 logs'
Write-Host '  日常发布   : powershell -ExecutionPolicy Bypass -File scripts\publish.ps1 -Message "说明"'
Write-Host '  快速草稿   : powershell -ExecutionPolicy Bypass -File scripts\sync.ps1 -Watch'
Write-Host '  进容器     : powershell -ExecutionPolicy Bypass -File scripts\remote.ps1 shell'
Write-Host ''
Write-Host "  数据库端口 : 127.0.0.1:$((Get-DeployEnvValue 'DB_EXPOSE_PORT' '13306'))（SSH 隧道访问）"
