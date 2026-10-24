<?php

declare(strict_types=1);

/**
 * Lab 03：Channel —— 生产者 / 消费者 + 背压
 * 运行：php lab/swoole/03-channel.php
 *
 * 观察点：
 * 1. Channel 容量为 2，生产者 push 到第 3 个任务时会挂起，等消费者取走
 * 2. Channel::close() 之后，消费者 pop 到空会得到 false，从而退出循环
 */

use Swoole\Coroutine;
use Swoole\Coroutine\Channel;
use function Swoole\Coroutine\run;

run(function () {
    $channel = new Channel(2);

    Coroutine::create(function () use ($channel) {
        for ($i = 1; $i <= 5; ++$i) {
            $channel->push(['task' => $i, 'at' => date('H:i:s')]);
            echo "[生产者] push 任务 {$i}，队列长度=" . $channel->length() . "\n";
            Coroutine::sleep(0.2);
        }
        $channel->close();
        echo "[生产者] 关闭 Channel\n";
    });

    while (true) {
        $task = $channel->pop();
        if ($task === false) {
            break; // Channel 已关闭且没有剩余数据
        }
        echo "  [消费者] 处理任务 {$task['task']}（入队于 {$task['at']}）\n";
        Coroutine::sleep(0.4);
    }

    echo "[消费者] 全部处理完成\n";
});
