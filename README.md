# Hyperf / Swoole 学习工作区（MineAdmin 3.2）

本地读代码、改代码 → push 到 GitHub → 服务器 pull → 自动装依赖 / 迁移 / 构建前端 → 热更新看效果。

## 快速开始

```powershell
# 1. 在 GitHub 创建空仓库 hyperfstu，然后绑定远程并首次推送
cd D:\code\hyperfstu
git remote add origin https://github.com/yifeng19900101/hyperfstu.git
git push -u origin main

# 2. 配置服务器（GitHub 地址、SSH、项目目录）
Copy-Item scripts\deploy.config.example.ps1 scripts\deploy.config.ps1
notepad scripts\deploy.config.ps1

# 3. 一键部署（首次：clone + 安装依赖 + 初始化数据库 + 构建前端）
powershell -ExecutionPolicy Bypass -File scripts\bootstrap.ps1

#   服务器装了宝塔面板（80 端口归面板 Nginx）时用这个：
#   powershell -ExecutionPolicy Bypass -File scripts\bootstrap.ps1 -BtPanel

# 4. 日常发布：commit + push + 服务器更新
powershell -ExecutionPolicy Bypass -File scripts\publish.ps1 -Message "说明"

# 5. 看日志（另一个窗口）
powershell -ExecutionPolicy Bypass -File scripts\remote.ps1 logs
```

详细步骤：[docs/08-GitHub部署与前端发布.md](docs/08-GitHub部署与前端发布.md)

**服务器用的是宝塔面板？** 看 [docs/10-宝塔面板部署.md](docs/10-宝塔面板部署.md)，差别是 `USE_DOCKER_NGINX=0`，由面板 Nginx 做入口。

**完全不想用 Docker？** 看 [docs/11-不用Docker启动.md](docs/11-不用Docker启动.md)：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\bootstrap-native.ps1 -DbUser mineadmin -DbPassword '数据库密码' -Domain 你的域名
```

> 只改 PHP、想立刻看效果且不想提交时，可开 `scripts\sync.ps1 -Watch` 做草稿同步。

## 文档

1. [线上部署与热更新（旧版原理）](docs/01-线上部署与热更新.md)
2. [Swoole 核心机制](docs/02-Swoole核心机制.md)
3. [Swoole 实验课](docs/03-Swoole实验课.md)
4. [Hyperf 核心原理](docs/04-Hyperf核心原理.md)
5. [MineAdmin 源码导读](docs/05-MineAdmin源码导读.md)
6. [实战：写一个 CRUD 模块](docs/06-实战-写一个CRUD模块.md)
7. [六周学习计划](docs/07-六周学习计划.md)
8. [GitHub 部署与前端发布](docs/08-GitHub部署与前端发布.md)
9. [Nginx 反向代理与请求头](docs/09-Nginx反向代理与请求头.md)
10. [宝塔面板部署](docs/10-宝塔面板部署.md)
11. [不用 Docker 启动](docs/11-不用Docker启动.md)

## 目录

- `MineAdmin/`：后端源码（3.2 分支），包含本地 `vendor/` 供阅读
- `MineAdmin/lab/swoole/`：7 个可运行的 Swoole 实验
- `MineAdmin-Vue/`：前端源码（Vue3 + Vite，构建产物同步到 `MineAdmin/web/`，由 Nginx 托管）
- `deploy/`：服务器 compose（app + nginx + mysql + redis）、Nginx 配置、更新脚本
- `deploy/native/`：不用 docker 时的安装 / 更新 / 进程管理脚本（宝塔 PHP 直跑）
- `scripts/`：初始化 / 发布 / 同步 / 日志 / 运行 lab
- `docs/`：学习文档

## 关键事实

- Hyperf 3.2 / PHP >= 8.2 / Swoole >= 5
- 路由由 `hyperf/swagger` 注解自动注册，**必须 `SWAGGER_ENABLED=true`**
- 热更新：`ScanFileDriver`，每 2 秒扫描 `app`、`config`、`.env`
- 前端生产 API 前缀 `/prod`，由 Nginx 去前缀反代到 Swoole
- `composer.lock` 已按 PHP 8.3 重新生成，服务器执行 `composer install`
- Windows 本地跑不了 Swoole，运行一律在服务器容器内
