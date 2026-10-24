# 02 Swoole 核心机制

这一篇只讲你读 Hyperf/MineAdmin 必须懂的 Swoole 知识。每一条都能在 `MineAdmin/lab/swoole/` 里跑出来。

---

## 1. 为什么 PHP 需要 Swoole

传统 PHP-FPM：

```
Nginx → PHP-FPM master → fork 一个 php-fpm 进程 → 加载所有 PHP 文件 → 执行 → 销毁
```

每个请求都要重新加载框架、重建数据库连接。QPS 上不去，连接也无法复用。

Swoole 是 PHP 的扩展，把 PHP 变成**常驻内存**的服务器：

```
启动时加载一次框架 → 常驻进程 → 每个请求只执行控制器逻辑
```

代价是：**进程是复用的**，所以你不能假设"每次请求都是干净的"。

| 传统 FPM | Swoole / Hyperf |
|---|---|
| 请求结束进程销毁 | 请求结束进程继续活 |
| 全局变量天然隔离 | 全局/静态变量会跨请求残留 |
| `sleep()` 只阻塞自己 | `sleep()` 阻塞整个 worker（必须 Hook） |
| 每请求新建 PDO 连接 | 连接池复用连接 |
| 改代码立即生效 | 必须重启 worker（所以需要热更新） |

---

## 2. 进程模型

`SWOOLE_PROCESS` 模式（`config/autoload/server.php` 用的就是这个）：

```
                    ┌──────────────────────────────┐
                    │        Master 进程            │
                    │  Reactor 线程（epoll 事件循环）│  ← 处理网络 IO、收发数据
                    └──────────────┬───────────────┘
                                   │
                    ┌──────────────▼───────────────┐
                    │        Manager 进程           │  ← 只负责 fork / 回收 worker
                    └──────────────┬───────────────┘
                                   │
        ┌──────────────────────────┼──────────────────────────┐
        ▼                          ▼                          ▼
  ┌───────────┐              ┌───────────┐              ┌───────────┐
  │ Worker 0  │              │ Worker 1  │   ...        │ Worker N  │
  │ 协程调度  │              │ 协程调度  │              │ 协程调度  │
  └───────────┘              └───────────┘              └───────────┘
        │
        ▼  （可选）
  ┌───────────┐
  │ TaskWorker│  ← 处理 $server->task() 投递的异步任务
  └───────────┘
```

要点：

- **Reactor 线程**负责网络事件，不执行业务代码
- **Worker 进程**执行业务代码；Hyperf 里每个请求是一个协程
- Worker 之间**内存不共享**（各自独立的 PHP 变量），共享要用 `Swoole\Table`、Redis、数据库
- 一个 Worker 同一时刻只跑一个线程，但可以跑成千上万个协程
- `worker_num` 不是越大越好：每个 worker 都会独立建立连接池、加载代码

对应 Hyperf 配置：

```php
// MineAdmin/config/autoload/server.php
'mode' => \SWOOLE_PROCESS,
'settings' => [
    Constant::OPTION_WORKER_NUM => env('APP_DEBUG') ? 1 : swoole_cpu_num(),
    Constant::OPTION_MAX_COROUTINE => 100000,
    Constant::OPTION_MAX_REQUEST => 100000,
    Constant::OPTION_ENABLE_COROUTINE => true,
    ...
]
```

`APP_DEBUG=true` 时只有 1 个 worker，断点/日志都简单，这就是我们学习环境这样配的原因。

---

## 3. 协程（Coroutine）

### 3.1 它是什么

协程是**用户态**的调度单位，比线程轻得多。一个 worker 里可以有几十万个协程，内存开销大概 KB 级。

```php
use Swoole\Coroutine;

Coroutine::create(function () {
    // 这里运行在一个协程里
    echo Coroutine::getCid();   // 协程 ID
    Coroutine::sleep(1);        // 让出 CPU，1 秒后恢复
});
```

`Coroutine::getCid()` 在协程外返回 `-1`。

### 3.2 什么时候切换

只有在**遇到 IO** 时才会切换：

- `Coroutine::sleep()`
- 协程版 MySQL/Redis/HTTP 客户端
- 被 Hook 的 `sleep()`、`file_get_contents()`、`PDO`、`stream` 等

纯 CPU 计算不会切换。所以：

> **一个协程里跑 10 秒的 for 循环，会卡死整个 worker。**

Hyperf 里也是同理。CPU 密集任务要丢给 Task Worker、队列或独立进程。

### 3.3 并发对比

`lab/swoole/02-coroutine.php`：

```php
run(function () {
    for ($i = 1; $i <= 3; ++$i) {
        Coroutine::create(function () use ($i) {
            Coroutine::sleep(1.0);
            echo "协程 {$i} 结束\n";
        });
    }
});
```

3 个协程各睡 1 秒，总耗时约 1 秒。如果是 3 个进程各睡 1 秒，也是 1 秒；但协程的创建/切换成本低几个数量级。

### 3.4 Hook：让阻塞函数变成协程调度

```php
use Swoole\Runtime;

Runtime::enableCoroutine(SWOOLE_HOOK_ALL);
```

Hook 之后，`sleep()`、`usleep()`、`file_get_contents()`、`PDO`、`curl`（部分）等会被 Swoole 接管：调用时自动让出 CPU，IO 完成后唤醒协程。

Hyperf 在 `bin/hyperf.php` 里做了：

```php
! defined('SWOOLE_HOOK_FLAGS') && define('SWOOLE_HOOK_FLAGS', SWOOLE_HOOK_ALL);
```

所以你在 Hyperf 里可以直接用 `PDO`、`file_get_contents`，但**推荐用框架封装**（连接池、协程客户端），因为裸 PDO 会绕过连接池。

### 3.5 协程上下文

协程之间变量隔离。Swoole 提供 `Coroutine::getContext()`（5.x 里逐步被 `Coroutine::getContext()`/`Hyperf\Context\Context` 替代），Hyperf 封装了：

```php
use Hyperf\Context\Context;

Context::set('current_user', $user);
Context::get('current_user');
Context::has('current_user');
```

这个 `Context` 是**协程级**的，不是全局的。MineAdmin 用它缓存当前登录用户：

```php
// app/Http/CurrentUser.php
public static function ctxUser(): ?User
{
    return Context::get('current_user');
}
```

**不要**用 `static $user` 或 `$_SESSION` 存请求级数据，会串请求。

---

## 4. 协程间通信

### 4.1 Channel

```php
$channel = new Channel(2);       // 容量 2
$channel->push($data);           // 满了会挂起
$data = $channel->pop(1.0);      // 超时 1 秒，超时返回 false
$channel->close();
```

用途：生产者-消费者、并发任务结果收集、协程池。

`lab/swoole/03-channel.php` 演示了背压：容量满了生产者自动等待。

### 4.2 WaitGroup

```php
use Swoole\Coroutine\WaitGroup;

$wg = new WaitGroup();
foreach ($ids as $id) {
    $wg->add();
    go(function () use ($id, $wg) {
        try {
            // 并发处理
        } finally {
            $wg->done();
        }
    });
}
$wg->wait();
```

Hyperf 里常用 `Hyperf\Coroutine\Parallel` 或 `Hyperf\Coroutine\WaitGroup`。

### 4.3 共享内存：Table / Atomic

进程之间变量不共享，但：

```php
$table = new Swoole\Table(1024);
$table->column('count', Swoole\Table::TYPE_INT);
$table->create();      // 必须在 fork 之前
```

- `Table`：key-value 共享内存，适合计数、配置、连接元信息
- `Atomic`：单个 64 位原子整数，适合 QPS、限流计数
- `Swoole\Atomic\Long`：64 位
- `Swoole\Lock` / `Swoole\Coroutine\Lock`：互斥

`lab/swoole/01-process.php` 演示了父进程创建 Table、子进程写入、父进程读取。

Hyperf 的 `hyperf/metric`、限流器、`hyperf/atomic` 都基于这些。

---

## 5. 定时器与事件循环

```php
Swoole\Timer::after(200, fn () => print("200ms 后执行一次\n"));
$id = Swoole\Timer::tick(1000, fn () => print("每秒执行\n"));
Swoole\Timer::clear($id);
Swoole\Timer::clearAll();
```

CLI 脚本里定时器不会自己跑，需要：

```php
Swoole\Event::wait();
```

服务器模式下不需要，Swoole 自己跑事件循环。

用途：

- Hyperf 的 `#[Crontab]` 定时任务（在自定义进程里）
- 连接池心跳、超时检测
- 延迟任务、重试

`lab/swoole/04-timer-atomic.php`。

---

## 6. Task Worker

```php
$server->set([
    'task_worker_num' => 4,
]);

$server->on('Task', function ($server, $taskId, $workerId, $data) {
    // 处理耗时任务
    $server->finish('done');
});

$server->on('Finish', function ($server, $taskId, $data) {
    echo "任务完成：{$data}\n";
});

// 在 worker 里投递
$server->task(['type' => 'send_mail']);
```

特点：

- Task 进程**不能**直接和客户端通信，只能通过 `finish` 回传
- 适合 CPU 密集/不需要立即返回的任务
- Hyperf 里更推荐 `hyperf/async-queue`（Redis 队列）或 `hyperf/crontab`

---

## 7. Worker 生命周期与重启

| 事件 | 说明 |
|---|---|
| `onWorkerStart` | worker 启动，适合初始化连接池、注册定时器 |
| `onWorkerStop` | 正常退出 |
| `onWorkerExit` | 协程退出前 |
| `max_request` | 处理 N 个请求后自动重启 worker（防内存泄漏） |
| `SIGTERM` | 优雅停止 |
| `SIGUSR1` | reload（平滑重启 worker） |

Hyperf 的 `runtime/container/proxy` 是启动时生成的，所以：

- 改注解/新增类 → 必须重启（`server:watch` 会做）
- 生产环境不能靠 `reload` 加载新代码，必须重启进程

---

## 8. 内存与全局状态（最容易翻车的地方）

Swoole 常驻内存，所以：

### ❌ 错误写法

```php
class UserService
{
    private array $cache = [];   // 单例，跨请求累积

    public function get(int $id)
    {
        return $this->cache[$id] ??= $this->db->find($id);
    }
}
```

这个 `$cache` 会在 worker 生命周期内一直增长，而且不同用户可能读到别人的数据。

### ✅ 正确写法

- 请求级缓存放 `Hyperf\Context\Context`
- 跨请求缓存放 Redis / `hyperf/cache`
- 不要在单例里存请求相关状态

### 其他注意

- 不要 `exit` / `die`（会杀掉 worker）
- 不要用 `$_GET`、`$_POST`、`$_SERVER`，用 `RequestInterface`
- 不要用 `header()`、`setcookie()`，用 PSR-7 Response
- 静态变量初始化只在 worker 启动时执行一次
- 长生命周期对象（连接、客户端）注意连接可用性（`heartbeat`）

---

## 9. Swoole 版本差异（5.x / 6.x）

MineAdmin 3.2 要求 `ext-swoole >= 5.0`，部署镜像自带 6.x。学习时记住：

- 协程 API 在 5/6 基本一致：`Coroutine::create`、`Coroutine::sleep`、`Channel`、`WaitGroup`
- `Swoole\Coroutine::getContext()` 在 6.x 仍可用，但 Hyperf 推荐 `Hyperf\Context\Context`
- `swoole_async_set()`、`Coroutine::getuid()` 等旧 API 已移除/不推荐
- Swoole 6 要求 PHP >= 8.1
- 不要照抄 4.x 时代的教程（`Coroutine::getUid()`、`Swoole\Coroutine::set()` 的某些参数）

查版本：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\remote.ps1 exec -Command "php --ri swoole | head -n 20"
```

---

## 10. 映射到 Hyperf

| Swoole 概念 | Hyperf 对应 |
|---|---|
| Worker 进程 | `config/autoload/server.php` 的 `worker_num` |
| 每请求一个协程 | `Hyperf\HttpServer\Server::onRequest` |
| 协程上下文 | `Hyperf\Context\Context` |
| 连接池 | `Hyperf\Pool`（db/redis 配置里的 `pool`） |
| 定时器 | `#[Crontab]` + `CrontabDispatcherProcess` |
| Task Worker | `hyperf/async-queue`、`hyperf/process` |
| 协程并发 | `Hyperf\Coroutine\Parallel`、`WaitGroup`、`Channel` |
| 事件循环 | 框架启动，无需自己 `Event::wait()` |

下一篇：[03-Swoole实验课](03-Swoole实验课.md)
