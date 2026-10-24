#!/usr/bin/env bash
# 首次安装（不用 Docker）：装依赖 -> 迁移 -> 灌初始数据 -> 构建前端 -> 修权限
#
# 用法（在服务器仓库根目录）：
#   bash deploy/native/install.sh
#   bash deploy/native/install.sh --php-bin=/www/server/php/83/bin/php
#   bash deploy/native/install.sh --skip-frontend
#   bash deploy/native/install.sh --no-dev
#
# 前提：MineAdmin/.env 已经写好，且宝塔里已建好数据库 / Redis。
# 不会启动服务；启动用 deploy/native/manage.sh start 或宝塔进程守护。

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

SKIP_FRONTEND=0
INSTALL_DEV=1
BUILD_FRONTEND_FORCE=0

for arg in "$@"; do
    case "$arg" in
        --php-bin=*)        PHP_BIN="${arg#*=}" ;;
        --skip-frontend)    SKIP_FRONTEND=1 ;;
        --build-frontend)   BUILD_FRONTEND_FORCE=1 ;;
        --no-dev)           INSTALL_DEV=0 ;;
        -h|--help)
            sed -n '2,12p' "$0"
            exit 0
            ;;
        *) die "未知参数：$arg" ;;
    esac
done

resolve_php
check_php_env

[ -f "$APP_DIR/.env" ] || die "缺少 $APP_DIR/.env。先在本地跑 scripts\\bootstrap-native.ps1，或手动 cp .env.example .env 后改数据库配置。"
[ -f "$APP_DIR/composer.json" ] || die "没找到 $APP_DIR/composer.json，确认仓库完整。"

cd "$APP_DIR"

if composer_needed; then
    resolve_composer
    log "安装 PHP 依赖（composer install）"
    if [ "$INSTALL_DEV" = "1" ]; then
        run_composer install --no-interaction --prefer-dist -o
    else
        run_composer install --no-interaction --prefer-dist -o --no-dev
    fi
else
    echo "PHP 依赖已是最新，跳过 composer"
fi

# 注解扫描缓存必须清掉，否则改了代码/路由不生效
rm -rf "$APP_DIR/runtime/container"

log "执行数据库迁移"
"$PHP_BIN" bin/hyperf.php migrate --force

if [ ! -f "$STATE_DIR/native-installed" ]; then
    log "首次灌入初始数据（菜单 / 用户）"
    "$PHP_BIN" bin/hyperf.php db:seed --path=databases/seeders --force
    mkdir -p "$STATE_DIR"
    date -u +"%Y-%m-%dT%H:%M:%SZ" > "$STATE_DIR/native-installed"
    echo "已写入标记：.deploy/native-installed（以后不会再重复 seed）"
else
    echo "检测到 .deploy/native-installed，跳过 seed"
fi

if [ "$SKIP_FRONTEND" = "1" ]; then
    echo "已指定 --skip-frontend，跳过前端"
else
    build_frontend "$BUILD_FRONTEND_FORCE" || true
fi

log "修正目录权限"
fix_permissions

log "安装完成"
cat <<EOF

下一步：
  启动服务      bash deploy/native/manage.sh start
  看日志        bash deploy/native/manage.sh logs
  状态          bash deploy/native/manage.sh status

如果要用宝塔「进程守护管理器」，先别启动，直接按 docs/11-不用Docker启动.md 添加守护进程。
EOF
