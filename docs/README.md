# MineAdmin + Hyperf + Swoole 学习工作区

这个目录是为「本地读代码 / 改代码 → push 到 GitHub → 服务器 pull 并热更新」准备的。

## 目录

```
D:\code\hyperfstu
├─ MineAdmin\                 # 框架源码（GitHub 3.2 分支，Hyperf 3.2）
│  ├─ app\                    # 业务代码（控制器/服务/仓储/模型）
│  ├─ config\                 # 配置（server、routes、watcher、db、redis...）
│  ├─ databases\              # 迁移 + 种子数据
│  ├─ plugin\                 # 插件
│  ├─ vendor\                 # 本地只读源码（Windows 装不了 Swoole，跑不起来，但看代码够用）
│  └─ lab\swoole\             # 我加的 Swoole 实验脚本（可以随时删）
├─ MineAdmin-Vue\             # 前端源码（Vue3 + Vite，构建后由 nginx 托管）
├─ deploy\                    # 服务器端 compose（app + nginx + mysql + redis）+ nginx 配置
├─ scripts\                   # 初始化 / 发布 / 同步 / 日志 / lab 脚本
└─ docs\                      # 学习文档（从 01 开始看）
```

## 学习顺序（建议严格按顺序）

| 顺序 | 文档 | 目标 |
|---|---|---|
| 1 | [01-线上部署与热更新](01-线上部署与热更新.md) | 先把线上跑起来，建立"改代码 → 2 秒后生效"的循环 |
| 2 | [02-Swoole核心机制](02-Swoole核心机制.md) | 进程模型、协程、Channel、Timer、Table、Task |
| 3 | [03-Swoole实验课](03-Swoole实验课.md) | 用 7 个小实验把机制跑一遍 |
| 4 | [04-Hyperf核心原理](04-Hyperf核心原理.md) | 启动流程、DI、注解、AOP、中间件、协程上下文、连接池 |
| 5 | [05-MineAdmin源码导读](05-MineAdmin源码导读.md) | 登录、鉴权、CRUD、插件、异常与响应格式 |
| 6 | [06-实战-写一个CRUD模块](06-实战-写一个CRUD模块.md) | 从迁移到接口，完整加一个模块 |
| 7 | [07-六周学习计划](07-六周学习计划.md) | 每天做什么、如何自测 |
| 8 | [08-GitHub部署与前端发布](08-GitHub部署与前端发布.md) | GitHub 单仓库 + 服务器拉取 + Nginx 前端 |
| 9 | [09-Nginx反向代理与请求头](09-Nginx反向代理与请求头.md) | 代理配置、header 传递、后端取参、真实 IP |
| 10 | [10-宝塔面板部署](10-宝塔面板部署.md) | 服务器用宝塔时：面板 Nginx 做入口、docker 只跑应用 |
| 11 | [11-不用Docker启动](11-不用Docker启动.md) | 完全不用 docker：宝塔 PHP + Swoole 直接常驻 |
| 12 | [12-前端dist静态托管](12-前端dist静态托管.md) | 本地构建 → 提交 dist → 域名直接指向 dist 目录 |

## 三条命令先记住

```powershell
# 1. 一次性部署（第一次，需要先填 scripts\deploy.config.ps1）
powershell -ExecutionPolicy Bypass -File scripts\bootstrap.ps1

# 2. 日常发布：commit + push + 服务器 pull + 构建前端
powershell -ExecutionPolicy Bypass -File scripts\publish.ps1 -Message "说明"

# 3. 看线上实时日志（另一个窗口）
powershell -ExecutionPolicy Bypass -File scripts\remote.ps1 logs
```

> 只改 PHP 想立刻看效果、不想提交时，仍可开 `scripts\sync.ps1 -Watch` 做草稿同步。

## 这份代码的版本事实（已核对）

- MineAdmin：`3.2` 分支，快照提交 `955e2c7b`
- MineAdmin-Vue：`3.2.2`，快照提交 `8a424d9`（package.json 版本 3.2.1）
- Hyperf：`3.2.*`
- PHP：`>= 8.2`（部署镜像用 8.3）
- Swoole：`>= 5.0`（部署镜像自带 Swoole 6.x）
- 前端：Vue 3 + Vite 8 + pnpm，hash 路由，生产 API 前缀 `/hyperfproapi`
- 路由：由 **hyperf/swagger 的 OpenAPI 注解** 自动注册，`#[Get]/#[Post]` 就是路由
- 热更新：`hyperf/watcher` 的 `ScanFileDriver`，每 2000ms 扫描 `app`、`config`、`.env`

## 两个容易踩的坑（先告诉你）

1. **`SWAGGER_ENABLED` 不能是 `false`**。MineAdmin 3.2 没有 `#[Controller]` 注解，路由是 `hyperf/swagger` 的 `BootSwaggerListener` 扫描 `#[Get]/#[Post]` 注册的；`swagger.enable=false` 时这个监听器直接 return，所有 `/admin/*` 都会 404。部署脚本已经自动设为 `true`。
2. **本地 Windows 跑不了 Swoole**。本地只用来读代码/改代码，运行一律在服务器容器里。

## 环境检查

```powershell
php -v          # 本地 8.4，仅用于语法检查/Composer
git --version
ssh -V
```

服务器上：

```bash
docker compose version
php -v          # 在容器里
php --ri swoole
```
