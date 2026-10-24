# 04 Hyperf 核心原理

目标：能看懂 `MineAdmin` 里任何一个类是怎么被创建、被调用、被拦截的。

---

## 1. 启动流程

入口：`MineAdmin/bin/hyperf.php`

```php
require BASE_PATH . '/vendor/autoload.php';

(function () {
    Plugin::init();
    Hyperf\Di\ClassLoader::init();
    $container = require BASE_PATH . '/config/container.php';
    $application = $container->get(Hyperf\Contract\ApplicationInterface::class);
    $application->run();
})();
```

按顺序发生了什么：

1. **Composer autoload**：注册 PSR-4（`App\ => app/`）和所有依赖的类映射
2. **`Plugin::init()`**：MineAdmin 的插件初始化（`plugin/` 目录）
3. **`ClassLoader::init()`**：把 `runtime/container/proxy` 里的代理类注册进 autoload（AOP 的基础）
4. **`config/container.php`**：创建 PSR-11 容器
   ```php
   return ApplicationContext::setContainer(new Container((new DefinitionSourceFactory())()));
   ```
5. **`$application->run()`**：解析命令行参数
   - `php bin/hyperf.php start` → 启动 Swoole 服务器
   - `php bin/hyperf.php migrate` → 执行命令
   - `php bin/hyperf.php server:watch` → 热更新模式

Swoole 服务器的启动由 `hyperf/server` + `hyperf/framework` 完成，最终按 `config/autoload/server.php` 建 Server、注册回调、`start()`。

---

## 2. 容器与依赖注入

### 2.1 自动注入

构造函数参数会自动从容器解析：

```php
final class PassportService
{
    public function __construct(
        protected readonly UserRepository $repository,
        protected readonly Factory $jwtFactory,
        protected readonly EventDispatcherInterface $dispatcher
    ) {}
}
```

只要 `UserRepository`、`Factory` 能被容器创建（有构造函数或无参），就能自动注入。

接口需要绑定实现，见 `config/autoload/dependencies.php`：

```php
return [
    UploadInterface::class => Factory::class,
    CheckTokenInterface::class => PassportService::class,
];
```

### 2.2 属性注入

```php
use Hyperf\Di\Annotation\Inject;

class Foo
{
    #[Inject]
    protected Bar $bar;

    #[Inject]
    protected RedisFactory $redis;   // 按类型
}
```

注意：

- 属性注入依赖代理类，**必须在启动时扫描**，热更新重启后生效
- 能用构造函数注入就别用属性注入（可测试、依赖明确）

### 2.3 手动取对象

```php
use Hyperf\Context\ApplicationContext;

$service = ApplicationContext::getContainer()->get(SomeService::class);
// 或
$service = make(SomeService::class);
```

MineAdmin 的 `AbstractController::getRequest()` 就是这么拿 `RequestInterface` 的。

### 2.4 注解扫描

`config/autoload/annotations.php`：

```php
'scan' => [
    'paths' => [
        BASE_PATH . '/app',
        BASE_PATH . '/kernel',
    ],
],
```

每个 Composer 包的 `ConfigProvider` 还会把自己加进去（例如 `Mine\Access\ConfigProvider`），所以 vendor 里的注解也能被识别。

扫描结果会缓存到 `runtime/container`，`APP_DEBUG=true` 时每次都重新扫描（慢但改代码不用清缓存）。

### 2.5 代理类

Hyperf 的 AOP / 注解 / `#[Inject]` 都依赖**运行时生成代理类**：

- 位置：`runtime/container/proxy/`
- 启动时生成，`server:watch` 重启会重新生成
- 所以：改了注解、加了类却没生效，先重启；还不行就删 `runtime/container` 再启动

---

## 3. 注解（Attribute）

Hyperf 用 PHP 8 原生 Attribute + 自己的 AnnotationCollector。

常见：

| 注解 | 作用 |
|---|---|
| `#[Controller]` | 声明控制器（MineAdmin 3.2 没用到，见下） |
| `#[GetMapping]` / `#[PostMapping]` | 控制器方法路由 |
| `#[Middleware]` | 中间件 |
| `#[Inject]` | 属性注入 |
| `#[Value]` | 注入配置值 |
| `#[Constants]` | 注入常量 |
| `#[Aspect]` | 切面 |
| `#[Listener]` | 事件监听器 |
| `#[Crontab]` | 定时任务 |
| `#[Permission]` | MineAdmin 自定义权限注解 |

查看某个控制器的注解怎么被收集：

```php
use Hyperf\Di\Annotation\AnnotationCollector;

AnnotationCollector::getClassAnnotation(SomeController::class, Permission::class);
AnnotationCollector::getClassMethodAnnotation(SomeController::class, 'index');
```

MineAdmin 的 `PermissionMiddleware` 就是这么做的。

---

## 4. AOP（切面）

### 4.1 写法

```php
#[Aspect]
class LogAspect extends AbstractAspect
{
    // 拦截带有该注解的类/方法
    public array $annotations = [SomeAnnotation::class];

    // 或者直接拦截某个类的某个方法
    public array $classes = [SomeService::class . '::someMethod'];

    public function process(ProceedingJoinPoint $point)
    {
        $start = microtime(true);
        $result = $point->process();      // 执行原方法
        $this->log($point->className, $point->methodName, microtime(true) - $start);
        return $result;
    }
}
```

`#[Aspect]` 的 `priority` 越大越先执行（默认 0）。

### 4.2 MineAdmin 的真实例子

`app/Library/DataPermission/Aspects/DataScopeAspect.php`：

```php
#[Aspect]
final class DataScopeAspect extends AbstractAspect
{
    public array $annotations = [DataScope::class];

    public array $classes = [
        Builder::class . '::update',
        Builder::class . '::delete',
        Builder::class . '::runSelect',
    ];

    public function process(ProceedingJoinPoint $proceedingJoinPoint)
    {
        ...
        // 在 SQL 真正执行前，给 Builder 加上数据权限条件
        $this->factory->build($builder, $user);
        return $proceedingJoinPoint->process();
    }
}
```

它做了两件事：

1. 拦截带 `#[DataScope]` 注解的类/方法，把数据权限配置写进 `Context`
2. 拦截 `Hyperf\Database\Query\Builder` 的 `runSelect/update/delete`，在 SQL 执行前注入部门/创建人条件

这是"横切关注点"的典型用法：业务代码不用写权限过滤，切面统一处理。

### 4.3 AOP 的边界

- 只拦截**容器创建的对象**的方法调用（`new` 出来的对象不会被代理）
- `final` 类/方法、静态方法拦截受限
- 代理类生成失败会导致启动报错，先看 `runtime/container/proxy` 和日志

---

## 5. HTTP 请求生命周期

```
Swoole onRequest
   ↓
Hyperf\HttpServer\Server::onRequest
   ↓
CoreMiddleware::dispatch
   ↓  全局中间件（config/autoload/middlewares.php）
   ↓  路由匹配（DispatcherFactory → 注解路由）
   ↓  路由/控制器中间件（#[Middleware]）
   ↓
Controller 方法（依赖注入 Request / Service）
   ↓
返回 Result（Arrayable）/ array / string / ResponseInterface
   ↓
CoreMiddleware::transferToResponse
   ↓
Swoole 响应
```

`transferToResponse` 的规则（`vendor/hyperf/http-server/src/CoreMiddleware.php`）：

| 返回值 | 响应 |
|---|---|
| `string` | `text/plain` |
| `ResponseInterface` | 原样返回 |
| `array` / `Arrayable` | `application/json` |
| `Jsonable` | `application/json` |
| `Htmlable` | `text/html` |
| 其他 | 强转字符串 |

MineAdmin 统一返回 `App\Http\Common\Result`，它实现了 `Arrayable`：

```php
return [
    'code' => $this->code->value,
    'message' => $this->message,
    'data' => $this->data,
];
```

所以控制器里 `return $this->success($data)` 就会被转成 JSON。

### 异常处理

`config/autoload/exceptions.php` 按顺序注册 handler：

```php
'handler' => [
    'http' => [
        ModeNotFoundHandler::class,
        BusinessExceptionHandler::class,
        UnauthorizedExceptionHandler::class,
        ValidationExceptionHandler::class,
        JwtExceptionHandler::class,
        AppExceptionHandler::class,
    ],
],
```

- 业务异常 `BusinessException` → 统一 `{code, message, data}`
- 参数校验失败 → `ValidationExceptionHandler`
- JWT 异常 → `JwtExceptionHandler`
- 兜底 `AppExceptionHandler`（生产环境不输出堆栈）

自定义异常时，加一个 handler 并注册到这里即可。

---

## 6. 中间件

### 6.1 全局中间件

`config/autoload/middlewares.php`：

```php
'http' => [
    RequestIdMiddleware::class,      // 请求 ID
    TranslationMiddleware::class,    // 多语言
    CorsMiddleware::class,           // 跨域
    ValidationMiddleware::class,     // FormRequest 校验
],
```

全局中间件对所有请求生效，顺序即数组顺序。

### 6.2 路由/控制器中间件

```php
#[Middleware(middleware: AccessTokenMiddleware::class, priority: 100)]
#[Middleware(middleware: PermissionMiddleware::class, priority: 99)]
#[Middleware(middleware: OperationMiddleware::class, priority: 98)]
class PositionController extends AbstractController
```

`priority` 越大越先执行。方法上的 `#[Middleware]` 会追加到类级别之后。

MineAdmin 的鉴权链：

1. `AccessTokenMiddleware`：解析并校验 JWT，写 `Context`
2. `PermissionMiddleware`：检查用户状态 + `#[Permission]` 代码
3. `OperationMiddleware`：记录操作日志（异步）

### 6.3 写一个中间件

```php
use Psr\Http\Message\ResponseInterface;
use Psr\Http\Message\ServerRequestInterface;
use Psr\Http\Server\MiddlewareInterface;
use Psr\Http\Server\RequestHandlerInterface;

final class DemoMiddleware implements MiddlewareInterface
{
    public function process(ServerRequestInterface $request, RequestHandlerInterface $handler): ResponseInterface
    {
        $response = $handler->handle($request);
        return $response->withHeader('X-Demo', '1');
    }
}
```

注册到 `config/autoload/middlewares.php` 或控制器 `#[Middleware]`。

---

## 7. 协程上下文与连接池

### 7.1 Context

```php
use Hyperf\Context\Context;

Context::set('key', $value);
Context::get('key', $default);
Context::has('key');
Context::destroy('key');
```

- 协程级隔离，请求结束自动释放（配合 `Context::destroy` 或协程销毁）
- MineAdmin 用它缓存 `current_user`
- 不要在 Context 里放连接对象（连接由池管理）

### 7.2 数据库连接池

`config/autoload/databases.php`：

```php
'pool' => [
    'min_connections' => 1,
    'max_connections' => 20,
    'connect_timeout' => 10.0,
    'wait_timeout' => 3.0,
    'heartbeat' => -1,
    'max_idle_time' => 60,
],
```

规则：

- 每个 worker 独立一个池（`worker_num=4` 就是 4 个池）
- 协程从池里借连接，用完归还
- `wait_timeout` 内拿不到连接会抛异常 → 检查是否连接泄漏（没释放）或 `max_connections` 太小
- 不要手动 `new PDO`，会绕过连接池

Redis 同理，见 `config/autoload/redis.php`。

### 7.3 常见泄漏

```php
// ❌ 协程里开了事务但异常没回滚/释放
Db::beginTransaction();
... // 抛异常
```

用 `Db::transaction(function () { ... })`，框架会处理回滚。

---

## 8. 事件

### 8.1 定义与监听

```php
// 事件类：普通 PHP 对象
final class UserRegistered
{
    public function __construct(public int $userId) {}
}
```

```php
use Hyperf\Event\Annotation\Listener;
use Hyperf\Event\Contract\ListenerInterface;

#[Listener]
final class SendWelcomeMail implements ListenerInterface
{
    public function listen(): array
    {
        return [UserRegistered::class];
    }

    public function process(object $event): void
    {
        // ...
    }
}
```

派发：

```php
$this->dispatcher->dispatch(new UserRegistered($id));
```

### 8.2 MineAdmin 的例子

`PassportService::login()` 里：

```php
$this->dispatcher->dispatch(new UserLoginEvent($user, $ip, $os, $browser));
```

`app/Http/Admin/Subscriber/Logstash/UserLoginSubscriber.php`：

```php
#[Listener]
class UserLoginSubscriber implements ListenerInterface
{
    public function process(object $event): void
    {
        Coroutine::create(fn () => $this->userService->save([...]));
    }
}
```

注意 `Coroutine::create`：登录日志异步写，不阻塞登录响应。这是 Hyperf 里常见的"事件 + 协程"组合。

> 注意：协程创建后若请求结束，协程仍会继续执行（Hyperf 会等待？实际上 `Coroutine::create` 脱离当前协程，请求结束后仍可能执行）。生产环境更稳的做法是丢队列。

---

## 9. 自定义进程、定时任务、队列

### 9.1 自定义进程

`config/autoload/processes.php`：

```php
return [
    CrontabDispatcherProcess::class,
];
```

自己写：

```php
class MyProcess
{
    public function __construct(private LoggerInterface $logger) {}

    public function handle(): void
    {
        while (true) {
            // 处理任务
            Coroutine::sleep(1);
        }
    }
}
```

注册到 `processes.php`，它会在 Swoole 启动时拉起。

### 9.2 定时任务

```php
use Hyperf\Crontab\Annotation\Crontab;

#[Crontab(name: 'Demo', rule: '*/5 * * * *', callback: 'execute', memo: '每5分钟')]
class DemoTask
{
    public function execute(): void
    {
        // ...
    }
}
```

`CrontabDispatcherProcess` 负责调度。规则是标准 crontab 5 段。

### 9.3 异步队列

`hyperf/async-queue` 已安装，可以把耗时任务丢 Redis 队列，由独立进程消费。适合发邮件、生成报表、同步第三方。

---

## 10. 日志与调试

- 应用日志：`runtime/logs/debug.log`
- SQL 日志：`runtime/logs/sql.log`（`config/autoload/logger.php` 里定义的 `sql` channel）
- 标准输出：`docker compose logs -f app`
- `StdoutLoggerInterface` 的日志级别在 `config/config.php` 配置

调试手段：

```powershell
# 交互式 shell
powershell -ExecutionPolicy Bypass -File scripts\remote.ps1 tinker

# 执行命令
powershell -ExecutionPolicy Bypass -File scripts\remote.ps1 exec -Command "php bin/hyperf.php list"

# 看日志
powershell -ExecutionPolicy Bypass -File scripts\remote.ps1 exec -Command "tail -n 200 runtime/logs/debug.log"
```

> 不要用 `var_dump` + `exit` 调试常驻进程，`exit` 会杀掉 worker。用日志，或临时 `throw`。

---

## 11. 测试

仓库自带 PHPUnit：

```bash
composer test
```

Hyperf 提供 `Hyperf\Testing\Client` 做 HTTP 测试，`co-phpunit` 在协程里跑测试。

学习阶段可以先跳过测试，但写完 CRUD 后建议补一个 Feature 测试。

---

## 12. 这一篇的自测

1. `bin/hyperf.php` 到 Swoole 启动之间发生了什么？
2. 为什么改了注解要重启？`runtime/container` 里是什么？
3. `#[Inject]` 和构造函数注入有什么区别？
4. 全局中间件和控制器中间件的执行顺序？
5. 控制器返回 `Result` 后，谁把它变成 JSON？
6. 连接池的 `max_connections` 是每个进程还是全局？
7. `Context` 和普通 `static` 属性有什么区别？
8. 为什么登录日志要用 `Coroutine::create`？

下一篇：[05-MineAdmin源码导读](05-MineAdmin源码导读.md)
