param(
    [switch]$Watch,
    [switch]$IncludeEnv,
    [switch]$Quiet
)

. "$PSScriptRoot\common.ps1"

if ($Watch) {
    Write-Step '监听模式：保存文件后自动同步到服务器（Ctrl+C 退出）'
    Sync-Project -IncludeEnv:$IncludeEnv
    $last = Get-SyncSignature
    Write-Info '等待文件变化...'
    while ($true) {
        Start-Sleep -Milliseconds 800
        $signature = Get-SyncSignature
        if ($signature -ne $last) {
            # 等编辑器的连续写入结束，避免同一秒同步多次
            Start-Sleep -Milliseconds 500
            Sync-Project -IncludeEnv:$IncludeEnv
            $last = Get-SyncSignature
            Write-Info '等待文件变化...'
        }
    }
}
else {
    Sync-Project -IncludeEnv:$IncludeEnv -Quiet:$Quiet
}
