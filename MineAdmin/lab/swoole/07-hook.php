<?php

declare(strict_types=1);

/**
 * Lab 07：Hook —— 把阻塞函数变成协程调度
 * 运行：php lab/swoole/07-hook.php
 *
 * 说明：
 * - 默认情况下 sleep() 会阻塞整个进程，协程也无法切换
 * - Runtime::enableCoroutine(SWOOLE_HOOK_ALL) 之后，sleep/文件/网络等调用会被 Swoole 接管
 * - 这正是 Hyperf 能"一个进程处理上万并发"的基础，也是你必须避免 CPU 密集任务的原因
 */

use Swoole\Coroutine;
use Swoole\Runtime;
use function Swoole\Coroutine\run;

Runtime::enableCoroutine(SWOOLE_HOOK_ALL);

$start = microtime(true);

run(function () {
    for ($i = 1; $i <= 3; ++$i) {
        go(function () use ($i) {
            echo "[协程 {$i}] 开始 cid=" . Coroutine::getCid() . ' 时间=' . date('H:i:s') . "\n";
            sleep(1); // 被 Hook 后，这里会让出 CPU
            echo "[协程 {$i}] 结束时间=" . date('H:i:s') . "\n";
        });
    }
});

echo '总耗时 ' . round(microtime(true) - $start, 2) . " 秒（如果是 3 秒说明 Hook 没生效）\n";
