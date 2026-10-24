param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$File,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ScriptArgs
)

. "$PSScriptRoot\common.ps1"

$relative = $File.Replace('\', '/')
$localFile = Join-Path $script:LocalAppRoot $relative
if (-not (Test-Path -LiteralPath $localFile)) {
    throw "本地找不到文件：$localFile"
}

Sync-Project -Quiet
$remoteFile = "/opt/www/$relative"
$cmd = "$($script:ComposeCmd) exec -T app php '$remoteFile'"
if ($ScriptArgs -and $ScriptArgs.Count -gt 0) {
    $cmd += ' ' + ($ScriptArgs -join ' ')
}

Write-Info "运行 $relative"
Invoke-SshStream $cmd
