[CmdletBinding()]
param(
    [string]$Message = '',
    [switch]$SkipDeploy,
    # 服务器不用 Docker（宝塔 PHP 直跑）时加这个开关
    [switch]$Native
)

. "$PSScriptRoot\common.ps1"

Write-Step '1/3 提交本地修改'
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

Write-Step '2/3 推送到 GitHub'
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

Write-Step '3/3 服务器拉取并发布'
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
Write-Host "  接口地址 : $url/prod"
Write-Host ''
if ($Native) {
    Write-Host '  看日志 : powershell -ExecutionPolicy Bypass -File scripts\remote.ps1 -Native logs'
}
else {
    Write-Host '  看实时日志 : powershell -ExecutionPolicy Bypass -File scripts\remote.ps1 logs'
}
