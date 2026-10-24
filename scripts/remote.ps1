param(
    [ValidateSet('ps', 'up', 'down', 'restart', 'reload', 'logs', 'shell', 'exec', 'install', 'migrate', 'seed', 'tinker', 'update', 'tunnel', 'url', 'watch')]
    [string]$Action = 'ps',
    [string]$Command = '',
    [int]$Tail = 200,
    # 服务器不用 Docker（宝塔 PHP 直跑）时加这个开关，命令会走 deploy/native/
    [switch]$Native
)

. "$PSScriptRoot\common.ps1"

if ($Native) {
    switch ($Action) {
        'ps' {
            Invoke-Ssh "cd '$RemotePath' && bash deploy/native/manage.sh status"
        }
        'up' {
            Invoke-SshStream "cd '$RemotePath' && bash deploy/native/manage.sh start"
            Write-Ok "已启动：$(Get-PublicUrl)"
        }
        'down' {
            Invoke-Ssh "cd '$RemotePath' && bash deploy/native/manage.sh stop"
        }
        'restart' {
            Invoke-SshStream "cd '$RemotePath' && bash deploy/native/manage.sh restart"
            Write-Ok 'Hyperf 已重启（PHP 代码生效；.env / config 修改也已重新加载）'
        }
        'reload' {
            Invoke-Ssh "cd '$RemotePath' && bash deploy/native/manage.sh reload"
            Write-Ok '已平滑重载 worker（只改 PHP 代码时够用）'
        }
        'logs' {
            Write-Info 'Ctrl+C 退出日志'
            Invoke-SshStream "cd '$RemotePath' && bash deploy/native/manage.sh logs $Tail"
        }
        'shell' {
            $sshArgs = @($script:SshArgs) + @('-t')
            & ssh @sshArgs $script:Target "cd '$RemotePath/MineAdmin' && exec bash -l"
            if ($LASTEXITCODE -ne 0) { throw '进入服务器 shell 失败' }
        }
        'exec' {
            if (-not $Command) { throw '用法：.\remote.ps1 -Native exec -Command "bin/hyperf.php list"' }
            $escaped = $Command.Replace("'", "'\''")
            Invoke-SshStream "cd '$RemotePath/MineAdmin' && '$PhpBin' $escaped"
        }
        'install' {
            Invoke-SshStream "cd '$RemotePath' && bash deploy/native/install.sh --php-bin='$PhpBin'"
        }
        'migrate' {
            Invoke-Ssh "cd '$RemotePath/MineAdmin' && '$PhpBin' bin/hyperf.php migrate --force"
        }
        'seed' {
            Invoke-Ssh "cd '$RemotePath/MineAdmin' && '$PhpBin' bin/hyperf.php db:seed --path=databases/seeders --force"
        }
        'tinker' {
            $sshArgs = @($script:SshArgs) + @('-t')
            & ssh @sshArgs $script:Target "cd '$RemotePath/MineAdmin' && exec '$PhpBin' bin/hyperf.php tinker"
            if ($LASTEXITCODE -ne 0) { throw 'tinker 启动失败（确认已安装 friendsofhyperf/tinker）' }
        }
        'update' {
            Invoke-SshStream "cd '$RemotePath' && bash deploy/native/update.sh --php-bin='$PhpBin'"
            Write-Ok "已更新：$(Get-PublicUrl)"
        }
        'watch' {
            Write-Info '前台热更新：改 PHP 文件后 Hyperf 自动重启 worker（Ctrl+C 退出）'
            Invoke-SshStream "cd '$RemotePath' && bash deploy/native/manage.sh watch"
        }
        'tunnel' {
            Write-Info 'SSH 隧道：本地 127.0.0.1:9501 -> 服务器 127.0.0.1:9501（Ctrl+C 退出）'
            Write-Info '另开窗口：cd MineAdmin-Vue; pnpm dev'
            $sshArgs = @($script:SshArgs) + @('-N', '-L', '9501:127.0.0.1:9501')
            & ssh @sshArgs $script:Target
            if ($LASTEXITCODE -ne 0) { throw 'SSH 隧道建立失败' }
        }
        'url' {
            Write-Host (Get-PublicUrl)
        }
    }
    return
}

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
    'reload' {
        Write-Info 'docker 模式下没有 worker 级 reload，使用 restart'
        Invoke-Ssh "$($script:ComposeCmd) restart app"
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
    'watch' {
        Write-Info '前台热更新：改 PHP 文件后 Hyperf 自动重启 worker（Ctrl+C 退出）'
        Invoke-SshStream "$($script:ComposeCmd) exec -T app php bin/hyperf.php server:watch"
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
