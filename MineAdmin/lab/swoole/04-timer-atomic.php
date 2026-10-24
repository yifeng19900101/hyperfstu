<?php

declare(strict_types=1);

/**
 * Lab 04：定时器 + 原子计数 + 事件循环
 * 运行：php lab/swoole/04-timer-atomic.php
 *
 * 观察点：
 * 1. Timer::after 只执行一次，Timer::tick 每 300ms 执行一次
 * 2. Atomic 是跨进程安全的计数器（这里在单进程里演示用法）
 * 3. CLI 脚本需要用 Event::wait() 挂起事件循环，否则定时器不会执行
 */

use Swoole\Atomic;
use Swoole\Event;
use Swoole\Timer;

$counter = new Atomic(0);

Timer::after(200, static function () {
    echo "[after] 200ms 到，只执行一次\n";
});

Timer::tick(300, static function () use ($counter) {
    $n = $counter->add(1);
    echo "[tick] 第 {$n} 次，时间=" . date('H:i:s') . "\n";

    if ($n >= 5) {
        Timer::clearAll();
        echo "[tick] 清除所有定时器，事件循环即将退出\n";
    }
});

Event::wait();

echo "done\n";
