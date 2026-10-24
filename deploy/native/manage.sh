#!/usr/bin/env bash
# 原生（不用 Docker）进程管理：start / stop / restart / reload / status / logs / watch
#
# 用法（在服务器仓库根目录）：
#   bash deploy/native/manage.sh start
#   bash deploy/native/manage.sh status
#   bash deploy/native/manage.sh logs 300
#   bash deploy/native/manage.sh watch        # 前台热更新，开发用
#
# 默认用 www 用户运行（和宝塔 nginx 一致），首次请确保已跑过 install.sh。

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

ACTION="${1:-status}"
TAIL="${2:-200}"

LOG_DIR="$APP_DIR/runtime/logs"
START_LOG="$LOG_DIR/native-start.log"

RUN_USER=""
if [ "$(id -u)" = "0" ] && id www >/dev/null 2>&1; then
    RUN_USER="www"
fi

prepare_dirs() {
    mkdir -p "$APP_DIR/runtime" "$LOG_DIR" "$APP_DIR/storage/uploads"
    if [ -n "$RUN_USER" ]; then
        chown -R "$RUN_USER":"$RUN_USER" "$APP_DIR/runtime" "$APP_DIR/storage" 2>/dev/null || true
    fi
}

latest_log() {
    local newest
    newest="$(ls -t "$LOG_DIR"/*.log 2>/dev/null | head -n 1 || true)"
    [ -n "$newest" ] && printf '%s' "$newest" || printf '%s' "$START_LOG"
}

do_start() {
    resolve_php
    prepare_dirs
    if process_running; then
        echo "已经在运行，PID $(cat "$PID_FILE")"
        return 0
    fi
    rm -f "$PID_FILE"

    log "启动 Hyperf（PHP: $PHP_BIN）"
    if [ -n "$RUN_USER" ]; then
        su -s /bin/bash "$RUN_USER" -c \
            "cd '$APP_DIR' && nohup '$PHP_BIN' '$APP_DIR/bin/hyperf.php' start >> '$START_LOG' 2>&1 &"
    else
        ( cd "$APP_DIR" && nohup "$PHP_BIN" "$APP_DIR/bin/hyperf.php" start >> "$START_LOG" 2>&1 & )
    fi

    local i
    for i in $(seq 1 40); do
        if process_running; then
            echo "启动成功，PID $(cat "$PID_FILE")"
            return 0
        fi
        sleep 0.5
    done

    echo "启动后 20 秒内没拿到 PID，最近日志："
    tail -n 40 "$START_LOG" 2>/dev/null || true
    return 1
}

do_stop() {
    local pid=""
    if [ -f "$PID_FILE" ]; then
        pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    fi

    if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
        # 兜底：没写 pid 文件时按命令行匹配（只匹配本项目）
        local pids
        pids="$(pgrep -f "$APP_DIR/bin/hyperf.php start" 2>/dev/null || true)"
        if [ -z "$pids" ]; then
            echo "没有在运行"
            rm -f "$PID_FILE"
            return 0
        fi
        pid="$pids"
    fi

    log "停止（SIGTERM）：$pid"
    kill -TERM $pid 2>/dev/null || true
    local i
    for i in $(seq 1 30); do
        local alive=0
        for p in $pid; do
            kill -0 "$p" 2>/dev/null && alive=1
        done
        [ "$alive" = "0" ] && break
        sleep 1
    done

    for p in $pid; do
        if kill -0 "$p" 2>/dev/null; then
            warn "进程 $p 30 秒内没退出，强制 kill -9"
            kill -9 "$p" 2>/dev/null || true
        fi
    done
    rm -f "$PID_FILE"
    echo "已停止"
}

do_reload() {
    if ! process_running; then
        echo "没有在运行，先 start"
        return 1
    fi
    local pid
    pid="$(cat "$PID_FILE")"
    log "平滑重载 worker（SIGUSR1）：$pid"
    kill -USR1 "$pid"
    echo "已发送。只重载 worker，改 .env / config 请用 restart。"
}

do_status() {
    resolve_php
    if process_running; then
        local pid
        pid="$(cat "$PID_FILE")"
        echo "运行中  PID=$pid"
        ps -o pid,ppid,etime,user,cmd -p "$pid" 2>/dev/null || true
    else
        echo "未运行"
    fi
    echo "PHP     : $PHP_BIN ($("$PHP_BIN" -r 'echo PHP_VERSION;' 2>/dev/null || echo '?'))"
    echo "swoole  : $("$PHP_BIN" -r 'echo phpversion("swoole") ?: "未安装";' 2>/dev/null || echo '?')"
    echo "监听    : $(ss -lntp 2>/dev/null | grep -c ':9501 ' || true) 个 9501 监听"
    echo "日志目录: $LOG_DIR"
    echo "启动日志: $START_LOG"
}

case "$ACTION" in
    start)   do_start ;;
    stop)    do_stop ;;
    restart) do_stop; do_start ;;
    reload)  do_reload ;;
    status)  do_status ;;
    logs)
        prepare_dirs
        exec tail -n "$TAIL" -F "$(latest_log)"
        ;;
    watch)
        resolve_php
        prepare_dirs
        log "前台热更新（Ctrl+C 退出）。只监听 PHP 源码变化，改 .env 需要 restart。"
        if [ -n "$RUN_USER" ]; then
            exec su -s /bin/bash "$RUN_USER" -c "cd '$APP_DIR' && exec '$PHP_BIN' '$APP_DIR/bin/hyperf.php' server:watch"
        fi
        cd "$APP_DIR"
        exec "$PHP_BIN" "$APP_DIR/bin/hyperf.php" server:watch
        ;;
    *)
        echo "用法：$0 {start|stop|restart|reload|status|logs|watch} [日志行数]"
        exit 1
        ;;
esac
