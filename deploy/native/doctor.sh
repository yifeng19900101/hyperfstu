#!/usr/bin/env bash
# 原生部署自检：一条命令把所有「Hyperf 起不来」的常见原因跑一遍。
#
# 用法（在服务器任意目录）：
#   bash /www/wwwroot/hyperfstu/deploy/native/doctor.sh
#   bash deploy/native/doctor.sh --php-bin=/www/server/php/83/bin/php
#
# 不修改任何东西，只读检查。

set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# lib.sh 开了 set -e，自检必须继续跑完，所以这里关掉
set +e

for arg in "$@"; do
    case "$arg" in
        --php-bin=*) PHP_BIN="${arg#*=}" ;;
    esac
done

FAIL=0
WARNS=0
ok()   { printf '  \033[32m[OK]\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
warn2(){ printf '  \033[33m[WARN]\033[0m %s\n' "$*"; WARNS=$((WARNS + 1)); }
head_() { printf '\n\033[36m== %s ==\033[0m\n' "$*"; }

head_ "路径"
echo "  仓库根目录 : $ROOT"
echo "  后端       : $APP_DIR"
[ -d "$APP_DIR" ] && ok "后端目录存在" || bad "后端目录不存在：$APP_DIR"

head_ "PHP"
# 不用 lib.sh 的 resolve_php：它在找不到时直接 die，自检需要继续往下跑
if [ -z "${PHP_BIN:-}" ] || [ ! -x "${PHP_BIN:-}" ]; then
    PHP_BIN=""
    for c in /www/server/php/83/bin/php /www/server/php/82/bin/php /usr/local/bin/php /usr/bin/php; do
        [ -x "$c" ] && PHP_BIN="$c" && break
    done
    [ -z "$PHP_BIN" ] && PHP_BIN="$(command -v php 2>/dev/null || true)"
fi
if [ -z "$PHP_BIN" ] || [ ! -x "$PHP_BIN" ]; then
    bad "找不到 php。用 --php-bin=/www/server/php/83/bin/php 指定"
else
    ok "PHP: $PHP_BIN"
    echo "  版本 : $("$PHP_BIN" -r 'echo PHP_VERSION;')"
    "$PHP_BIN" -r 'exit(PHP_VERSION_ID >= 80200 ? 0 : 1);' \
        && ok "版本 >= 8.2" || bad "版本过低，需要 >= 8.2"

    echo "  实际加载的 ini : $("$PHP_BIN" --ini | tr '\n' ' ' | sed 's/  */ /g')"

    if "$PHP_BIN" -r 'exit(function_exists("getenv") && function_exists("putenv") ? 0 : 1);'; then
        ok "getenv / putenv 可用（.env 能正常解析）"
    else
        bad "getenv / putenv 被禁用 → Hyperf 会报「None has no value」。
         宝塔 → PHP-8.3 → 设置 → 禁用函数，删掉 putenv 和 getenv
         当前 disable_functions：$("$PHP_BIN" -r 'echo ini_get("disable_functions");')"
    fi

    exts="$("$PHP_BIN" -m | tr 'A-Z' 'a-z')"
    for ext in swoole redis pdo_mysql fileinfo json openssl mbstring; do
        if echo "$exts" | grep -qx "$ext"; then
            ok "扩展 $ext"
        else
            bad "缺少扩展 $ext（宝塔 PHP 设置 → 安装扩展）"
        fi
    done

    if echo "$exts" | grep -qx swoole; then
        sv="$("$PHP_BIN" -r 'echo phpversion("swoole");')"
        "$PHP_BIN" -r 'exit(version_compare(phpversion("swoole"), "5.0.0", ">=") ? 0 : 1);' \
            && ok "swoole $sv >= 5.0" || bad "swoole $sv 过低，需要 >= 5.0"
        short="$("$PHP_BIN" -r '$a = ini_get_all("swoole"); echo $a["swoole.use_shortname"]["local_value"] ?? "";' 2>/dev/null || true)"
        norm="$(printf '%s' "$short" | tr 'A-Z' 'a-z' | tr -d '0 ')"
        case "$norm" in
            ''|off|false) ok "swoole.use_shortname = Off" ;;
            *) bad "swoole.use_shortname = '$short'，必须是 Off（php.ini 加 swoole.use_shortname=Off）" ;;
        esac
    fi

    for fn in proc_open popen pcntl_fork pcntl_signal; do
        "$PHP_BIN" -r "exit(function_exists('$fn') ? 0 : 1);" \
            || warn2 "disable_functions 里有 $fn（composer / server:watch 可能失败）"
    done
fi

head_ ".env"
if [ -f "$APP_DIR/.env" ]; then
    ok "$APP_DIR/.env 存在"
    get() { "$PHP_BIN" -r '$l=file($argv[1], FILE_IGNORE_NEW_LINES); foreach($l as $s){ if(preg_match("/^".preg_quote($argv[2],"\/")."=(.*)$/",$s,$m)){ echo $m[1]; return; } }' "$APP_DIR/.env" "$1" 2>/dev/null; }
    echo "  APP_ENV          = $(get APP_ENV)"
    echo "  APP_DEBUG        = $(get APP_DEBUG)"
    echo "  SWAGGER_ENABLED  = $(get SWAGGER_ENABLED)   # 必须 true，否则 /admin/* 全 404"
    echo "  DB_HOST:PORT     = $(get DB_HOST):$(get DB_PORT)"
    echo "  DB_DATABASE      = $(get DB_DATABASE)"
    echo "  DB_USERNAME      = $(get DB_USERNAME)"
    echo "  REDIS_HOST:PORT  = $(get REDIS_HOST):$(get REDIS_PORT)"
    echo "  SERVER_HOST      = $(get SERVER_HOST)   # 原生部署建议 127.0.0.1"
    [ "$(get SWAGGER_ENABLED)" = "true" ] && ok "SWAGGER_ENABLED=true" || bad "SWAGGER_ENABLED 不是 true，路由不会注册"
else
    bad "缺少 $APP_DIR/.env（cp .env.example .env 后填数据库）"
fi

head_ "依赖"
[ -f "$APP_DIR/vendor/autoload.php" ] && ok "vendor/ 已安装" || bad "vendor/ 缺失，先 composer install"
[ -f "$APP_DIR/web/index.html" ] && ok "MineAdmin/web/index.html 存在（前端已构建）" || warn2 "MineAdmin/web 没有前端产物，首页会 404/403"

head_ "目录权限"
id www >/dev/null 2>&1 && RUNU=www || RUNU="$(id -un)"
echo "  运行用户 : $RUNU"
for d in "$APP_DIR/runtime" "$APP_DIR/storage" "$APP_DIR/web"; do
    if [ -e "$d" ]; then
        owner="$(stat -c '%U' "$d" 2>/dev/null || echo '?')"
        if [ "$owner" = "$RUNU" ] || [ "$owner" = "www" ]; then
            ok "$d 属主 $owner"
        else
            warn2 "$d 属主 $owner（建议 chown -R www:www）"
        fi
    else
        warn2 "$d 不存在（启动时会自动创建）"
    fi
done
# 面板 nginx 以 www 运行，需要「其他人可读」
if [ -f "$APP_DIR/web/index.html" ]; then
    su -s /bin/bash www -c "test -r '$APP_DIR/web/index.html'" 2>/dev/null \
        && ok "www 用户可读 web/index.html" \
        || warn2 "www 用户读不到 web/index.html → 首页 403，执行 chmod -R o+rX web storage/uploads"
fi

head_ "数据库 / Redis"
if [ -f "$APP_DIR/.env" ] && [ -n "${PHP_BIN:-}" ]; then
    DBH="$(get DB_HOST)"; DBP="$(get DB_PORT)"; DBD="$(get DB_DATABASE)"; DBU="$(get DB_USERNAME)"; DBW="$(get DB_PASSWORD)"
    if command -v mysql >/dev/null 2>&1; then
        MYSQL_PWD="$DBW" mysql -h "$DBH" -P "${DBP:-3306}" -u "$DBU" -e 'select 1' "$DBD" >/dev/null 2>&1 \
            && ok "MySQL 可连接（$DBU@$DBH:${DBP:-3306}/$DBD）" \
            || bad "MySQL 连不上。检查密码、以及是否需要授权 '$DBU'@'127.0.0.1'"
    else
        warn2 "没有 mysql 客户端，跳过数据库检查"
    fi
    if command -v redis-cli >/dev/null 2>&1; then
        RA="$(get REDIS_AUTH)"
        if [ -n "$RA" ]; then
            redis-cli -h "$(get REDIS_HOST)" -p "$(get REDIS_PORT)" -a "$RA" --no-auth-warning ping 2>/dev/null | grep -q PONG \
                && ok 'Redis PONG' || bad 'Redis 连不上（检查 REDIS_AUTH）'
        else
            redis-cli -h "$(get REDIS_HOST)" -p "$(get REDIS_PORT)" ping 2>/dev/null | grep -q PONG \
                && ok 'Redis PONG' || bad 'Redis 连不上（可能需要密码）'
        fi
    fi
fi

head_ "进程 / 端口"
if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; then
    ok "Hyperf 运行中，PID $(cat "$PID_FILE")"
else
    warn2 "Hyperf 未运行（还没启动，或已崩溃）"
fi
if ss -lntp 2>/dev/null | grep -q ':9501 '; then
    echo "  9501 监听："
    ss -lntp 2>/dev/null | grep ':9501 ' | sed 's/^/    /'
else
    warn2 "9501 没有监听"
fi

printf '\n\033[36m== 结果 ==\033[0m\n'
if [ "$FAIL" -eq 0 ]; then
    printf '  \033[32m全部通过\033[0m（warn %d 项）\n' "$WARNS"
else
    printf '  \033[31m%d 项失败\033[0m（warn %d 项），按上面的提示逐条修\n' "$FAIL" "$WARNS"
fi
[ "$FAIL" -eq 0 ]
