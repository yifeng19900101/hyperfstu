<?php

declare(strict_types=1);

/**
 * Lab 02：协程并发 —— 3 个协程各 sleep 1 秒，总耗时约 1 秒
 * 运行：php lab/swoole/02-coroutine.php
 *
 * 观察点：
 * 1. 所有输出都在同一个 pid 里（协程不是进程/线程）
 * 2. 每个协程有独立的 cid
 * 3. 总耗时 ≈ 1 秒，而不是 3 秒
 */

use Swoole\Coroutine;
use function Swoole\Coroutine\run;

$start = microtime(true);

echo '[主进程] pid=' . getmypid() . "\n";

run(function () {
    echo '[主协程] cid=' . Coroutine::getCid() . '，pid=' . getmypid() . "\n";

    for ($i = 1; $i <= 3; ++$i) {
        Coroutine::create(function () use ($i) {
            $cid = Coroutine::getCid();
            echo "  [协程 {$i}] 开始 cid={$cid}\n";
            Coroutine::sleep(1.0); // 让出执行权，1 秒后由调度器唤醒
            echo "  [协程 {$i}] 结束 cid={$cid}，时间=" . date('H:i:s') . "\n";
        });
    }
});

echo '总耗时 ' . round(microtime(true) - $start, 2) . " 秒（3 个协程并发 sleep 1 秒）\n";
