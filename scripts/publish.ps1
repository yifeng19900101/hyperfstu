[CmdletBinding()]
param(
    [string]$Message = '',
    [switch]$SkipDeploy,
    # 服务器不用 Docker（宝塔 PHP 直跑）时加这个开关
    [switch]$Native,
    # 发布前在本地 pnpm build，把新的 dist 一起提交（FRONTEND_MODE=repo 时用）
    [switch]$BuildFrontend
)

. "$PSScriptRoot\common.ps1"

if ($BuildFrontend) {
    Write-Step '0/4 构建前端（本地 pnpm build）'
    if (-not (Test-Path -LiteralPath $script:LocalFrontRoot)) {
        throw "找不到前端目录：$($script:LocalFrontRoot)"
    }
    $nodeVersion = & node -v 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $nodeVersion) {
        throw '本机没有 node。装 Node 22 后再用 -BuildFrontend，或手动 cd MineAdmin-Vue; pnpm build'
    }
    Write-Info "node $nodeVersion"
    if (-not (Test-Path -LiteralPath (Join-Path $script:LocalFrontRoot 'node_modules'))) {
        Write-Info 'node_modules 不存在，先 pnpm install'
        & pnpm --dir $script:LocalFrontRoot install --frozen-lockfile
        if ($LASTEXITCODE -ne 0) { throw 'pnpm install 失败' }
    }
    Write-Info 'pnpm build ...'
    & pnpm --dir $script:LocalFrontRoot build
    if ($LASTEXITCODE -ne 0) { throw 'pnpm build 失败' }
    if (-not (Test-Path -LiteralPath (Join-Path $script:LocalFrontRoot 'dist\index.html'))) {
        throw 'build 完成但没有 dist\index.html'
    }
    Write-Ok 'dist 已更新，将随本次提交一起推送'
}

Write-Step '1/4 提交本地修改'
# 全程只用一个 main 分支：不在 main 上就直接中止
Assert-OnMainBranch | Out-Null

& git -C $script:ProjectRoot add -A
if ($LASTEXITCODE -ne 0) { throw 'git add 失败' }

& git -C $script:ProjectRoot diff --cached --quiet
$hasChanges = ($LASTEXITCODE -ne 0)

if ($hasChanges) {
    if (-not $Message) {
        $Message = 'study: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    }
    & git -C $script:ProjectRoot commit -m $Message
    if ($LASTEXITCODE -ne 0) { throw 'git commit 失败' }
    Write-Ok "已提交：$Message"
}
else {
    Write-Ok '没有新修改，跳过 commit'
}

Write-Step '2/4 推送到 GitHub'
$origin = & git -C $script:ProjectRoot remote get-url origin 2>$null
if ($LASTEXITCODE -ne 0 -or -not $origin) {
    throw @"
本地仓库还没有 origin。先在 GitHub 创建仓库，然后执行：
  git -C "$($script:ProjectRoot)" remote add origin https://github.com/你的用户名/hyperfstu.git
  git -C "$($script:ProjectRoot)" push -u origin main
"@
}
& git -C $script:ProjectRoot push -u origin main
if ($LASTEXITCODE -ne 0) {
    throw "git push 失败。检查 GitHub 登录状态 / 远程分支是否是 main（本项目只用 main）"
}
Write-Ok '已推送 origin/main'

if ($SkipDeploy) {
    Write-Ok '已跳过服务器部署（-SkipDeploy）'
    return
}

Write-Step '3/4 服务器拉取并发布'
if ($Native) {
    Invoke-SshStream "cd '$RemotePath' && bash deploy/native/update.sh --php-bin='$PhpBin'"
}
else {
    Invoke-SshStream "cd '$RemotePath' && bash deploy/update.sh"
}

$url = Get-PublicUrl
Write-Host ''
Write-Host '================ 发布完成 ================' -ForegroundColor Green
Write-Host "  前端地址 : $url/"
Write-Host "  接口地址 : $url$ApiPrefix"
Write-Host ''
if ($Native) {
    Write-Host '  看日志 : powershell -ExecutionPolicy Bypass -File scripts\remote.ps1 -Native logs'
}
else {
    Write-Host '  看实时日志 : powershell -ExecutionPolicy Bypass -File scripts\remote.ps1 logs'
}
