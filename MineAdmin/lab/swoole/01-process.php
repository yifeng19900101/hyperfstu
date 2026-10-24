<?php

declare(strict_types=1);

/**
 * Lab 01：进程模型 —— 父进程创建子进程，共享内存 Table
 * 运行：php lab/swoole/01-process.php
 *
 * 观察点：
 * 1. 每个子进程的 pid 都不同，但 ppid 都等于父进程 pid
 * 2. 子进程 exit 后，父进程仍能读到 Table 里的数据（Table 是共享内存，父进程创建、子进程写入）
 */

use Swoole\Process;
use Swoole\Table;

$table = new Table(1024);
$table->column('pid', Table::TYPE_INT, 8);
$table->column('no', Table::TYPE_INT, 4);
$table->create();

$workers = [];

for ($i = 1; $i <= 3; ++$i) {
    $process = new Process(function (Process $proc) use ($i, $table) {
        $table->set('worker_' . $i, ['pid' => $proc->pid, 'no' => $i]);
        echo "[子进程 {$i}] pid={$proc->pid}, ppid={$proc->ppid}\n";
        usleep(500_000);
        echo "[子进程 {$i}] 退出\n";
        $proc->exit(0);
    }, false);

    $process->start();
    $workers[] = $process;
}

echo "[父进程] pid=" . getmypid() . '，已创建 ' . count($workers) . " 个子进程\n";

foreach ($workers as $worker) {
    Process::wait();
}

echo "[父进程] 子进程全部退出，Table 中数据仍然存在：\n";
foreach ($table as $key => $row) {
    echo "  {$key}: pid={$row['pid']} no={$row['no']}\n";
}
