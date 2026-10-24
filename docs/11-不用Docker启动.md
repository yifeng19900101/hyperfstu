# 11 不用 Docker 启动（宝塔原生 PHP）

> 服务器还是用宝塔面板，但不跑 docker：**PHP 由宝塔安装、MySQL/Redis 由宝塔提供、Nginx 由宝塔管理**，Hyperf 用宝塔的 PHP 直接以 Swoole 模式常驻。
>
> 本篇接 [10-宝塔面板部署](10-宝塔面板部署.md)。区别只是把 `app` 容器换成了宿主机上的一个 PHP 进程，Nginx 配置完全一样。

> 本篇示例目录统一写 `/opt/hyperfstu`。宝塔建站时默认是 `/www/wwwroot/hyperfstu` 这类路径，两者都行（脚本的 `RemotePath` 校验同时支持 `/opt`、`/srv`、`/var/www`、`/home`、`/root`、`/www`），照着你自己的实际路径替换即可。

---

## 1. 两种跑法对比

| | Docker（08/10 文档） | 原生（本篇） |
|---|---|---|
| PHP / Swoole | 官方镜像，自带 | 宝塔安装的 PHP 8.3 + swoole 扩展 |
| MySQL | 容器 `mysql:8.0` | 宝塔「数据库」 |
| Redis | 容器 `redis:7` | 宝塔「软件商店 → Redis」 |
| Nginx | 面板 Nginx（宝塔模式） | 面板 Nginx（一样） |
| 启动 | `docker compose up -d` | `manage.sh start` 或宝塔「进程守护管理器」 |
| 热更新 | `server:watch` 容器内跑 | `manage.sh watch` 宿主机跑 |
| 升级 PHP | 换镜像 | 面板换 PHP 版本 |
| 隔离性 | 好 | 一般（和面板其他站点共用 PHP） |
| 内存占用 | 高（多一套 MySQL/Redis） | 低 |

学习阶段推荐 **原生**：少一层抽象，`ps`、`strace`、`php --ri swoole` 都能直接看到，调 Swoole 参数更直观。

---

## 2. 一键装（推荐路径）

前提：服务器上已经 git clone 了仓库（`scripts/bootstrap.ps1` 第 2 步做过就行，或者手动 clone），宝塔里已建好数据库。

```powershell
# 本地：生成 .env + 装依赖 + 迁移 + 灌数据 + 构建前端 + 启动
powershell -ExecutionPolicy Bypass -File scripts\bootstrap-native.ps1 `
    -DbUser mineadmin -DbPassword '你的数据库密码' `
    -RedisAuth '你的Redis密码' `
    -Domain example.com
```

参数说明：

| 参数 | 默认 | 说明 |
|---|---|---|
| `-DbHost` / `-DbPort` | `127.0.0.1` / `3306` | 宝塔 MySQL |
| `-DbName` / `-DbUser` | 从已有 .env 读，否则 `mineadmin` | 宝塔「数据库」里建的 |
| `-DbPassword` | 无（必填） | 已有 .env 时可省略 |
| `-RedisHost` / `-RedisPort` / `-RedisAuth` | `127.0.0.1` / `6379` / 空 | 宝塔 Redis |
| `-Domain` | 空 = 用服务器 IP | 写进 `APP_URL`，影响上传文件返回的绝对地址 |
| `-PhpBin` | `/www/server/php/83/bin/php` | 宝塔 PHP 路径 |
| `-SkipFrontend` | 否 | 服务器没 Node 时先跳过 |
| `-SkipStart` | 否 | 只装不启动（之后交给进程守护） |
| `-Force` | 否 | 完全重建 .env（会换 JWT_SECRET，所有人要重新登录） |

脚本会依次执行：检查 PHP/扩展 → clone/pull → 写 `MineAdmin/.env` → `deploy/native/install.sh` → `manage.sh start` → 健康检查。

装完还差**建站反代**这一步，见第 7 节。

---

## 3. 手动装（了解每一步在干什么）

### 3.1 装 PHP 8.3

宝塔 → 软件商店 → 安装 **PHP 8.3**（不能是 8.1：`composer.json` 要求 `php >= 8.2`）。

点 PHP 8.3 → 设置 → **安装扩展**，至少要有：

| 扩展 | 用途 |
|---|---|
| `swoole`（>= 5.0） | Hyperf 的运行时 |
| `redis`（phpredis） | `hyperf/redis` 依赖 `ext-redis` |
| `pdo_mysql` | 数据库 |
| `fileinfo` `json` `openssl` `mbstring` | 框架/上传/HTTPS |

宝塔扩展列表里如果有 **swoole5**，直接点安装最省事。没有的话编译：

```bash
yum install -y gcc gcc-c++ make autoconf openssl-devel curl-devel
/www/server/php/83/bin/pecl install swoole
# 交互里除 "enable openssl support?" 选 yes，其余回车用默认
```

然后把两行写进 `/www/server/php/83/etc/php.ini`：

```ini
extension=swoole.so
; Hyperf 启动时强校验这一项，不是 Off 会直接退出
swoole.use_shortname=Off
```

验证：

```bash
/www/server/php/83/bin/php -v
/www/server/php/83/bin/php -m | grep -Ei 'swoole|redis|pdo_mysql|fileinfo|mbstring'
/www/server/php/83/bin/php --ri swoole | head -20
/www/server/php/83/bin/php -r 'var_dump(ini_get("swoole.use_shortname"));'
```

> ⚠️ 一定要用**绝对路径** `/www/server/php/83/bin/php`。服务器上通常还有系统的 `php`（可能是 7.4），`php -v` 显示的很可能不是宝塔那个。

### 3.2 改 php.ini 的几个值

```ini
memory_limit = 512M
max_execution_time = 300
date.timezone = Asia/Shanghai
```

再到 设置 → **禁用函数**，把这些删掉（宝塔默认禁了，Swoole/Supervisor/composer 会踩到）：

```
putenv  getenv  proc_open  popen
pcntl_alarm  pcntl_fork  pcntl_waitpid  pcntl_wait
pcntl_signal  pcntl_signal_dispatch  pcntl_getpriority  pcntl_setpriority
```

> ⚠️ **`putenv` / `getenv` 必须可用**，否则 Hyperf 连启动都到不了：
>
> ```
> PHP Fatal error: Uncaught RuntimeException: None has no value.
>   in vendor/phpoption/phpoption/src/PhpOption/None.php:45
> #0 vendor/hyperf/support/src/DotenvManager.php(73): PhpOption\None->get()
> #1 vendor/hyperf/support/src/DotenvManager.php(60): ...getAdapter()
> ```
>
> 原因：`phpdotenv` 的 `PutenvAdapter::create()` 会判断 `function_exists('getenv') && function_exists('putenv')`，任一被禁用就返回 `None`，而 Hyperf 对这个 `None` 调了 `->get()`。报错和 `.env`、数据库都无关，别去查配置。
>
> 修好之后验证（两条都得是 `bool(true)`）：
>
> ```bash
> php -r 'var_dump(function_exists("putenv"), function_exists("getenv"));'
> ```

改完在面板里保存，会重载 PHP-FPM（CLI 下次执行就是新配置）。

### 3.3 建数据库

宝塔 → 数据库 → 添加数据库：库名 `mineadmin`，用户 `mineadmin`，记下密码，字符集 `utf8mb4`。

宝塔建的用户是 `'mineadmin'@'localhost'`。如果 MySQL 开了 `skip-name-resolve`，用 `127.0.0.1` 连接会匹配不上，补一条授权：

```sql
CREATE USER IF NOT EXISTS 'mineadmin'@'127.0.0.1' IDENTIFIED BY '你的密码';
GRANT ALL PRIVILEGES ON `mineadmin`.* TO 'mineadmin'@'127.0.0.1';
FLUSH PRIVILEGES;
```

验证：

```bash
mysql -h 127.0.0.1 -u mineadmin -p mineadmin -e 'select 1;'
```

### 3.4 Redis

宝塔 → 软件商店 → Redis → 设置。默认 `bind 127.0.0.1`、无密码，够用。

如果设了密码，`.env` 里的 `REDIS_AUTH` 要填上，否则启动后第一次读缓存就报 `NOAUTH Authentication required`。

```bash
redis-cli -h 127.0.0.1 -a '你的密码' ping   # 应返回 PONG
```

### 3.5 拉代码

```bash
mkdir -p /opt && cd /opt
git clone https://github.com/你的用户名/hyperfstu.git
cd hyperfstu
```

（如果 `scripts/bootstrap.ps1` 已经跑过，直接 `cd /opt/hyperfstu && git checkout main && git pull --ff-only origin main`。）

### 3.6 写 `MineAdmin/.env`

```bash
cd /opt/hyperfstu/MineAdmin
cp .env.example .env
openssl rand -base64 64          # 生成的字符串填到 JWT_SECRET
vi .env
```

关键项：

```ini
APP_NAME=MineAdmin
APP_ENV=prod
APP_DEBUG=false

# MineAdmin 3.2 的路由靠注解扫描注册，关掉的话 /admin/* 全部 404
SWAGGER_ENABLED=true
SWAGGER_AUTO_GENERATE=false

DB_DRIVER=mysql
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=mineadmin
DB_USERNAME=mineadmin
DB_PASSWORD=你的数据库密码
DB_CHARSET=utf8mb4
DB_COLLATION=utf8mb4_unicode_ci
DB_PREFIX=

REDIS_HOST=127.0.0.1
REDIS_PORT=6379
REDIS_AUTH=
REDIS_DB=0

APP_URL=http://example.com
JWT_SECRET=上一步生成的值

# 只监听本机，公网只能通过 Nginx 进来
SERVER_HOST=127.0.0.1
```

`SERVER_HOST` 是本仓库给 `config/autoload/server.php` 加的开关（默认 `0.0.0.0`，docker 用）。设成 `127.0.0.1` 后 `9501` 不对外，少一个绕过 Nginx 的口子。

```bash
chmod 600 .env
```

### 3.7 装依赖 + 初始化

```bash
cd /opt/hyperfstu
bash deploy/native/install.sh --php-bin=/www/server/php/83/bin/php
```

它做的事（等价于下面几条命令）：

```bash
cd /opt/hyperfstu/MineAdmin
composer install --no-interaction --prefer-dist -o     # 首次
rm -rf runtime/container                              # 清注解/DI 缓存
php bin/hyperf.php migrate --force
php bin/hyperf.php db:seed --path=databases/seeders --force   # 只跑一次！
chown -R www:www runtime storage web
chmod -R o+rX web storage/uploads
```

`db:seed` 会灌菜单和默认账号 `admin / 123456`。**只能跑一次**，重复跑会插重复菜单；所以脚本用 `.deploy/native-installed` 做了标记，`update.sh` 不会重复 seed。

---

## 4. 启动

### 4.1 前台跑（第一次排查问题用这个）

```bash
cd /opt/hyperfstu/MineAdmin
/www/server/php/83/bin/php bin/hyperf.php start
```

看到 `Server started, listening on 127.0.0.1:9501` 之类的输出就成功了，`Ctrl+C` 停止。

> Hyperf 3.2 的 `start` **没有 `-d` 参数**（网上老教程里的 `start -d` 会报 option 不存在）。后台运行见下面两种。

另开一个窗口验证：

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST \
  -H 'Content-Type: application/json' -d '{}' \
  http://127.0.0.1:9501/admin/passport/login
# 422 = 正常（参数校验失败）
```

### 4.2 脚本后台跑

```bash
bash /opt/hyperfstu/deploy/native/manage.sh start     # 自动用 www 用户 + nohup
bash /opt/hyperfstu/deploy/native/manage.sh status
bash /opt/hyperfstu/deploy/native/manage.sh logs 200
bash /opt/hyperfstu/deploy/native/manage.sh restart
bash /opt/hyperfstu/deploy/native/manage.sh stop
```

PID 写在 `MineAdmin/runtime/hyperf.pid`，启动输出在 `MineAdmin/runtime/logs/native-start.log`。

### 4.3 宝塔「进程守护管理器」（长期推荐）

前面两种方式在 SSH 断开、服务器重启后就没了。生产用 Supervisor 托管：

1. 先停掉脚本启动的实例：`bash deploy/native/manage.sh stop`
2. 宝塔 → 软件商店 → 安装 **进程守护管理器**（Supervisor）
3. 添加守护进程：

| 字段 | 填什么 |
|---|---|
| 名称 | `mineadmin` |
| 启动用户 | `www` |
| 运行目录 | `/opt/hyperfstu/MineAdmin` |
| 启动命令 | `/www/server/php/83/bin/php /opt/hyperfstu/MineAdmin/bin/hyperf.php start` |
| 进程数量 | `1` |

参考配置也在 `deploy/native/supervisor.conf`。要点：

- 命令**不要**加 `&` 或 `-d`，Hyperf 本来就前台跑，由 Supervisor 看着
- 进程数量必须是 **1**，worker 由 Swoole 自己 fork
- 启动用户 `www`，和 `runtime/`、`storage/` 的属主一致

### 4.4 systemd（可选）

```ini
# /etc/systemd/system/mineadmin.service
[Unit]
Description=MineAdmin (Hyperf)
After=network.target mysql.service redis.service

[Service]
Type=simple
User=www
WorkingDirectory=/opt/hyperfstu/MineAdmin
ExecStart=/www/server/php/83/bin/php /opt/hyperfstu/MineAdmin/bin/hyperf.php start
Restart=always
RestartSec=3
KillMode=mixed
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
```

```bash
systemctl daemon-reload
systemctl enable --now mineadmin
journalctl -u mineadmin -f
```

---

## 5. 热更新（改代码立刻看效果）

```bash
bash /opt/hyperfstu/deploy/native/manage.sh watch
# 或本地：
powershell -File scripts\remote.ps1 -Native watch
```

`server:watch` 来自 `hyperf/watcher`（`require-dev`），监听 `app/`、`config/` 等目录，改动后自动重启 worker。规则：

| 改了什么 | 需要做什么 |
|---|---|
| `app/` 里的 PHP | watch 自动生效，或 `manage.sh reload`（SIGUSR1 重载 worker） |
| `config/`、`.env`、`composer.json` | 必须 `manage.sh restart` |
| 前端 `MineAdmin-Vue/src` | `pnpm dev`（本地开发服务器，自带 HMR）；或重新 build |
| 新增注解/路由 | 建议 `restart`，注解扫描只在启动时做 |

> watch 只适合学习环境。`composer install --no-dev` 之后 `server:watch` 命令不存在，这是正常的。

---

## 6. 前端

前端产物必须落到 `MineAdmin/web`（Nginx 的站点根目录）。两种方式：

**A. 服务器上构建**（`install.sh` / `update.sh` 默认尝试）

```bash
bash /opt/hyperfstu/deploy/native/update.sh --skip-pull
```

脚本会自动找 `/www/server/nodejs/*/bin` 并 `corepack` 启用 pnpm。也可以先在宝塔「Node.js 版本管理器」装 Node 22：

```bash
node -v && pnpm -v
cd /opt/hyperfstu/MineAdmin-Vue
pnpm install --frozen-lockfile && pnpm build
rm -rf ../MineAdmin/web && mkdir -p ../MineAdmin/web
cp -a dist/. ../MineAdmin/web/
```

**B. 本地构建后上传**

```powershell
cd D:\code\hyperfstu\MineAdmin-Vue
pnpm install --frozen-lockfile
pnpm build
# 上传（示例，路径按需改）
scp -r dist/* root@你的服务器:/opt/hyperfstu/MineAdmin/web/
```

`.env.production` 里的 `VITE_OPEN_PROXY=true` + `VITE_PROXY_PREFIX=/prod` 决定了浏览器请求 `/prod/...`，所以 Nginx 必须有那个 `location ^~ /prod/`。

---

## 7. Nginx（复用 10 的配置，一字不用改）

宝塔 → 网站 → 添加站点：

| 项 | 值 |
|---|---|
| 域名 | 你的域名 / 临时用服务器 IP |
| PHP 版本 | **纯静态** |
| 网站目录 | `/opt/hyperfstu/MineAdmin/web` |
| 伪静态 | 无 |

然后把 `deploy/bt/nginx-site.conf` 的内容粘进这个站点的 `server { }` 里（网站 → 设置 → 配置文件）。核心还是：

```nginx
location ^~ /prod/ {
    proxy_pass http://127.0.0.1:9501/;   # 尾斜杠必须写，否则后端收到 /prod/...
    proxy_set_header Host              $host;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Prefix /prod;
}
```

注意 `^~`：宝塔站点自带 `location ~ .*\.(png|jpg)$` 这种正则，普通前缀会被抢走。

```bash
chmod o+x /opt /opt/hyperfstu /opt/hyperfstu/MineAdmin
chmod -R o+rX /opt/hyperfstu/MineAdmin/web /opt/hyperfstu/MineAdmin/storage/uploads
/www/server/nginx/sbin/nginx -t && /www/server/nginx/sbin/nginx -s reload
```

验证（服务器上不止一个站点时记得带 `Host`）：

```bash
curl -s "http://127.0.0.1/prod/admin/proxy/debug?page=2" -H "Host: example.com"
# path 应该是 /admin/proxy/debug，ip.getClientIps 是真实公网 IP
```

---

## 8. 和 Docker 版本共存的注意事项

- **9501 只能有一个主人**。切到原生前先 `docker compose -f deploy/docker-compose.yml down`，否则 `Address already in use`。
- Docker 的 MySQL/Redis 映射在 `127.0.0.1:13306/16379`，和宝塔的 `3306/6379` 不冲突，可以同时开，但没必要。
- `MineAdmin/.env` 是**共用**的：docker 模式需要 `DB_HOST=mysql`、`REDIS_HOST=redis`、`SERVER_HOST=0.0.0.0`；原生需要 `127.0.0.1`。来回切记得改。
- 两套部署脚本互不影响：`deploy/update.sh`（docker）、`deploy/native/update.sh`（原生）。

---

## 9. 日常发布

```powershell
# 本地提交推送 + 服务器原生更新（git pull -> composer -> migrate -> 前端 -> 重启）
powershell -ExecutionPolicy Bypass -File scripts\publish.ps1 -Native -Message "feat: xxx"
```

```bash
# 服务器上手动（全程只用 main）
cd /opt/hyperfstu
git checkout main
git pull --ff-only origin main
bash deploy/native/update.sh --skip-pull
```

原生模式的 `update.sh` 流程：

1. 校验当前分支是 `main`，然后 `git pull --ff-only origin main`
2. `composer.lock` 比 `vendor/composer/installed.json` 新才 install
3. `rm -rf runtime/container`
4. `migrate --force`
5. 前端有变化就 build 并同步到 `MineAdmin/web`
6. `chown www runtime storage web`
7. `manage.sh restart`

> Supervisor 托管时，`manage.sh restart` 会先 `kill -TERM` 再由 Supervisor 拉起，`autorestart` 有没有都行。更稳的做法是更新时 `supervisorctl restart mineadmin`；用脚本也行，只是会有一次 Supervisor 的 restart 计数。

---

## 10. 日志与排错

| 位置 | 内容 |
|---|---|
| `MineAdmin/runtime/logs/hyperf*.log` | 应用日志（异常、SQL 慢查询） |
| `MineAdmin/runtime/logs/native-start.log` | `manage.sh start` 的标准输出/启动错误 |
| `MineAdmin/runtime/logs/supervisor.log` | Supervisor 托管时的输出 |
| `MineAdmin/runtime/hyperf.pid` | 主进程 PID |
| `/www/wwwlogs/<域名>.error.log` | Nginx 错误 |

### 10.1 先跑自检

不确定坏在哪一层时，先跑这个（只读，不改任何东西）：

```bash
bash /www/wwwroot/hyperfstu/deploy/native/doctor.sh
# 或指定 PHP
bash deploy/native/doctor.sh --php-bin=/www/server/php/83/bin/php
```

它会逐项检查：PHP 路径/版本/实际加载的 ini、`putenv`/`getenv` 是否可用、扩展（swoole/redis/pdo_mysql/fileinfo/json/openssl/mbstring）、`swoole.use_shortname`、`.env` 里 `SWAGGER_ENABLED`/`SERVER_HOST` 等关键值、`vendor/` 和 `web/index.html` 是否存在、目录属主、MySQL/Redis 连通性、9501 监听状态。最后给出 `[OK]` / `[WARN]` / `[FAIL]` 汇总。

### 10.2 三层定位法

```bash
# ① 进程活着吗
bash /opt/hyperfstu/deploy/native/manage.sh status
ss -lntp | grep 9501

# ② 后端能直连吗（无 /prod 前缀）
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: application/json' \
  -d '{}' http://127.0.0.1:9501/admin/passport/login      # 422 正常

# ③ 经过 Nginx 呢
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: application/json' \
  -d '{}' -H 'Host: example.com' http://127.0.0.1/prod/admin/passport/login
```

### 常见错误

| 现象 | 原因 / 处理 |
|---|---|
| `RuntimeException: None has no value`（`phpoption/None.php`，调用栈里是 `DotenvManager::getAdapter`） | **`putenv` / `getenv` 被禁用**。宝塔 PHP 设置 → 禁用函数 里删掉这两项。与 `.env`、数据库无关 |
| `ERROR Swoole short function names must be disabled...` | php.ini 加 `swoole.use_shortname=Off` |
| `Class "Swoole\Coroutine" not found` | 用错了 PHP（系统 7.4）。全用绝对路径 |
| 启动卡住不动，无输出 | 正常，前台常驻。`Ctrl+C` 退出 |
| `Address already in use (9501)` | 旧进程或 docker app 还在：`manage.sh stop` + `docker compose down` |
| 502 Bad Gateway | 9501 没进程：`manage.sh logs` / `native-start.log` |
| 所有 `/admin/*` 404 | `.env` 里 `SWAGGER_ENABLED=false`；改成 true 后 restart |
| `SQLSTATE[HY000] [1045] Access denied` | DB 用户/密码/host 不对，见 3.3 的 `'127.0.0.1'` 授权 |
| `NOAUTH Authentication required` | Redis 有密码但 `REDIS_AUTH` 为空 |
| `Permission denied` 写 `runtime/` | `chown -R www:www runtime storage web` |
| `composer install` 卡在 GitHub | 换阿里云镜像：`composer config -g repo.packagist composer https://mirrors.aliyun.com/composer/` |
| `The Process class relies on proc_open, which is disabled` | 宝塔「禁用函数」里删掉 `proc_open` |
| 上传 >10M 报错 | 三处一起改：Nginx `client_max_body_size`、`config/autoload/server.php` 里的 `OPTION_UPLOAD_MAX_FILESIZE`（默认 10M）和 `OPTION_PACKAGE_MAX_LENGTH`（默认 4M） |
| 改了代码没生效 | `SCAN_CACHEABLE`/注解缓存：`rm -rf runtime/container && manage.sh restart` |
| 前端刷新 404 | 路由是 hash 模式，正常不会；如果改成了 history，需要 `try_files $uri $uri/ /index.html` |

---

## 11. 检查清单

- [ ] 宝塔装了 PHP 8.3，`/www/server/php/83/bin/php -v` 正常
- [ ] `php -m` 有 swoole(>=5.0) / redis / pdo_mysql / fileinfo / json / openssl / mbstring
- [ ] `function_exists('putenv') && function_exists('getenv')` 都是 true（否则报 `None has no value`）
- [ ] `swoole.use_shortname=Off`，`disable_functions` 里没有 `proc_open` / `pcntl_*`
- [ ] 宝塔数据库 `mineadmin` 可连；Redis `ping` 返回 PONG
- [ ] `MineAdmin/.env`：`APP_ENV=prod`、`SWAGGER_ENABLED=true`、`SERVER_HOST=127.0.0.1`、DB/Redis 都是 `127.0.0.1`
- [ ] `composer install` 成功，`vendor/autoload.php` 存在
- [ ] `migrate --force` 成功，`.deploy/native-installed` 已生成（seed 只跑一次）
- [ ] `MineAdmin/web/index.html` 存在（前端已构建）
- [ ] `manage.sh status` 显示运行中；`curl 127.0.0.1:9501` 返回 422
- [ ] 宝塔站点：纯静态 + 根目录 `MineAdmin/web` + `location ^~ /prod/` 带尾斜杠
- [ ] 9501 只监听 `127.0.0.1`；安全组/防火墙不放行 9501
- [ ] 用 Supervisor 托管时，`numprocs=1`、用户 `www`、命令不带 `-d`
- [ ] 上线前删掉 `ProxyDebugController` 和 Nginx 里的 `/__echo`
