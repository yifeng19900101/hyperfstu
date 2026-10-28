<?php

declare(strict_types=1);
/**
 * This file is part of MineAdmin.
 *
 * @link     https://www.mineadmin.com
 * @document https://doc.mineadmin.com
 * @contact  root@imoi.cn
 * @license  https://github.com/mineadmin/MineAdmin/blob/master/LICENSE
 */

namespace App\Http\Admin\Controller;

use App\Http\Common\Result;
use Hyperf\Redis\Redis as RedisClient;
use Hyperf\Redis\RedisFactory;
use Hyperf\Swagger\Annotation\Delete;
use Hyperf\Swagger\Annotation\Get;
use Hyperf\Swagger\Annotation\HyperfServer;
use Hyperf\Swagger\Annotation\JsonContent;
use Hyperf\Swagger\Annotation\Post;
use Hyperf\Swagger\Annotation\RequestBody;
use Mine\Swagger\Attributes\ResultResponse;
use OpenApi\Attributes\Property;
use Psr\SimpleCache\CacheInterface;

/**
 * Redis 入门示例控制器（学习用）。
 *
 * ============================================================================
 * 【最关键的一件事】为什么注入 \Redis 就能用？
 * ============================================================================
 * Hyperf 在 hyperf/redis 的 ConfigProvider 里做了类型绑定：
 *
 *     'dependencies' => [
 *         \Redis::class => \Hyperf\Redis\Redis::class,
 *     ]
 *
 * 所以下面构造函数里写 `\Redis $redis` 或 `RedisClient $redis`，容器给你的
 * 都不是原生 phpredis 对象，而是 Hyperf 的「代理类」。它内部做的事：
 *
 *     1. 从『当前协程』的连接池借一条真正的 phpredis 连接
 *     2. 把命令转发给这条连接
 *     3. 命令执行完（finally 里）把连接 push 回池
 *
 * 因此你的写法是同步的，但底层 socket 读写在 Swoole Hook 下会自动挂起协程，
 * 不会阻塞 worker。这就是「一个进程能同时处理很多请求」的来源。
 *
 * ============================================================================
 * 【强烈建议】业务代码用 CacheInterface，而不是直接 CMD
 * ============================================================================
 * 直接 $redis->set() 得到的是「裸字符串」，存数组必须自己 json_encode，
 * 而且序列化/前缀/TTL 都要自己管。Hyperf 的缓存组件已经处理好这些
 * （见下面 arrayDemo 方法），它的绑定是：
 *
 *     Psr\SimpleCache\CacheInterface  =>  Hyperf\Cache\Cache
 *
 * 底层 store 也是 Redis（config/autoload/cache.php 里配的 RedisDriver），
 * 所以它和 $redis 用的是【同一个池】、同一批连接，只是多了层包装。
 * 注意前提：CacheInterface 会自动序列化（项目配的是 PhpSerializerPacker），
 * 所以用 redis-cli 直接 get 那个 key，看到的是 PHP 序列化串而不是 JSON。
 *
 * ============================================================================
 * 【安全提示】本控制器没有挂任何鉴权中间件，方便你 curl 直接试。
 * 生产环境请删除本文件，或至少加上：
 *     #[Middleware(middleware: AccessTokenMiddleware::class, priority: 100)]
 *     #[Middleware(middleware: PermissionMiddleware::class, priority: 99)]
 * ============================================================================
 */
#[HyperfServer(name: 'http')]
final class RedisDemoController extends AbstractController
{
    /**
     * 两种注入方式，任选其一，这里都写出来对照：
     *
     *   $redis        —— 直接要一个「default 池」的代理（最常用）
     *   $redisFactory —— 有多个池（见 config/autoload/redis.php）时，按名字取
     *
     * 注意：这两个对象都是【单例】，可以放心注入，不会每次都新建连接。
     * 真正的连接是「按协程」从池里借的，不是按类实例。
     */
    public function __construct(
        protected readonly RedisClient $redis,
        protected readonly RedisFactory $redisFactory,
        protected readonly CacheInterface $cache,
    ) {}

    /* =========================================================================
     * 1. SET —— 写入一个字符串
     * =========================================================================
     * POST /hyperfproapi/admin/redis-demo/set
     * body: {"key":"demo:name","value":"mineadmin","ttl":60}
     */
    #[Post(
        path: '/admin/redis-demo/set',
        operationId: 'redisDemoSet',
        summary: 'Redis 示例：写入一个字符串',
        tags: ['admin:redis-demo'],
    )]
    #[RequestBody(
        content: new JsonContent(
            properties: [
                new Property(property: 'key', type: 'string', example: 'demo:name'),
                new Property(property: 'value', type: 'string', example: 'mineadmin'),
                new Property(property: 'ttl', type: 'integer', example: 60),
            ],
            required: ['key', 'value'],
        )
    )]
    #[ResultResponse(instance: new Result())]
    public function set(): Result
    {
        $key = (string) $this->getRequest()->input('key', '');
        $value = (string) $this->getRequest()->input('value', '');
        $ttl = (int) $this->getRequest()->input('ttl', 0);

        if ($key === '') {
            return $this->error('key 不能为空');
        }

        // ── 写法 A：不过期 ──────────────────────────────────────────────
        // $redis->set() 返回 bool。这里的 $this->redis 是 Hyperf 代理，
        // 调用时自动借连接 → 执行 → 还连接，全程你不需要管连接。
        //
        // 这行代码在协程里执行时，底层 recv() 若返回 EAGAIN，会挂起当前协程、
        // 转去跑别的请求，数据到达后再恢复。所以你写的是同步代码，
        // 实际行为是非阻塞的。
        if ($ttl <= 0) {
            $ok = $this->redis->set($key, $value);
            return $this->success([
                'key' => $key,
                'value' => $value,
                'ttl' => null,
                'result' => $ok,
                // 查一下剩余有效期：-1 = 永久，-2 = 不存在
                'ttl_left' => $this->redis->ttl($key),
            ]);
        }

        // ── 写法 B：带过期时间（推荐，避免脏数据永久堆积）─────────────
        // setex = SET + EXPIRE 的原子版本，等价于 SET key value EX ttl。
        // 不要写成「set 之后再 expire」，那样中间会有一个「永不过期」的窗口。
        $ok = $this->redis->setex($key, $ttl, $value);

        return $this->success([
            'key' => $key,
            'value' => $value,
            'ttl' => $ttl,
            'result' => $ok,
            'ttl_left' => $this->redis->ttl($key),
        ]);
    }

    /* =========================================================================
     * 2. GET —— 读取
     * =========================================================================
     * GET /hyperfproapi/admin/redis-demo/get?key=demo:name
     */
    #[Get(
        path: '/admin/redis-demo/get',
        operationId: 'redisDemoGet',
        summary: 'Redis 示例：读取一个字符串',
        tags: ['admin:redis-demo'],
    )]
    #[ResultResponse(instance: new Result())]
    public function get(): Result
    {
        $key = (string) $this->getRequest()->input('key', '');
        if ($key === '') {
            return $this->error('key 不能为空');
        }

        // get() 在 key 不存在时返回 false（不是 null，也不是空字符串）。
        // 这一点很容易踩坑：`if (!$value)` 会把 '' 和 '0' 也当成不存在，
        // 所以判断必须用 === false。
        $value = $this->redis->get($key);

        // exists() 返回的是「存在的 key 数量」：单 key 就是 0 或 1。
        // 它比 get() 轻，只判断存在性时用它。
        $exists = $this->redis->exists($key);

        return $this->success([
            'key' => $key,
            'exists' => (bool) $exists,
            // 用 === false 判断，不用 empty()
            'value' => $value === false ? null : $value,
            'type' => $value === false ? null : gettype($value),
            'ttl_left' => $this->redis->ttl($key),
        ]);
    }

    /* =========================================================================
     * 3. 删除 / 计数 —— 演示「原子」操作
     * =========================================================================
     * DELETE /hyperfproapi/admin/redis-demo/delete?key=demo:name
     */
    #[Delete(
        path: '/admin/redis-demo/delete',
        operationId: 'redisDemoDelete',
        summary: 'Redis 示例：删除 key',
        tags: ['admin:redis-demo'],
    )]
    #[ResultResponse(instance: new Result())]
    public function delete(): Result
    {
        $key = (string) $this->getRequest()->input('key', '');
        if ($key === '') {
            return $this->error('key 不能为空');
        }

        // del() 返回「实际删掉的 key 数量」。删一个已不存在的 key 返回 0，
        // 不会报错，所以别用抛异常的方式判断是否删成功。
        $deleted = $this->redis->del($key);

        return $this->success([
            'key' => $key,
            'deleted' => $deleted,
        ]);
    }

    /* =========================================================================
     * 4. INCR —— 为什么计数器必须用 Redis 而不是「查出来 +1 再写回」
     * =========================================================================
     * POST /hyperfproapi/admin/redis-demo/incr?key=demo:counter
     *
     * 错误写法（有并发 bug）：
     *     $n = (int) $redis->get($key);   // 协程 A 读到 100
     *     $redis->set($key, $n + 1);      // 协程 B 也读到 100，两者都写 101
     *
     * 正确写法：INCR 在 Redis 服务端执行，是单线程原子的，不可能丢更新。
     */
    #[Post(
        path: '/admin/redis-demo/incr',
        operationId: 'redisDemoIncr',
        summary: 'Redis 示例：原子自增',
        tags: ['admin:redis-demo'],
    )]
    #[ResultResponse(instance: new Result())]
    public function incr(): Result
    {
        $key = (string) $this->getRequest()->input('key', 'demo:counter');

        // incr 返回自增后的新值。
        // 注意：这个操作【不是】幂等的。如果因为读超时触发了 Hyperf 的
        // 自动重试（RedisConnection::retry），命令可能被执行两次。
        // 对计数类业务，要么接受这个误差，要么用 Lua 脚本保证。
        $after = $this->redis->incr($key);

        // 计数器也要设过期时间，否则 key 会永久存在。
        // 用 expire 而不是 setex：INCR 之后再设，避免覆盖当前值。
        // 这里只在第一次自增时设（结果为 1 说明是新建的）。
        if ((int) $after === 1) {
            $this->redis->expire($key, 3600);
        }

        return $this->success([
            'key' => $key,
            'value' => (int) $after,
            'ttl_left' => $this->redis->ttl($key),
        ]);
    }

    /* =========================================================================
     * 5. 存数组：必须自己序列化
     * =========================================================================
     * POST /hyperfproapi/admin/redis-demo/array
     *
     * 【常见错误】
     *     $redis->set('k', ['a' => 1]);
     *   phpredis 会把数组转成字符串 "Array"，并抛 Warning，
     *   再 get 出来得到 "Array" 这个字符串——数据彻底丢了，而且不报致命错。
     *
     * 两个正确做法：
     *   A. 自己 json_encode / json_decode（控制力最强）
     *   B. 改用 CacheInterface（推荐，自动处理序列化 + 前缀 + TTL）
     */
    #[Post(
        path: '/admin/redis-demo/array',
        operationId: 'redisDemoArray',
        summary: 'Redis 示例：存数组（JSON）',
        tags: ['admin:redis-demo'],
    )]
    #[ResultResponse(instance: new Result())]
    public function arrayDemo(): Result
    {
        $key = 'demo:user:1';

        // ── A. 手动 JSON 序列化 ────────────────────────────────────────
        $user = [
            'id' => 1,
            'username' => 'admin',
            'roles' => ['SuperAdmin'],
            'created_at' => date('Y-m-d H:i:s'),
        ];

        // JSON_UNESCAPED_UNICODE：让中文以原文存储，方便用 redis-cli 直接看
        $this->redis->setex($key, 300, json_encode($user, JSON_UNESCAPED_UNICODE));

        $raw = $this->redis->get($key);

        // json_decode 第二个参数 true → 得到关联数组而不是 stdClass
        // 反序列化一定要考虑失败：数据被别的代码写坏时 decode 会返回 null
        $decoded = $raw === false ? null : json_decode($raw, true);

        // ── B. 用 CacheInterface（同样的数据，更省心）──────────────────
        // 不需要自己 json_encode，也不需要管前缀；缓存 key 会自动加上
        // config/autoload/cache.php 里配的 'MineAdmin:' 前缀。
        // set($key, $value, $ttl) 的 TTL 单位是秒。
        $this->cache->set('demo:cache:user:1', $user, 300);
        $fromCache = $this->cache->get('demo:cache:user:1');

        return $this->success([
            'raw_string' => $raw === false ? null : $raw,
            'json_decoded' => $decoded,
            'from_cache' => $fromCache,
            'cache_hit' => $fromCache !== null,
            'note' => 'raw_string 是字符串；json_decoded / from_cache 才是数组',
            'cache_note' => 'CacheInterface 会自动序列化，redis-cli 看到的是序列化串，不是 JSON',
        ]);
    }

    /* =========================================================================
     * 6. Hash —— 适合「一条记录多个字段，且要单独更新某个字段」
     * =========================================================================
     * GET /hyperfproapi/admin/redis-demo/hash
     *
     * 对比：
     *   String + JSON ：读要全读、写要全写，改一个字段也得反序列化整个对象
     *   Hash          ：可以只 hSet 一个字段、只 hGet 一个字段
     */
    #[Get(
        path: '/admin/redis-demo/hash',
        operationId: 'redisDemoHash',
        summary: 'Redis 示例：Hash 结构',
        tags: ['admin:redis-demo'],
    )]
    #[ResultResponse(instance: new Result())]
    public function hash(): Result
    {
        $key = 'demo:config:1';

        // hSet 一次写多个字段：phpredis 2.x+ 支持传数组，返回写入的字段数
        $this->redis->hSet($key, 'site_name', 'MineAdmin');
        $this->redis->hSet($key, 'version', '3.2');
        $this->redis->hSet($key, 'debug', '1');

        // 只改一个字段：不需要像 JSON 那样先读整个对象再整体写回
        $this->redis->hSet($key, 'debug', '0');

        // hGetAll 返回关联数组。注意：所有值都是字符串，'0' 不会变成 int
        $all = $this->redis->hGetAll($key);

        // Hash 也要单独设过期时间（expire 对 hash 整体生效）
        $this->redis->expire($key, 600);

        return $this->success([
            'key' => $key,
            'hGet_site_name' => $this->redis->hGet($key, 'site_name'),
            'hGetAll' => $all,
            'hKeys' => $this->redis->hKeys($key),
            'field_count' => $this->redis->hLen($key),
            'ttl_left' => $this->redis->ttl($key),
            'note' => 'hGetAll 的值全是 string 类型，需要 int 请自己转换',
        ]);
    }

    /* =========================================================================
     * 7. 多池：什么时候需要 RedisFactory
     * =========================================================================
     * GET /hyperfproapi/admin/redis-demo/pools
     *
     * 应用场景举例：
     *   池 default  → 普通缓存，db=0
     *   池 session  → 会话，db=1
     *   池 queue    → 队列/BLPOP 这种长期占用连接的，单独一个池
     *
     * 【重要】不要把 BLPOP 这类「阻塞命令」和普通命令放同一个池。
     * 阻塞命令会让那条连接一直被占用（max_connections 默认 10），
     * 开 11 个阻塞协程就会触发 "Connection pool exhausted"。
     */
    #[Get(
        path: '/admin/redis-demo/pools',
        operationId: 'redisDemoPools',
        summary: 'Redis 示例：连接池信息',
        tags: ['admin:redis-demo'],
    )]
    #[ResultResponse(instance: new Result())]
    public function pools(): Result
    {
        // 按池名取代理对象。池名 = config/autoload/redis.php 的顶层 key
        $default = $this->redisFactory->get('default');

        // ping() 用来验证连接是否真的可用，返回 true（或 '+PONG'）
        $pong = $default->ping();

        return $this->success([
            'ping' => $pong,
            'info_clients' => $default->info('clients'),
            'note' => 'max_connections 是【每个 worker】的配额，不是整个应用共享',
        ]);
    }

    /* =========================================================================
     * 8. 常见的三个错误写法（对照着看，别踩）
     * =========================================================================
     *
     * ❌ 错误 1：自己 new \Redis()
     *      $r = new \Redis();
     *      $r->connect('127.0.0.1', 6379);
     *    问题：绕过了连接池。每个请求新建一条 TCP 连接并握手，
     *    高并发时 Redis 侧 connected_clients 暴涨，还会堆 TIME_WAIT。
     *    正确：注入 \Redis 或 RedisFactory。
     *
     * ❌ 错误 2：在事务里开子协程
     *      $redis->multi();
     *      Coroutine::create(fn () => $redis->set('a', 1));  // 不在事务里！
     *      $redis->exec();
     *    问题：子协程的 Context 是全新的，会从池里另借一条连接，
     *    那条 set 根本不在事务范围内。而且【不会报错】，静默失效。
     *
     * ❌ 错误 3：在子协程里用 CurrentUser / RequestContext
     *      Coroutine::create(function () {
     *          $id = $this->currentUser->id();   // 抛异常：拿不到 token
     *      });
     *    问题：Swoole 子协程不继承父协程的 Context。
     *    正确：在父协程里先把需要的值取出来，再 use 进闭包。
     *    （MineAdmin 的 Subscriber 就是这么做的：userId 在事件构造时就传进去了）
     *
     * ❌ 错误 4：KEYS * / 大 SMEMBERS
     *      $redis->keys('user:*');
     *    问题：Redis 是单线程的，KEYS 会阻塞整个 Redis 服务端，
     *    你所有 worker 的 Redis 请求都会一起排队。
     *    正确：用 SCAN（或 SMEMBERS 换成 SSCAN 分批）。
     */
}
