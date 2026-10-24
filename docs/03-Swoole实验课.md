# 03 Swoole 实验课

所有实验都在 `MineAdmin/lab/swoole/`，通过脚本自动同步到服务器并在容器里执行。

```powershell
# 通用格式
powershell -ExecutionPolicy Bypass -File scripts\lab.ps1 lab/swoole/01-process.php
```

脚本做三件事：同步代码 → `docker compose exec -T app php /opt/www/lab/...` → 把输出实时打回本地。

建议每个实验都做两遍：先跑一遍看现象，再改代码改参数跑第二遍。

---

## 实验 1：进程与共享内存

```powershell
powershell -ExecutionPolicy Bypass -File scripts\lab.ps1 lab/swoole/01-process.php
```

预期：

```
[子进程 1] pid=123, ppid=100
[子进程 2] pid=124, ppid=100
[子进程 3] pid=125, ppid=100
[父进程] pid=100，已创建 3 个子进程
...
[父进程] 子进程全部退出，Table 中数据仍然存在：
  worker_1: pid=123 no=1
  ...
```

要理解：

- 父子 pid 关系
- 子进程退出后 Table 数据还在（共享内存不属于某个子进程）
- 把 `$table->set(...)` 删掉再跑，观察父进程读到什么

思考：

1. 为什么 `Table` 必须在 `start()` 之前 `create()`？
2. 如果把 Table 换成普通数组 `$arr[$i] = ...`，父进程能看到吗？为什么？

---

## 实验 2：协程并发

```powershell
powershell -ExecutionPolicy Bypass -File scripts\lab.ps1 lab/swoole/02-coroutine.php
```

预期：总耗时约 1 秒，3 个协程的 cid 不同、pid 相同。

改造：

- 把 `Coroutine::sleep(1.0)` 换成 `usleep(1_000_000)`（未 Hook），观察总耗时是否变成 3 秒
- 把 3 改成 100，看耗时是否仍然是 1 秒
- 在协程里加一个 `for ($i=0;$i<1e8;$i++)` 的死循环，观察其他协程是否被卡住

---

## 实验 3：Channel 背压

```powershell
powershell -ExecutionPolicy Bypass -File scripts\lab.ps1 lab/swoole/03-channel.php
```

预期：生产者 push 到第 3 个任务时会等待，消费者取走后才继续。

改造：

- 把容量 `2` 改成 `10`，观察生产者是否还会等待
- 把消费者 `sleep(0.4)` 改成 `2`，观察生产者被压住
- 把 `close()` 去掉，程序会怎样？（消费者永远等不到 false）

---

## 实验 4：定时器与原子计数

```powershell
powershell -ExecutionPolicy Bypass -File scripts\lab.ps1 lab/swoole/04-timer-atomic.php
```

预期：200ms 的 after 执行一次，tick 每 300ms 一次，共 5 次后退出。

改造：

- 去掉 `Event::wait()`，观察定时器是否还执行
- 把 `Timer::clearAll()` 换成 `Timer::clear($tick)`，只清 tick
- 用 `Swoole\Atomic` 在多个协程里并发 `add(1)`，验证结果是否是精确的 10000

---

## 实验 5：最小 TCP 服务器

```powershell
powershell -ExecutionPolicy Bypass -File scripts\lab.ps1 lab/swoole/05-tcp-server.php
```

预期：master 启动 → 3 个客户端连接 → 各自收到 echo → 1.5 秒后服务器关闭。

要理解：

- `on('Start')` 在 master 进程执行，`on('Receive')` 在 worker 执行（看 pid）
- `fd` 是连接在 worker 内的标识
- 为什么 `WorkerStart` 里可以 `go()` 和 `Timer::after()`

改造：

- 把 `worker_num` 改成 1，观察连接是否都落在同一个 worker
- 在 `onReceive` 里 `sleep(1)`，同时开 3 个客户端，观察是否串行（未 Hook 时）
- 把 `SWOOLE_PROCESS` 改成 `SWOOLE_BASE`，观察行为差异

---

## 实验 6：协程 HTTP 客户端

先确认应用在跑：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\remote.ps1 ps
```

然后：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\lab.ps1 lab/swoole/06-http-client.php
```

预期：5 个请求并发，status=200，总耗时远小于串行。

改造：

- 把并发数改成 100，观察耗时和 `Coroutine::stats()`
- 请求 `/admin/passport/login`（POST），感受一下自己请求自己的服务
- 用 `Hyperf\Coroutine\Parallel` 重写一版（需要写进 app 里，或直接用 `php -r` 不方便，建议留到 Hyperf 阶段）

---

## 实验 7：Hook

```powershell
powershell -ExecutionPolicy Bypass -File scripts\lab.ps1 lab/swoole/07-hook.php
```

预期：总耗时约 1 秒。

改造：

- 注释掉 `Runtime::enableCoroutine(SWOOLE_HOOK_ALL);`，再跑一次，总耗时变成约 3 秒
- 把 `sleep(1)` 换成 `file_get_contents('/tmp/bigfile')`（先造一个大文件），观察 Hook 文件 IO

---

## 自测题

做完 7 个实验，应该能回答：

1. Swoole 的 Master / Manager / Worker 各自负责什么？
2. 一个 worker 里能同时跑多少个协程？受什么限制？
3. 协程在什么情况下会让出 CPU？`for` 循环会让出吗？
4. 为什么不能把请求数据存在单例的属性里？
5. `Channel` 满了以后 `push` 会怎样？`pop` 空队列会怎样？
6. 为什么 `Table` 必须在 fork 前创建？
7. `max_request` 解决什么问题？
8. 热更新为什么要重启进程，而不能只 reload？

答不上来的，回到 [02-Swoole核心机制](02-Swoole核心机制.md) 对应小节。

---

下一篇：[04-Hyperf核心原理](04-Hyperf核心原理.md)
