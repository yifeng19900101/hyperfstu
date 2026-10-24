[CmdletBinding()]
param(
    # 后端路径（不含代理前缀，默认 /hyperfproapi）
    [string]$Path = '/admin/proxy/debug',
    [ValidateSet('GET', 'POST', 'PUT', 'DELETE', 'PATCH')]
    [string]$Method = 'GET',
    # 自定义请求头，例如 @{ 'X-Custom' = 'hello'; 'Authorization' = 'Bearer xxx' }
    [hashtable]$Headers = @{},
    # 查询参数，例如 @{ page = 1; name = '中文' }
    [hashtable]$Query = @{},
    # 请求体（字符串，通常是 JSON）
    [string]$Body = '',
    [string]$ContentType = 'application/json',
    # 直接指定完整地址，留空则读 deploy.config.ps1 拼出 http://服务器IP[:端口]
    [string]$Url = ''
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Get-BaseUrl {
    if ($Url) { return $Url.TrimEnd('/') }
    . "$PSScriptRoot\common.ps1"
    return (Get-PublicUrl)
}

function ConvertTo-QueryString {
    param([hashtable]$Table)
    if (-not $Table -or $Table.Count -eq 0) { return '' }
    $pairs = foreach ($key in $Table.Keys) {
        '{0}={1}' -f [Uri]::EscapeDataString($key), [Uri]::EscapeDataString([string]$Table[$key])
    }
    return ($pairs -join '&')
}

$baseUrl = Get-BaseUrl
$cleanPath = '/' + $Path.TrimStart('/')
# 前端生产环境 API 前缀（默认 /hyperfproapi，见 common.ps1 的 $ApiPrefix）
if ($cleanPath -notlike "$ApiPrefix/*" -and $cleanPath -ne $ApiPrefix) {
    $cleanPath = $ApiPrefix + $cleanPath
}

$target = $baseUrl + $cleanPath
$queryString = ConvertTo-QueryString -Table $Query
if ($queryString) { $target += '?' + $queryString }

Write-Host ''
Write-Host "==> $Method $target" -ForegroundColor Cyan
foreach ($k in $Headers.Keys) {
    # 只显示前 40 个字符，避免把长 token 打到屏幕上
    $v = [string]$Headers[$k]
    $shown = if ($v.Length -gt 40) { $v.Substring(0, 40) + '...' } else { $v }
    Write-Host "    ${k}: $shown" -ForegroundColor DarkGray
}
if ($Body) { Write-Host "    body: $Body" -ForegroundColor DarkGray }

$params = @{
    Uri                = $target
    Method             = $Method
    UseBasicParsing    = $true
    TimeoutSec         = 30
    Headers            = $Headers
}
if ($Body) {
    $params['Body'] = $Body
    $params['ContentType'] = $ContentType
}

try {
    $response = Invoke-WebRequest @params
}
catch [System.Net.WebException] {
    $resp = $_.Exception.Response
    if ($null -eq $resp) { throw }
    $code = [int]$resp.StatusCode
    $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
    $text = $reader.ReadToEnd()
    Write-Host ''
    Write-Host "HTTP $code" -ForegroundColor Red
    Write-Host '--- 响应头（部分）---' -ForegroundColor Yellow
    foreach ($name in 'Content-Type', 'Request-Id', 'Server', 'X-Request-Id') {
        $val = $resp.Headers[$name]
        if ($val) { Write-Host "  $name : $val" }
    }
    Write-Host '--- 响应体 ---' -ForegroundColor Yellow
    Write-Host $text
    exit 1
}

Write-Host ''
Write-Host "HTTP $($response.StatusCode) $($response.StatusDescription)" -ForegroundColor Green

Write-Host ''
Write-Host '--- 响应头 ---' -ForegroundColor Yellow
foreach ($key in $response.Headers.Keys) {
    Write-Host ("  {0}: {1}" -f $key, $response.Headers[$key])
}

Write-Host ''
Write-Host '--- 响应体 ---' -ForegroundColor Yellow
$text = $response.Content
try {
    $json = $text | ConvertFrom-Json
    Write-Host ($json | ConvertTo-Json -Depth 10)
}
catch {
    Write-Host $text
}
