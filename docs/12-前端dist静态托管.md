# 12 前端 dist 静态托管（提交产物 + 域名直接指向 dist）

目标：**在本地构建前端，把 `MineAdmin-Vue/dist` 提交到仓库；服务器只 `git pull`，Nginx 的站点根目录直接指向这个 `dist`。** 服务器不装 Node、不跑构建。

适用场景：服务器只当静态空间用、不想在服务器上折腾 Node，或者前端改动不频繁、希望「推送即生效」。

---

## 1. 和「服务器构建」的区别

| | 服务器构建（旧） | dist 提交（本篇） |
|---|---|---|
| 产物在哪 | 服务器 build 出的 `MineAdmin-Vue/dist` → 复制到 `MineAdmin/web` | 仓库里的 `MineAdmin-Vue/dist`，就是站点根目录 |
| 站点根目录 | `MineAdmin/web` | `MineAdmin-Vue/dist` |
| 服务器需要 Node | 需要（Node 22 + pnpm） | **不需要** |
| 发布耗时 | 每次几分钟（install + build） | 一次 `git pull`，秒级 |
| 谁构建 | 服务器 | 你的 Windows 机器 |
| 仓库体积 | 小 | 每次前端改动 +几 MB（只有变化的 chunk） |

开关在 `deploy/.env`：

```ini
# repo  = dist 在仓库里，服务器只 pull（本篇）
# build = 服务器构建
FRONTEND_MODE=repo
```

> ⚠️ **`FRONTEND_MODE=repo` 时服务器绝对不能再构建。** 一旦在服务器上跑 `pnpm build`，`dist` 就变成未提交的修改，下次 `git pull --ff-only` 会直接失败（`local changes would be overwritten`）。脚本已经按这个前提写死：`update.sh` / `native/update.sh` 在 repo 模式下只检查 `dist/index.html` 存在，不执行任何构建命令。

---

## 2. 一次性改造（仓库侧，已经做好）

这些改动已经提交，列出来是为了你知道为什么：

| 文件 | 改了什么 |
|---|---|
| `MineAdmin-Vue/.gitignore` | 去掉 `dist*`，只忽略 `dist.zip` / `dist-*.tar.gz` 这类存档 |
| `.gitignore`（根） | 去掉 `MineAdmin-Vue/dist/` |
| `.gitattributes`（新增） | `MineAdmin-Vue/dist/** -text -diff` —— 不让 Git 碰换行符，避免破坏产物；`*.sh text eol=lf` 防止 CRLF 传到 Linux |
| `MineAdmin-Vue/.env.production` | `VITE_BUILD_COMPRESS =` 置空：预压缩会让文件数翻三倍、每次构建都产生新 blob，改为 Nginx 实时 gzip |
| `deploy/.env.example` | 新增 `FRONTEND_MODE=repo` |
| `deploy/update.sh`、`deploy/native/lib.sh` | repo 模式跳过构建；站点根目录统一为 `MineAdmin-Vue/dist`，不再复制到 `MineAdmin/web` |
| `deploy/docker-compose.yml` | nginx 挂载 `../MineAdmin-Vue/dist` |
| `deploy/bt/nginx-site.conf` | 站点目录说明改为 `dist`；新增 `gzip` 配置和 `/font/` 缓存 |
| `scripts/publish.ps1` | 新增 `-BuildFrontend`：发布前在本地构建 |

产物现状：**215 个文件、约 9.2 MB**（关掉预压缩后）。

### 2.1 老服务器的一次性迁移

以前 `dist` 是被忽略的本地构建产物。服务器上如果已经有这个目录（未跟踪），直接 `git pull` 会失败：

```
error: Untracked working tree files would be overwritten by merge:
        MineAdmin-Vue/dist/index.html
```

`deploy/update.sh` 和 `deploy/native/update.sh` 已经加了保护：拉代码前如果发现 `dist` 存在但**还没被 HEAD 跟踪**，会先 `rm -rf` 它，让 Git 接管。你也可以手动来一遍：

```bash
cd /www/wwwroot/hyperfstu
git ls-files MineAdmin-Vue/dist | head -1     # 没有输出 = 还没被跟踪
rm -rf MineAdmin-Vue/dist                      # 放心删，产物在仓库里
git pull --ff-only origin main
ls MineAdmin-Vue/dist/index.html              # 应该存在
```

---

## 3. 日常发布流程

### 3.1 只改后端

```powershell
powershell -ExecutionPolicy Bypass -File scripts\publish.ps1 -Native -Message "fix: xxx"
```

不碰前端，产物不变。

### 3.2 改了前端

```powershell
# -BuildFrontend：先在本地 pnpm build，再把 dist 一起提交
powershell -ExecutionPolicy Bypass -File scripts\publish.ps1 -Native -BuildFrontend -Message "feat: 新页面"
```

等价的手动流程：

```powershell
cd D:\code\hyperfstu\MineAdmin-Vue
pnpm install --frozen-lockfile   # 依赖没变可跳过
pnpm build

cd D:\code\hyperfstu
git add MineAdmin-Vue/dist
git commit -m "build: 前端产物"
git push origin main

# 服务器
ssh root@服务器IP "cd /www/wwwroot/hyperfstu && bash deploy/native/update.sh --php-bin=/www/server/php/83/bin/php"
```

服务器端 `update.sh` 会 `git pull --ff-only origin main`，然后：
- repo 模式：确认 `dist/index.html` 存在 → 直接用
- 不碰 `dist` 里的任何文件

### 3.3 提交前自检

```powershell
cd D:\code\hyperfstu

# 1. dist 是否被正确跟踪（应该看到一堆 MineAdmin-Vue/dist/...）
git status --short MineAdmin-Vue/dist | Select-Object -First 5

# 2. 确认没有被忽略
git check-ignore -v MineAdmin-Vue/dist/index.html   # 应该没有输出

# 3. 确认 API 前缀被正确烘焙（应输出 /hyperfproapi 附近的内容）
Select-String -Path MineAdmin-Vue\dist\static\js\*.js -Pattern 'VITE_PROXY_PREFIX' -List
```

---

## 4. 宝塔建站：域名直接指向 dist

宝塔 → 网站 → 添加站点：

| 项 | 值 |
|---|---|
| 域名 | `example.com`（可以再加 `www.example.com`） |
| 根目录 | **`/www/wwwroot/hyperfstu/MineAdmin-Vue/dist`** |
| PHP 版本 | **纯静态** |
| 伪静态 | 无 |
| 数据库 / FTP | 都不创建 |

这份目录就是「dist 空间」，Nginx 直接读文件，不经过任何 PHP/容器。

然后：网站 → 设置 → 配置文件，把 `deploy/bt/nginx-site.conf` 的内容粘进 `server { }`（**不要整个替换**，否则会丢掉宝塔生成的 SSL / 日志配置）。

里面只有一条反代需要你确认路径：

```nginx
location ^~ /hyperfproapi/ {
    proxy_pass http://127.0.0.1:9501/;   # 尾斜杠必须写
    ...
}
```

权限（宝塔 nginx 以 `www` 运行）：

```bash
chmod o+x /www /www/wwwroot /www/wwwroot/hyperfstu /www/wwwroot/hyperfstu/MineAdmin-Vue
chmod -R o+rX /www/wwwroot/hyperfstu/MineAdmin-Vue/dist
chmod -R o+rX /www/wwwroot/hyperfstu/MineAdmin/storage/uploads
```

验证：

```bash
/www/server/nginx/sbin/nginx -t && /www/server/nginx/sbin/nginx -s reload

# 站点根目录生效了吗
curl -sI http://127.0.0.1/ -H "Host: example.com" | head -5      # 200 + text/html
curl -s  http://127.0.0.1/ -H "Host: example.com" | grep -o 'static/js/[^"]*' | head -3

# 反代通不通
curl -s "http://127.0.0.1/hyperfproapi/admin/proxy/debug" -H "Host: example.com"
```

---

## 5. 路由模式：为什么不需要 SPA fallback

`.env.production` 里 `VITE_APP_ROUTE_MODE = hash`，URL 形如 `https://example.com/#/admin/user`。

`#` 后面的部分**不会发给服务器**，所以：

- 刷新任意页面，请求的都是 `/`（`index.html`）——不会 404
- 不需要 `try_files $uri $uri/ /index.html`
- 也就不需要为 SPA 额外配 rewrite

如果你改成 `history` 模式，必须补一条：

```nginx
location / {
    try_files $uri $uri/ /index.html;
}
```

并且 `index.html` 的 `Cache-Control` 必须保持 `no-cache`（片段里已经配了），否则发布后浏览器还在跑旧路由表。

---

## 6. 缓存策略

`dist` 里的文件名带内容 hash，所以可以放心长缓存：

| 路径 | 缓存 | 原因 |
|---|---|---|
| `/static/` | 30 天 + immutable | 文件名带 hash，内容变了文件名就变 |
| `/font/` | 30 天 + immutable | 字体不会变 |
| `/favicon.ico` `logo.svg` | 7 天 | 固定文件名 |
| `/index.html` | `no-cache, no-store` | 它是「资源清单」，必须每次拿新的 |

这套策略是「发布后用户立刻看到新版」的关键：`index.html` 不缓存 → 拿到新的 hash → 新资源自然加载。

宝塔若另开了「网站加速」/ CDN，要单独清缓存。

---

## 7. 仓库体积与历史

每次前端改动只会新增**变化的 chunk**（未变的文件内容相同，hash 相同，Git 自动复用），所以增量和改动量成正比，不是每次 +9MB。

如果哪天觉得历史太大：

```bash
# 只保留最近一次构建的 dist（把历史里的旧产物清掉）
git filter-repo --path MineAdmin-Vue/dist --invert-paths
# 然后重新提交一份干净的 dist
```

> `git filter-repo` 会重写全部历史，需要 force push。学习仓库一般用不到。

另一个选择：把 `dist` 打包成单个 `dist.zip` 提交，服务器上解压。这样历史里每次只有一个二进制文件（无法增量复用，反而更容易膨胀），**不推荐**。

---

## 8. 和 Docker 模式一起用

`deploy/docker-compose.yml` 里 nginx 已经挂载 `../MineAdmin-Vue/dist`，所以：

```ini
USE_DOCKER_NGINX=1
FRONTEND_MODE=repo
```

`docker compose up -d app nginx` 之后，容器里的 nginx 直接读宿主机的 `dist`，行为跟宝塔模式完全一致。

---

## 9. 常见问题

| 现象 | 原因 / 处理 |
|---|---|
| `git pull` 报 `local changes would be overwritten by merge: MineAdmin-Vue/dist/...` | 服务器上有人/脚本跑过 build。`cd 项目 && git checkout -- MineAdmin-Vue/dist && git pull --ff-only origin main`，并把 `FRONTEND_MODE` 确认为 `repo` |
| 首页 403 | `www` 读不到 dist。按第 4 节补 `chmod o+rX`，用 `namei -l .../dist/index.html` 逐级查 |
| 首页 404 / 目录列表 | 网站目录没指到 `MineAdmin-Vue/dist` |
| 页面能开但接口 404 | `/hyperfproapi` 的 `proxy_pass` 少了尾斜杠，或用了 `location /hyperfproapi/` 而不是 `^~` |
| 接口打到了 `http://hyperf:9501` | 这个包是在别的环境构建的（`VITE_OPEN_PROXY` 不是 true）。本地重新 `pnpm build` 覆盖 dist |
| 发布后仍是旧页面 | `index.html` 被缓存。检查 `curl -sI .../index.html` 的 `Cache-Control`，或清 CDN |
| dist 里有 `.gz/.br` | 用了旧产物。`VITE_BUILD_COMPRESS =` 置空后重新 build，并把多余的删掉 |
| 提交后 GitHub 上 diff 巨大 | `.gitattributes` 没生效。确认有 `MineAdmin-Vue/dist/** -text -diff`，再 `git add --renormalize MineAdmin-Vue/dist` |
| 仓库里 dist 没被跟踪 | `git check-ignore -v MineAdmin-Vue/dist/index.html`。有输出说明仍被忽略，检查两个 `.gitignore` |

---

## 10. 检查清单

- [ ] `MineAdmin-Vue/dist/index.html` 在仓库里（`git ls-files MineAdmin-Vue/dist | head`）
- [ ] `git check-ignore` 对 dist 无输出
- [ ] `.gitattributes` 有 `MineAdmin-Vue/dist/** -text -diff`
- [ ] `deploy/.env` 里 `FRONTEND_MODE=repo`
- [ ] 宝塔站点：根目录 `.../MineAdmin-Vue/dist`、PHP 选「纯静态」、伪静态「无」
- [ ] `location ^~ /hyperfproapi/` 的 `proxy_pass` 带尾斜杠
- [ ] `www` 可读 dist（`chmod -R o+rX`）
- [ ] `curl -sI http://域名/index.html` 的 `Cache-Control` 含 `no-cache`
- [ ] 改了前端后，`dist` 的 hash 文件名有变化（否则是没重新 build）
