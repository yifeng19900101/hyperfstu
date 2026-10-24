param(
    [ValidateSet('ps', 'up', 'down', 'restart', 'logs', 'shell', 'exec', 'install', 'migrate', 'seed', 'tinker', 'update', 'tunnel', 'url')]
    [string]$Action = 'ps',
    [string]$Command = '',
    [int]$Tail = 200
)

. "$PSScriptRoot\common.ps1"

switch ($Action) {
    'ps' {
        Invoke-Ssh "$($script:ComposeCmd) ps"
    }
    'up' {
        if (Test-UseDockerNginx) {
            Invoke-Ssh "$($script:ComposeCmd) up -d app nginx"
        }
        else {
            Invoke-Ssh "$($script:ComposeCmd) up -d app"
            Write-Info '宝塔模式：docker nginx 已禁用，入口由面板 Nginx 提供'
        }
        Write-Ok "已启动：$(Get-PublicUrl)"
    }
    'down' {
        Invoke-Ssh "$($script:ComposeCmd) down"
    }
    'restart' {
        Invoke-Ssh "$($script:ComposeCmd) restart app"
        Write-Ok 'app 容器已重启'
    }
    'logs' {
        Write-Info 'Ctrl+C 退出日志（保存代码后这里会看到 Hyperf 重启输出）'
        Invoke-SshStream "$($script:ComposeCmd) logs -f --tail=$Tail app"
    }
    'shell' {
        $sshArgs = @($script:SshArgs) + @('-t')
        & ssh @sshArgs $script:Target "$($script:ComposeCmd) exec app sh"
        if ($LASTEXITCODE -ne 0) { throw '进入容器失败' }
    }
    'exec' {
        if (-not $Command) { throw '用法：.\remote.ps1 exec -Command "php bin/hyperf.php list"' }
        $escaped = $Command.Replace("'", "'\''")
        Invoke-SshStream "$($script:ComposeCmd) exec -T app sh -lc '$escaped'"
    }
    'install' {
        Invoke-SshStream "$($script:ComposeCmd) run --rm -T --no-deps app composer install --no-interaction --prefer-dist -o"
        Invoke-SshStream "$($script:ComposeCmd) run --rm -T --no-deps app php bin/hyperf.php mine:install --no-interaction"
    }
    'migrate' {
        Invoke-Ssh "$($script:ComposeCmd) exec -T app php bin/hyperf.php migrate"
    }
    'seed' {
        Invoke-Ssh "$($script:ComposeCmd) exec -T app php bin/hyperf.php db:seed"
    }
    'tinker' {
        $sshArgs = @($script:SshArgs) + @('-t')
        & ssh @sshArgs $script:Target "$($script:ComposeCmd) exec app php bin/hyperf.php tinker"
        if ($LASTEXITCODE -ne 0) { throw 'tinker 启动失败（确认已安装 friendsofhyperf/tinker）' }
    }
    'update' {
        Invoke-SshStream "cd '$RemotePath' && bash deploy/update.sh"
        Write-Ok "已更新：$(Get-PublicUrl)"
    }
    'tunnel' {
        Write-Info 'SSH 隧道：本地 127.0.0.1:9501 -> 服务器 app:9501（Ctrl+C 退出）'
        Write-Info '另开窗口：cd MineAdmin-Vue; pnpm dev'
        $sshArgs = @($script:SshArgs) + @('-N', '-L', '9501:127.0.0.1:9501')
        & ssh @sshArgs $script:Target
        if ($LASTEXITCODE -ne 0) { throw 'SSH 隧道建立失败' }
    }
    'url' {
        Write-Host (Get-PublicUrl)
    }
}
