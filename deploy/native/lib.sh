#!/usr/bin/env bash
# 原生（不用 Docker）部署公共函数，被 install.sh / update.sh / manage.sh source。
# 目标环境：宝塔面板 + 面板安装的 PHP 8.2/8.3（含 swoole、redis 扩展）+ 面板 MySQL/Redis。

set -euo pipefail

NATIVE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$NATIVE_DIR/../.." && pwd)"
APP_DIR="$ROOT/MineAdmin"
FRONT_DIR="$ROOT/MineAdmin-Vue"
STATE_DIR="$ROOT/.deploy"
WEB_DIR="$APP_DIR/web"
PID_FILE="$APP_DIR/runtime/hyperf.pid"

PHP_BIN="${PHP_BIN:-}"
COMPOSER_BIN=""
COMPOSER_PHAR=""

log() { printf '\n\033[36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33m[警告] %s\033[0m\n' "$*"; }
die() { printf '\033[31m[错误] %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- PHP
resolve_php() {
    if [ -n "$PHP_BIN" ] && [ -x "$PHP_BIN" ]; then
        return 0
    fi
    local candidate
    for candidate in \
        /www/server/php/83/bin/php \
        /www/server/php/82/bin/php \
        /usr/local/bin/php \
        /usr/bin/php; do
        if [ -x "$candidate" ]; then
            PHP_BIN="$candidate"
            return 0
        fi
    done
    candidate="$(command -v php 2>/dev/null || true)"
    [ -n "$candidate" ] || die "找不到 php 可执行文件。用 --php-bin=/www/server/php/83/bin/php 指定。"
    PHP_BIN="$candidate"
}

check_php_env() {
    local version
    version="$("$PHP_BIN" -r 'echo PHP_VERSION;')"
    log "PHP：$PHP_BIN（$version）"

    "$PHP_BIN" -r 'exit(PHP_VERSION_ID >= 80200 ? 0 : 1);' \
        || die "PHP 版本过低（当前 $version），MineAdmin 3.2 需要 >= 8.2。"

    local exts missing=()
    exts="$("$PHP_BIN" -m | tr 'A-Z' 'a-z')"
    for ext in swoole redis pdo_mysql fileinfo json openssl mbstring; do
        echo "$exts" | grep -qx "$ext" || missing+=("$ext")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        die "缺少扩展：${missing[*]}
在宝塔面板 → 软件商店 → PHP-8.3 设置 → 安装扩展 里补上，或见 docs/11-不用Docker启动.md"
    fi

    local swoole_version
    swoole_version="$("$PHP_BIN" -r 'echo phpversion("swoole");')"
    "$PHP_BIN" -r 'exit(version_compare(phpversion("swoole"), "5.0.0", ">=") ? 0 : 1);' \
        || die "swoole 版本过低（$swoole_version），Hyperf 3.2 需要 >= 5.0。"
    log "swoole：$swoole_version"

    # Hyperf 启动时会强校验这一项，不是 Off 直接退出
    local short normalized
    short="$("$PHP_BIN" -r '$a = ini_get_all("swoole"); echo $a["swoole.use_shortname"]["local_value"] ?? "";' 2>/dev/null || true)"
    normalized="$(printf '%s' "$short" | tr 'A-Z' 'a-z' | tr -d '0 ')"
    case "$normalized" in
        ''|off|false) ;;
        *) die "php.ini 里 swoole.use_shortname 当前是 '$short'，必须设为 Off，否则 Hyperf 无法启动。
在 /www/server/php/83/etc/php.ini 末尾加一行：swoole.use_shortname=Off
然后重载 PHP（宝塔 PHP 设置里保存即可）。" ;;
    esac

    # getenv / putenv 必须是可用函数，否则 hyperf 的 DotenvManager 直接崩：
    #   RuntimeException: None has no value.
    #   at vendor/phpoption/phpoption/src/PhpOption/None.php
    # 原因：phpdotenv 的 PutenvAdapter::create() 在 putenv/getenv 被禁用时返回 None，
    #       Hyperf 对这个 None 调用了 ->get()。
    if ! "$PHP_BIN" -r 'exit(function_exists("getenv") && function_exists("putenv") ? 0 : 1);'; then
        local disabled_now
        disabled_now="$("$PHP_BIN" -r 'echo ini_get("disable_functions");')"
        die "putenv / getenv 被禁用，Hyperf 无法读取 .env（报错：None has no value）。

当前 disable_functions：${disabled_now:-（空）}

处理（二选一）：
  1) 宝塔面板 → 软件商店 → PHP-8.3 → 设置 → 禁用函数，
     把 putenv 和 getenv 删掉 → 保存。
  2) 直接改 php.ini（路径看 php --ini 的输出，宝塔一般是
     /www/server/php/83/etc/php.ini），从 disable_functions 里删掉这两项，再重载 PHP。

改完验证（两条都应为 true）：
  $PHP_BIN -r 'var_dump(function_exists(\"putenv\"), function_exists(\"getenv\"));'"
    fi
    log 'getenv / putenv 可用'

    # 这些不是致命项，但 composer / server:watch / Swoole 进程管理会踩到
    for fn in proc_open popen pcntl_fork pcntl_signal pcntl_signal_dispatch; do
        if ! "$PHP_BIN" -r "exit(function_exists('$fn') ? 0 : 1);"; then
            warn "disable_functions 里有 $fn，composer / server:watch / Swoole 可能出错。建议在宝塔 PHP 设置的「禁用函数」里删掉它。"
        fi
    done

    local memory
    memory="$("$PHP_BIN" -r 'echo ini_get("memory_limit");')"
    log "memory_limit：$memory"
}

# ---------------------------------------------------------------- Composer
resolve_composer() {
    if command -v composer >/dev/null 2>&1; then
        COMPOSER_BIN="$(command -v composer)"
        return 0
    fi
    mkdir -p "$STATE_DIR"
    COMPOSER_PHAR="$STATE_DIR/composer.phar"
    if [ ! -f "$COMPOSER_PHAR" ]; then
        log "未找到 composer，下载 composer.phar 到 .deploy/"
        "$PHP_BIN" -r "copy('https://getcomposer.org/download/latest-stable/composer.phar', '$COMPOSER_PHAR');" \
            || die "下载 composer 失败。可手动安装：curl -sS https://getcomposer.org/installer | $PHP_BIN"
    fi
}

run_composer() {
    export COMPOSER_ALLOW_SUPERUSER=1
    if [ -n "$COMPOSER_BIN" ]; then
        "$COMPOSER_BIN" "$@"
    else
        "$PHP_BIN" "$COMPOSER_PHAR" "$@"
    fi
}

composer_needed() {
    [ -f "$APP_DIR/vendor/autoload.php" ] || return 0
    [ "$APP_DIR/composer.json" -nt "$APP_DIR/vendor/composer/installed.json" ] && return 0
    [ -f "$APP_DIR/composer.lock" ] && [ "$APP_DIR/composer.lock" -nt "$APP_DIR/vendor/composer/installed.json" ] && return 0
    return 1
}

# ---------------------------------------------------------------- Node / 前端
setup_node() {
    if command -v node >/dev/null 2>&1; then
        :
    else
        local dir
        for dir in /www/server/nodejs/*/bin; do
            if [ -x "$dir/node" ]; then
                export PATH="$dir:$PATH"
            fi
        done
    fi
    command -v node >/dev/null 2>&1 || return 1
    if ! command -v pnpm >/dev/null 2>&1; then
        corepack enable >/dev/null 2>&1 || true
        corepack prepare pnpm@10.0.0 --activate >/dev/null 2>&1 || true
    fi
    command -v pnpm >/dev/null 2>&1
}

frontend_changed() {
    local dist="$FRONT_DIR/dist/index.html"
    [ -f "$dist" ] || return 0
    [ -n "$(find "$FRONT_DIR/src" "$FRONT_DIR/public" "$FRONT_DIR/index.html" \
        "$FRONT_DIR/package.json" "$FRONT_DIR/pnpm-lock.yaml" \
        -newer "$dist" -print -quit 2>/dev/null)" ] && return 0
    return 1
}

build_frontend() {
    local force="${1:-0}"
    if [ "$force" != "1" ] && ! frontend_changed; then
        echo "前端产物是最新的，跳过构建"
        return 0
    fi
    if ! setup_node; then
        warn "服务器上没有 node / pnpm，跳过前端构建。
可以在宝塔「Node.js 版本管理器」里装 Node 22，或在本地 pnpm build 后把 dist 上传到 MineAdmin/web。"
        return 1
    fi
    log "构建前端（node $(node -v)，pnpm $(pnpm -v)）"
    ( cd "$FRONT_DIR" && pnpm install --frozen-lockfile && pnpm build )
    [ -f "$FRONT_DIR/dist/index.html" ] || die "前端构建完成但 dist/index.html 不存在"

    log "同步前端到 MineAdmin/web"
    mkdir -p "$WEB_DIR"
    rm -rf "$WEB_DIR"
    mkdir -p "$WEB_DIR"
    cp -a "$FRONT_DIR/dist/." "$WEB_DIR/"
}

# ---------------------------------------------------------------- 权限
fix_permissions() {
    mkdir -p "$APP_DIR/runtime" "$APP_DIR/storage/uploads" "$WEB_DIR"
    if id www >/dev/null 2>&1; then
        chown -R www:www "$APP_DIR/runtime" "$APP_DIR/storage" "$WEB_DIR" 2>/dev/null || true
    fi
    chmod -R u+rwX "$APP_DIR/runtime" "$APP_DIR/storage" "$WEB_DIR" 2>/dev/null || true
    # 面板 nginx 以 www 运行，需要能读静态文件和附件
    chmod o+x "$ROOT" "$APP_DIR" 2>/dev/null || true
    chmod -R o+rX "$WEB_DIR" "$APP_DIR/storage/uploads" 2>/dev/null || true
}

# ---------------------------------------------------------------- 进程
process_running() {
    [ -f "$PID_FILE" ] || return 1
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null
}
