# 复制本文件为 deploy.config.ps1，然后按你的服务器情况修改。
# deploy.config.ps1 不要提交到公开仓库（里面有服务器地址）。

# 服务器公网 IP 或域名
$RemoteHost = '203.0.113.10'

# SSH 用户（学习环境通常用 root；用普通用户需要给 docker 权限）
$RemoteUser = 'root'

# SSH 端口
$RemotePort = 22

# 服务器上的项目目录（Git 仓库会 clone 到这里）
$RemotePath = '/opt/hyperfstu'

# 私钥路径，例如 C:\Users\Administrator\.ssh\id_ed25519
# 留空则使用 ssh-agent / 默认密钥；如果都没配置，会提示输入密码
$IdentityFile = ''

# GitHub 仓库地址（服务器用它 clone / pull）
# 公开仓库：https://github.com/你的用户名/hyperfstu.git
# 私有仓库：git@github.com:你的用户名/hyperfstu.git（需要给服务器配 Deploy Key，见 docs/08）
$RepoUrl = 'https://github.com/your-name/hyperfstu.git'

# 分支：固定 main，不提供配置项（全程只用一个分支，脚本里写死）

# 容器名（一般不用改）
$AppContainer = 'mineadmin-app'

# 原生部署（不用 Docker）时用的 PHP 可执行文件，宝塔面板一般是这个
$PhpBin = '/www/server/php/83/bin/php'
