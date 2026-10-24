# 08 GitHub 存储 + 服务器拉取部署（含前端）

> 服务器装了**宝塔面板**的话，直接看 [10-宝塔面板部署](10-宝塔面板部署.md)：80 端口归面板 Nginx，`USE_DOCKER_NGINX=0`。
> 代理层（`/prod` 转发、请求头、后端取参、真实 IP）的细节见 [09-Nginx反向代理与请求头](09-Nginx反向代理与请求头.md)。

目标：本地改代码 → `git push` 到 GitHub → 服务器 `git pull` → 自动装依赖、迁移、构建前端 → 热更新生效。

sudo -u www git clone https://github.com/yifeng19900101/hyperfstu.git

这条链路替代了 01 里的「tar 覆盖同步」，更适合长期学习和多机协作。`sync.ps1` 仍然保留，用来做不提交的快速草稿。

---

## 1. 最终结构

**GitHub 单仓库**（后端 + 前端 + 部署 + 文档）：

```
hyperfstu/
├─ MineAdmin/            # Hyperf 3.2 后端
│  ├─ app/ config/ databases/ plugin/
│  ├─ lab/swoole/        # Swoole 实验
│  ├─ .env               # 服务器本地生成，不进 Git
│  └─ vendor/            # 服务器 composer，不进 Git
├─ MineAdmin-Vue/        # Vue3 前端源码
│  ├─ src/ ...
│  └─ dist/              # 服务器构建缓存，不进 Git
│  # MineAdmin/web/      # 构建产物同步到这里，Nginx 实际托管，不进 Git
├─ deploy/
│  ├─ docker-compose.yml # app + nginx + mysql + redis
│  ├─ nginx/default.conf # 静态站 + /prod 反代
│  ├─ update.sh          # 服务器更新入口
│  └─ .env               # 密码/端口，不进 Git
├─ scripts/              # Windows 侧脚本
└─ docs/
```

**服务器运行结构**（`/opt/hyperfstu`）：

```
浏览器 :80
   │
   ├─ /            → nginx → /usr/share/nginx/html（服务器上的 MineAdmin/web）
   ├─ /static/*    → nginx 直接返回，30 天缓存
   ├─ /uploads/*   → nginx 直接读 MineAdmin/storage/uploads
   └─ /prod/admin/* → 去掉 /prod → app:9501（Swoole server:watch）
```

前端 `.env.production` 里 `VITE_OPEN_PROXY=true`，所以打包后 axios 的 `baseURL` 是 `/prod`。Nginx 把 `/prod/` 前缀去掉再转发，后端不需要改任何路由。

---

## 2. 一次性准备

### 2.1 在 GitHub 建仓库

打开 GitHub → New repository：

- 名称：`hyperfstu`
- 可见性：
  - **Public**：服务器可以直接 `git clone`，最省事（代码里没有密码，`.env` 已被忽略）
  - **Private**：需要给服务器配 Deploy Key，见 2.4
- 不要勾选 Add README / .gitignore（本地已经有内容）

### 2.2 本地仓库已经初始化好了

本工作区已经执行过 `git init -b main` 并完成首次提交。你只需要绑定远程仓库并推送：

```powershell
cd D:\code\hyperfstu
git remote add origin https://github.com/你的用户名/hyperfstu.git
git push -u origin main
```

> 如果 `git push` 弹窗，按提示登录 GitHub 即可（Windows 凭据管理器会记住）。
> 之后日常发布直接运行 `scripts\publish.ps1`，它会自动 add / commit / push / 远程部署。

### 2.3 填写服务器配置

```powershell
Copy-Item scripts\deploy.config.example.ps1 scripts\deploy.config.ps1
notepad scripts\deploy.config.ps1
```

至少改这几项：

```powershell
$RemoteHost = '你的服务器IP'
$RemoteUser = 'root'
$RemotePath = '/opt/hyperfstu'
$RepoUrl    = 'https://github.com/你的用户名/hyperfstu.git'   # 公开仓库
$Branch     = 'main'
```

`scripts\deploy.config.ps1` 和 `deploy\.env` 都在 `.gitignore` 里，不会被推上去。

### 2.4 私有仓库：给服务器配 Deploy Key

在服务器上执行：

```bash
ssh-keygen -t ed25519 -C "hyperfstu-deploy" -f ~/.ssh/hyperfstu_deploy -N ""
cat ~/.ssh/hyperfstu_deploy.pub
```

复制输出的公钥，到 GitHub 仓库 → **Settings → Deploy keys → Add deploy key**，粘贴并保存（只读即可，不需要 Allow write）。

然后让服务器访问 github.com 时默认用这把钥匙：

```bash
cat >> ~/.ssh/config <<'EOF'
Host github.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/hyperfstu_deploy
  IdentitiesOnly yes
EOF
chmod 600 ~/.ssh/config
ssh -T git@github.com
```

看到 `Hi xxx! You've successfully authenticated...` 就对了。此时 `$RepoUrl` 用 SSH 地址：

```powershell
$RepoUrl = 'git@github.com:你的用户名/hyperfstu.git'
```

> 同一个 Deploy Key 只能绑定一个仓库；换仓库要重新生成一把。

---

## 3. 第一次部署

服务器需要：Docker + Docker Compose 插件、能访问 GitHub、放行 **80** 端口（SSH 22 默认已开）。

```powershell
powershell -ExecutionPolicy Bypass -File scripts\bootstrap.ps1
```

脚本会依次做：

1. 检查 SSH / Docker Compose
2. `git clone` 仓库到 `/opt/hyperfstu`（已存在则 `git pull --ff-only`）
3. 生成并上传 `deploy/.env`（随机数据库密码、`WEB_PORT=80`）
4. 生成并上传 `MineAdmin/.env`（`SWAGGER_ENABLED=true`、随机 JWT、`APP_URL=http://服务器IP`）
5. 启动 MySQL / Redis，`composer install`，`mine:install`（migrate + seed）
6. 用 Node 容器 `pnpm install --frozen-lockfile && pnpm build`，产物在 `MineAdmin-Vue/dist`，再同步到 `MineAdmin/web`
7. 启动 app + nginx，做首页和登录接口健康检查

完成后访问：

- 前端：`http://服务器IP/`
- 接口：`http://服务器IP/prod/admin/passport/login`
- 账号：`admin / 123456`

> 第一次会拉取 hyperf、mysql、nginx、node 镜像，并安装 Composer/npm 依赖，通常 5~10 分钟。

---

## 4. 日常开发循环

### 4.1 正式流程（推荐）

```powershell
# 改完代码后一条命令：commit + push + 服务器 pull + 依赖/迁移/前端构建
powershell -ExecutionPolicy Bypass -File scripts\publish.ps1 -Message "feat: 完成通知模块"

# 只看线上日志（另一个窗口）
powershell -ExecutionPolicy Bypass -File scripts\remote.ps1 logs
```

服务器端 `deploy/update.sh` 实际做的事：

```bash
git pull --ff-only
docker compose up -d mysql redis
# composer.json / lock 比 vendor 新时才 composer install
docker compose run --rm app php bin/hyperf.php migrate --force
# 前端源码比 dist/index.html 新时才构建
docker compose up -d
```

PHP 文件被 `git pull` 覆盖后，`server:watch` 会在 2 秒内检测到并重启 Swoole，不需要手动 restart。前端改动则会在本次发布时重新构建，刷新浏览器即可。

### 4.2 草稿流程（不提交，最快）

只改 PHP、还想 2 秒看效果时：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\sync.ps1 -Watch
```

它直接 tar+SSH 覆盖服务器 `MineAdmin/` 下的代码（不经过 Git），适合试错。试稳定后再用 `publish.ps1` 提交，避免把半成品推上去。

> 注意：`sync.ps1` 是覆盖式的，会删除服务器上本地不存在的文件；不要用它同步 `MineAdmin-Vue`（前端请走 `publish.ps1` / `update.sh`）。

### 4.3 只让服务器更新（本地不提交）

```powershell
powershell -ExecutionPolicy Bypass -File scripts\remote.ps1 update
```

等价于 SSH 上去执行 `bash deploy/update.sh`。

---

## 5. 前端构建细节

| 项 | 值 |
|---|---|
| 源码 | `MineAdmin-Vue/`（Vue 3.2.2，Vite 8，pnpm） |
| 构建命令 | `pnpm install --frozen-lockfile && pnpm build` |
| 构建产物 | `MineAdmin-Vue/dist/`（构建缓存） |
| 对外目录 | `MineAdmin/web/`（`update.sh` 会把 `dist/` 同步到这里） |
| 路由模式 | hash（`/#/login`），Nginx 仍保留 history fallback |
| API 前缀 | `/prod`（`.env.production` 的 `VITE_OPEN_PROXY=true`） |
| 静态托管 | nginx 容器挂载 `MineAdmin/web/` |
| 上传目录 | nginx 挂载 `MineAdmin/storage/uploads/` 到 `/srv/uploads/` |

### 只想手动重建前端

```bash
# 在服务器执行
cd /opt/hyperfstu
docker run --rm -v "$PWD/MineAdmin-Vue:/app" -w /app node:22-alpine \
  sh -c "corepack enable && pnpm install --frozen-lockfile && pnpm build"
mkdir -p MineAdmin/web && cp -a MineAdmin-Vue/dist/. MineAdmin/web/
```

本地也可以构建（验证语法）：

```powershell
cd D:\code\hyperfstu\MineAdmin-Vue
pnpm install --frozen-lockfile
pnpm build
```

### 本地预览前端（HMR，不占用服务器构建）

前端开发时不需要每次都发布，可以本地跑 Vite，接口通过 SSH 隧道打到线上 Swoole：

```powershell
# 窗口 1：把服务器的 127.0.0.1:9501 映射到本地 9501
powershell -ExecutionPolicy Bypass -File scripts\remote.ps1 tunnel

# 窗口 2：本地前端热更新
cd D:\code\hyperfstu\MineAdmin-Vue
pnpm dev        # http://localhost:2888
```

`.env.development` 里 `VITE_OPEN_PROXY=true`、代理前缀 `/dev`，Vite 会把 `/dev/admin/...` 转发到 `http://127.0.0.1:9501/admin/...`，也就是隧道另一端的线上后端。改 Vue 文件浏览器立即热更新；确认没问题后再 `publish.ps1` 发布构建产物。

### 修改 API 地址 / 域名

- 同域部署：保持 `/prod` 不变，换域名不用改前端。
- 前后端分域：改 `MineAdmin-Vue/.env.production` 的 `VITE_APP_API_BASEURL`，并把 `VITE_OPEN_PROXY` 设为 `false`，重新构建。
- 后端 `APP_URL` 决定上传文件返回的绝对地址；换域名后要同步修改 `MineAdmin/.env`，否则历史附件 URL 仍指向旧地址。

---

## 6. 常用运维命令

```powershell
# 容器状态 / 实时日志 / 进容器
powershell -File scripts\remote.ps1 ps
powershell -File scripts\remote.ps1 logs
powershell -File scripts\remote.ps1 shell

# 手动迁移 / 种子
powershell -File scripts\remote.ps1 migrate
powershell -File scripts\remote.ps1 seed

# 重启后端
powershell -File scripts\remote.ps1 restart

# 在容器里跑命令
powershell -File scripts\remote.ps1 exec -Command "php bin/hyperf.php list"
```

服务器上直接操作：

```bash
cd /opt/hyperfstu
docker compose -f deploy/docker-compose.yml ps
docker compose -f deploy/docker-compose.yml logs -f --tail=200 app
docker compose -f deploy/docker-compose.yml logs -f --tail=200 nginx
git log -1 --oneline
```

---

## 7. 常见问题

### 7.1 `git pull` 失败：local changes would be overwritten

服务器上的文件被直接改过（例如手工编辑），和 Git 冲突。先看：

```bash
cd /opt/hyperfstu
git status
```

学习环境可以直接丢弃服务器本地改动（确认没有重要内容）：

```bash
git reset --hard origin/main
bash deploy/update.sh --skip-pull
```

### 7.2 `Permission denied (publickey)`

私有仓库没配好 Deploy Key，或 `~/.ssh/config` 没生效。按 2.4 重配，然后：

```bash
ssh -T git@github.com
cd /opt/hyperfstu && git pull
```

公开仓库则检查 `$RepoUrl` 是否写成了 SSH 地址。

### 7.3 首页 403 / 404

`web/` 没生成，或 nginx 挂载路径不对：

```bash
ls -la /opt/hyperfstu/MineAdmin/web/index.html
ls -la /opt/hyperfstu/MineAdmin-Vue/dist/index.html
cd /opt/hyperfstu && bash deploy/update.sh --skip-pull
docker compose -f deploy/docker-compose.yml logs nginx
```

如果 `MineAdmin/web` 是空的，但 `dist` 有内容：

```bash
cd /opt/hyperfstu
mkdir -p MineAdmin/web && cp -a MineAdmin-Vue/dist/. MineAdmin/web/
```

### 7.4 登录接口 404

`MineAdmin/.env` 里 `SWAGGER_ENABLED=false`。MineAdmin 3.2 的路由由 Swagger 注解扫描注册，关掉就全 404：

```bash
sed -i 's/^SWAGGER_ENABLED=.*/SWAGGER_ENABLED=true/' /opt/hyperfstu/MineAdmin/.env
```

`server:watch` 检测到 `.env` 变化会自动重启。

### 7.5 接口 502 / 503

后端没起来：

```bash
docker compose -f deploy/docker-compose.yml logs --tail=200 app
```

常见原因：`composer install` 没跑完、`.env` 的数据库密码和 `deploy/.env` 不一致、MySQL 还没 healthy。

### 7.6 `composer.lock` 和 PHP 版本

仓库里的 `composer.lock` 已经按 **PHP 8.3** 重新生成（`composer.json` 里加了 `config.platform.php = 8.3.0`），服务器只执行 `composer install`，不会改写锁文件。

如果你在本地用 PHP 8.4 跑 `composer update`，可能又把 Symfony 8（要求 PHP >= 8.4）拉进来，服务器 8.3 就跑不了。保持 `config.platform.php` 为 8.3.0，或者用：

```powershell
composer update --no-install --ignore-platform-req=ext-* --no-scripts
```

另外 `hyperf/utils` 在锁文件里是 `3.2.x-dev`（上游没有 3.2 稳定 tag），但已固定到具体 commit，服务器 `composer install` 结果可复现，不用管。

### 7.7 80 端口被占用

改 `deploy/.env` 的 `WEB_PORT=8080`，同步修改 `MineAdmin/.env` 的 `APP_URL=http://服务器IP:8080`，然后：

```bash
bash deploy/update.sh --skip-pull
```

### 7.8 前端改了但页面没变

`update.sh` 通过「源码文件是否比 `dist/index.html` 新」判断是否构建。如果时间戳异常（比如整仓复制），强制重建：

```bash
cd /opt/hyperfstu
rm -rf MineAdmin-Vue/dist
bash deploy/update.sh --skip-pull
cp -a MineAdmin-Vue/dist/. MineAdmin/web/
```

浏览器强刷 `Ctrl+F5`。

### 7.9 磁盘占用

`composer install`、`pnpm install`、Docker 镜像会占几个 GB。定期：

```bash
docker system df
docker image prune -f
docker builder prune -f
```

---

## 8. 这套方案的关键文件

| 文件 | 作用 |
|---|---|
| `.gitignore` | 排除 `.env`、`vendor/`、`dist/`、`web/`、`node_modules/` |
| `deploy/docker-compose.yml` | app + nginx + mysql + redis |
| `deploy/nginx/default.conf` | 静态站、`/prod` 反代、`/uploads` 直读、`/__echo` 回显 |
| `deploy/bt/nginx-site.conf` | **宝塔**站点配置片段（粘到面板站点里） |
| `deploy/update.sh` | 服务器端更新总入口（按 `USE_DOCKER_NGINX` 决定是否启动 docker nginx） |
| `deploy/native/install.sh` | 原生安装：composer + migrate + seed + 前端 |
| `deploy/native/update.sh` | 原生日常更新（git pull → 依赖 → 迁移 → 前端 → 重启） |
| `deploy/native/manage.sh` | 原生进程管理：start / stop / restart / reload / logs / watch |
| `scripts/bootstrap-native.ps1` | 原生一键部署（写 .env + 远程 install） |
| `scripts/bootstrap.ps1` | 首次 clone + 生成 .env + 初始化（宝塔加 `-BtPanel`） |
| `scripts/publish.ps1` | 本地提交推送 + 触发服务器更新 |
| `scripts/sync.ps1` | 不提交的快速草稿同步 |
| `scripts/proxy.ps1` | 发一个请求并打印响应头/响应体，验证代理链路 |
| `scripts/remote.ps1` | 日志 / shell / 迁移 / 手动更新 |
