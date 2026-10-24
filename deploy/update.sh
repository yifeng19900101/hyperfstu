#!/usr/bin/env bash
# 服务器端：拉取 GitHub 最新代码 -> 装依赖 -> 迁移 -> 构建前端 -> 重启容器
#
# 用法（在服务器仓库根目录）：
#   bash deploy/update.sh              # 日常更新
#   bash deploy/update.sh --skip-pull  # 已经手动 pull 过
#   bash deploy/update.sh --init       # 第一次安装（migrate + seed）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

COMPOSE=(docker compose -f deploy/docker-compose.yml)
SKIP_PULL=0
INIT=0
SKIP_FRONTEND=0
for arg in "$@"; do
    case "$arg" in
        --skip-pull)     SKIP_PULL=1 ;;
        --init)          INIT=1 ;;
        --skip-frontend) SKIP_FRONTEND=1 ;;
        *) echo "未知参数：$arg"; exit 1 ;;
    esac
done

log() { printf '\n\033[36m==> %s\033[0m\n' "$*"; }

if [ ! -f deploy/.env ]; then
    echo "缺少 deploy/.env，请先在本地运行 scripts/bootstrap.ps1（会自动生成并上传）。"
    exit 1
fi

if [ "$SKIP_PULL" = 0 ] && [ -d .git ]; then
    log "拉取 GitHub 最新代码"
    git pull --ff-only
fi

log "启动 MySQL / Redis"
"${COMPOSE[@]}" up -d mysql redis >/dev/null

wait_healthy() {
    local name="$1"
    for _ in $(seq 1 60); do
        local status
        status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$name" 2>/dev/null || true)"
        [ "$status" = "healthy" ] && return 0
        [ "$status" = "running" ] && return 0
        sleep 3
    done
    echo "$name 未在 180 秒内就绪，请查看：docker logs $name"
    return 1
}
wait_healthy mineadmin-mysql
wait_healthy mineadmin-redis
log "MySQL / Redis 已就绪"

log "检查 PHP 依赖"
NEED_COMPOSER=0
if [ ! -f MineAdmin/vendor/autoload.php ]; then
    NEED_COMPOSER=1
elif [ MineAdmin/composer.json -nt MineAdmin/vendor/composer/installed.json ]; then
    NEED_COMPOSER=1
elif [ -f MineAdmin/composer.lock ] && [ MineAdmin/composer.lock -nt MineAdmin/vendor/composer/installed.json ]; then
    NEED_COMPOSER=1
fi

if [ "$NEED_COMPOSER" = 1 ]; then
    # 仓库里的 composer.lock 已按 PHP 8.3 重新生成，服务器只 install，不改写锁文件
    "${COMPOSE[@]}" run --rm -T --no-deps app composer install --no-interaction --prefer-dist -o
else
    echo "依赖无变化，跳过 composer"
fi

if [ "$INIT" = 1 ] && [ ! -f .deploy/installed ]; then
    log "首次初始化数据库（migrate + seed）"
    "${COMPOSE[@]}" run --rm -T --no-deps app php bin/hyperf.php mine:install --no-interaction
    mkdir -p .deploy
    date -u +"%Y-%m-%dT%H:%M:%SZ" > .deploy/installed
else
    log "执行数据库迁移"
    "${COMPOSE[@]}" run --rm -T --no-deps app php bin/hyperf.php migrate --force
fi

log "构建前端"
DIST="MineAdmin-Vue/dist"
FRONT_CHANGED=0
if [ "$SKIP_FRONTEND" = 1 ]; then
    echo "已指定 --skip-frontend，跳过前端构建"
    FRONT_CHANGED=-1
fi
if [ "$FRONT_CHANGED" = -1 ]; then
    :
elif [ ! -f "$DIST/index.html" ]; then
    FRONT_CHANGED=1
elif [ -n "$(find MineAdmin-Vue/src MineAdmin-Vue/public MineAdmin-Vue/index.html \
        MineAdmin-Vue/package.json MineAdmin-Vue/pnpm-lock.yaml \
        -newer "$DIST/index.html" -print -quit 2>/dev/null)" ]; then
    FRONT_CHANGED=1
fi

if [ "$FRONT_CHANGED" = 1 ]; then
    mkdir -p "$DIST"
    docker run --rm -v "$ROOT/MineAdmin-Vue:/app" -w /app node:22-alpine \
        sh -c "corepack enable >/dev/null 2>&1 || true; pnpm install --frozen-lockfile && pnpm build"
else
    echo "前端源码无变化，跳过构建"
fi

# 最终对外目录是 MineAdmin/web（nginx 的 root），dist 只是构建缓存
log "同步前端到 MineAdmin/web"
mkdir -p MineAdmin/web
if [ -f "$DIST/index.html" ]; then
    cp -a "$DIST/." MineAdmin/web/
else
    echo "警告：$DIST/index.html 不存在，MineAdmin/web 可能为空"
fi

log "启动 / 更新容器"
"${COMPOSE[@]}" up -d

WEB_PORT="$(grep -E '^WEB_PORT=' deploy/.env | head -n1 | cut -d= -f2 || true)"
WEB_PORT="${WEB_PORT:-80}"
if [ "$WEB_PORT" = "80" ]; then
    echo
    echo "部署完成：http://<服务器IP>/"
else
    echo
    echo "部署完成：http://<服务器IP>:$WEB_PORT/"
fi
"${COMPOSE[@]}" ps
