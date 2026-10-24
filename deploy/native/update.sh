#!/usr/bin/env bash
# 原生（不用 Docker）日常更新：git pull -> 依赖 -> 迁移 -> 前端 -> 权限 -> 重启
#
# 用法（在服务器仓库根目录，或由 scripts/publish.ps1 -Native 调用）：
#   bash deploy/native/update.sh
#   bash deploy/native/update.sh --skip-pull
#   bash deploy/native/update.sh --skip-frontend
#   bash deploy/native/update.sh --php-bin=/www/server/php/83/bin/php

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

SKIP_PULL=0
SKIP_FRONTEND=0
INSTALL_DEV=1

for arg in "$@"; do
    case "$arg" in
        --skip-pull)      SKIP_PULL=1 ;;
        --skip-frontend)  SKIP_FRONTEND=1 ;;
        --no-dev)         INSTALL_DEV=0 ;;
        --php-bin=*)      PHP_BIN="${arg#*=}" ;;
        *) die "未知参数：$arg" ;;
    esac
done

resolve_php
check_php_env
export PHP_BIN

cd "$ROOT"

if [ "$SKIP_PULL" = "0" ] && [ -d "$ROOT/.git" ]; then
    CURRENT_BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
    if [ "$CURRENT_BRANCH" != "main" ]; then
        die "服务器仓库当前在分支「$CURRENT_BRANCH」，本项目只用 main。
请先执行：cd $ROOT && git checkout main"
    fi
    log "拉取 GitHub 最新代码（main）"
    git -C "$ROOT" pull --ff-only origin main
fi

cd "$APP_DIR"

if composer_needed; then
    resolve_composer
    log "安装 PHP 依赖"
    if [ "$INSTALL_DEV" = "1" ]; then
        run_composer install --no-interaction --prefer-dist -o
    else
        run_composer install --no-interaction --prefer-dist -o --no-dev
    fi
else
    echo "PHP 依赖无变化，跳过 composer"
fi

rm -rf "$APP_DIR/runtime/container"

log "执行数据库迁移"
"$PHP_BIN" bin/hyperf.php migrate --force

if [ "$SKIP_FRONTEND" = "0" ]; then
    build_frontend 0 || true
else
    echo "已指定 --skip-frontend"
fi

log "修正目录权限"
fix_permissions

log "重启服务"
bash "$NATIVE_DIR/manage.sh" restart

log "更新完成"
bash "$NATIVE_DIR/manage.sh" status
