<?php

declare(strict_types=1);

/**
 * Lab 06：协程 HTTP 客户端 —— 并发请求本机 MineAdmin
 * 运行前先确保容器里的 Hyperf 已经启动（docker compose ps 里 app 是 Up）
 * 运行：php lab/swoole/06-http-client.php
 *
 * 观察点：
 * 1. 5 个请求几乎同时发出，总耗时远小于串行 5 次
 * 2. 每个请求的 cid 不同，但都在同一个进程里
 */

use Swoole\Coroutine;
use Swoole\Coroutine\Http\Client;
use function Swoole\Coroutine\run;

$start = microtime(true);

run(function () {
    for ($i = 1; $i <= 5; ++$i) {
        Coroutine::create(function () use ($i) {
            $client = new Client('127.0.0.1', 9501);
            $client->set(['timeout' => 5]);
            $client->get('/');

            $body = substr((string) $client->body, 0, 40);
            echo "请求 {$i}: status={$client->statusCode} cid=" . Coroutine::getCid() . " body={$body}\n";

            if ($client->statusCode < 0) {
                echo "  ↑ 连不上 9501，请先确认 Hyperf 已启动\n";
            }

            $client->close();
        });
    }
});

echo '5 个并发请求总耗时 ' . round(microtime(true) - $start, 3) . " 秒\n";
