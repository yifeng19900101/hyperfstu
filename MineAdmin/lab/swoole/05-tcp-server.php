<?php

declare(strict_types=1);

/**
 * Lab 05：最小 TCP 服务器 + 协程客户端
 * 运行：php lab/swoole/05-tcp-server.php
 *
 * 观察点：
 * 1. Master 进程负责监听，Worker 进程处理连接（输出里的 pid 是 worker 的）
 * 2. 一个 worker 里可以用协程同时处理多条连接
 * 3. WorkerStart 里既能注册定时器，也能启动协程客户端
 */

use Swoole\Coroutine\Client;
use Swoole\Server;
use Swoole\Timer;

$server = new Server('127.0.0.1', 9502, SWOOLE_PROCESS, SWOOLE_SOCK_TCP);

$server->set([
    'worker_num' => 2,
    'enable_coroutine' => true,
    'log_file' => '/tmp/swoole-lab-05.log',
]);

$server->on('Start', static function (Server $server) {
    echo "[master] TCP 服务启动：127.0.0.1:9502，master_pid={$server->master_pid}\n";
});

$server->on('Connect', static function (Server $server, int $fd, int $reactorId) {
    echo '[worker ' . $server->worker_id . '] 新连接 fd=' . $fd . ' pid=' . getmypid() . "\n";
});

$server->on('Receive', static function (Server $server, int $fd, int $reactorId, string $data) {
    $server->send($fd, 'echo: ' . trim($data) . ' (worker pid=' . getmypid() . ")\n");
});

$server->on('Close', static function (Server $server, int $fd) {
    echo '[worker ' . $server->worker_id . '] 连接关闭 fd=' . $fd . "\n";
});

$server->on('WorkerStart', static function (Server $server, int $workerId) {
    if ($workerId !== 0) {
        return; // 只让 0 号 worker 发起演示客户端
    }

    Timer::after(200, static function () {
        for ($i = 1; $i <= 3; ++$i) {
            go(static function () use ($i) {
                $client = new Client(SWOOLE_SOCK_TCP);
                if (! $client->connect('127.0.0.1', 9502, 2)) {
                    echo "客户端 {$i} 连接失败，errCode={$client->errCode}\n";
                    return;
                }
                $client->send("hello-{$i}");
                echo "客户端 {$i} 收到：" . $client->recv();
                $client->close();
            });
        }
    });

    Timer::after(1500, static function () use ($server) {
        echo "[master] 演示结束，关闭服务器\n";
        $server->shutdown();
    });
});

$server->start();
