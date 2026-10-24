# 05 MineAdmin 源码导读

目标：从"登录接口"这一条线，把 MineAdmin 3.2 的骨架串起来。看完你应该知道新加一个接口要改哪些文件。

---

## 1. 目录地图

```
app/
├─ Command/                 # 命令行：mine:install、mine:update
├─ Exception/               # 业务异常 + 全局异常处理器
├─ Http/
│  ├─ Admin/Controller/     # 后台接口（/admin/*）
│  ├─ Admin/Middleware/     # 权限中间件
│  ├─ Admin/Request/        # FormRequest 参数校验
│  ├─ Admin/Subscriber/     # 事件监听（登录日志、操作日志）
│  ├─ Api/Controller/       # 前台接口（/api/*）
│  ├─ Common/               # Result、公共中间件、公共控制器
│  └─ CurrentUser.php       # 当前用户（基于协程 Context）
├─ Library/DataPermission/  # 数据权限（AOP 实现）
├─ Model/                   # 模型（Permission/User、Role、Menu...）
├─ Repository/              # 数据访问层（IRepository 基类）
├─ Schema/                  # Swagger Schema（接口文档结构）
└─ Service/                 # 业务层（IService 基类）
config/
├─ autoload/server.php      # Swoole 配置
├─ autoload/watcher.php     # 热更新配置
├─ autoload/swagger.php     # 路由 + 文档（关键）
├─ autoload/middlewares.php # 全局中间件
├─ autoload/dependencies.php# 接口绑定
└─ routes.php               # 只有 / 和 /favicon.ico
databases/
├─ migrations/              # 建表
└─ seeders/                 # 初始化数据（菜单、用户）
plugin/                     # 插件（app-store）
```

---

## 2. 路由：为什么没有 `#[Controller]`

这是 MineAdmin 3.2 最容易被忽略的一点。

控制器：

```php
// app/Http/Admin/Controller/PassportController.php
#[OA\HyperfServer(name: 'http')]
final class PassportController extends AbstractController
{
    #[Post(path: '/admin/passport/login', operationId: 'passportLogin', summary: '系统登录')]
    public function login(PassportLoginRequest $request): Result
}
```

`#[Post]` 来自 `Hyperf\Swagger\Annotation\Post`，本来是 OpenAPI 文档注解，但 MineAdmin 把它当路由用。

注册代码：`vendor/hyperf/swagger/src/Listener/BootSwaggerListener.php`

```php
$config = $this->container->get(ConfigInterface::class);
if (! $config->get('swagger.enable', false)) {
    return;
}
...
foreach ([SA\Get::class, SA\Post::class, ...] as $annotation) {
    foreach (AnnotationCollector::getMethodsByAnnotation($annotation) as $item) {
        $serverAnnotations = Util::findAnnotations($methodAnnotations, SA\HyperfServer::class)
            ?: Util::findAnnotations($classAnnotations, SA\HyperfServer::class);

        $factory->getRouter($serverAnnotation->name)->addRoute(
            [$opera->method],
            $opera->path,
            [$class, $method],
            ['middleware' => ...]
        );
    }
}
```

所以：

- **`SWAGGER_ENABLED=true` 是路由生效的前提**
- `#[HyperfServer(name: 'http')]` 决定注册到哪个 server（对应 `config/autoload/server.php` 里 `name => 'http'`）
- `path` 就是 URL，`#[Middleware]` 会被合并进路由的 middleware
- 想改路由，改注解里的 `path`

`config/routes.php` 里只有两个手写路由（`/` 和 `/favicon.ico`），其余全是注解注册。

---

## 3. 登录全链路

### 3.1 请求

```
POST /admin/passport/login
{"username":"admin","password":"123456"}
```

### 3.2 中间件与校验

1. 全局中间件（`config/autoload/middlewares.php`）
   - `RequestIdMiddleware`：生成/透传 `X-Request-Id`，日志里能串起来
   - `TranslationMiddleware`：根据 `Accept-Language` 切语言
   - `CorsMiddleware`：跨域
   - `ValidationMiddleware`：执行 `FormRequest::rules()`
2. `PassportLoginRequest`（`app/Http/Admin/Request/PassportLoginRequest.php`）

```php
public function rules(): array
{
    return [
        'username' => 'required|string|exists:user,username',
        'password' => 'required|string',
    ];
}
```

校验失败会抛 `ValidationException`，由 `ValidationExceptionHandler` 统一返回。

注意它用了 `NoAuthorizeTrait`：登录接口不需要鉴权，否则会死循环。

### 3.3 控制器

```php
public function login(PassportLoginRequest $request): Result
{
    return $this->success(
        $this->passportService->login(
            (string) $request->input('username'),
            (string) $request->input('password'),
            Type::SYSTEM,
            $request->ip(),
            $request->header('User-Agent') ?: 'unknown',
            $request->os()
        )
    );
}
```

控制器只做参数搬运，业务在 Service。

### 3.4 Service

`app/Service/PassportService.php`：

```php
public function login(string $username, string $password, ...): array
{
    $user = $this->repository->findByUnameType($username, $userType);
    if (! $user->verifyPassword($password)) {
        $this->dispatcher->dispatch(new UserLoginEvent($user, $ip, $os, $browser, false));
        throw new BusinessException(ResultCode::UNPROCESSABLE_ENTITY, trans('auth.password_error'));
    }
    if ($user->status->isDisable()) {
        throw new BusinessException(ResultCode::DISABLED);
    }
    $this->dispatcher->dispatch(new UserLoginEvent($user, $ip, $os, $browser));

    $jwt = $this->getJwt();
    return [
        'access_token' => $jwt->builderAccessToken((string) $user->id)->toString(),
        'refresh_token' => $jwt->builderRefreshToken((string) $user->id)->toString(),
        'expire_at' => (int) $jwt->getConfig('ttl', 0),
    ];
}
```

关键点：

- 密码错误也派发事件（记录失败日志），然后抛业务异常
- 用户被禁用 → `BusinessException(ResultCode::DISABLED)`
- JWT 由 `mineadmin/jwt` 的工厂构建
- 登录日志通过 `UserLoginEvent` 异步写（`Coroutine::create`）

### 3.5 Repository

`app/Repository/Permission/UserRepository.php`：

```php
public function findByUnameType(string $username, Type $userType = Type::SYSTEM): User
{
    return $this->model->newQuery()
        ->where('username', $username)
        ->where('user_type', $userType)
        ->firstOrFail();
}
```

`IRepository` 提供了 `page/list/create/updateById/deleteById` 等通用方法，子类只需要写 `handleSearch()`。

### 3.6 返回

`AbstractController::success()` → `new Result(ResultCode::SUCCESS, $message, $data)` → `Result::toArray()` → `CoreMiddleware::transferToResponse` 转 JSON。

---

## 4. 鉴权链（带 token 的请求）

### 4.1 AccessTokenMiddleware

`app/Http/Common/Middleware/AccessTokenMiddleware.php` 继承 `HeaderTokenMiddleware`，最终继承 vendor 的 `AbstractTokenMiddleware`：

```php
public function process(ServerRequestInterface $request, RequestHandlerInterface $handler): ResponseInterface
{
    $token = $this->parserToken($request);      // 解析 Bearer token
    $this->checkToken->checkJwt($token);        // 查黑名单
    return $handler->handle(
        $request->setAttribute('token', $token) // 塞进 request attribute
    );
}
```

`CheckTokenInterface` 的实现绑定在 `config/autoload/dependencies.php`：

```php
CheckTokenInterface::class => PassportService::class,
```

所以 `checkJwt()` 调用的是 `PassportService::checkJwt()`：

```php
public function checkJwt(UnencryptedToken $token): void
{
    $this->getJwt()->hasBlackList($token) && throw new JwtInBlackException();
}
```

登出时：

```php
public function logout(UnencryptedToken $token): void
{
    $this->getJwt()->addBlackList($token);
}
```

黑名单在 Redis 里（`mineadmin/jwt` 实现）。

### 4.2 CurrentUser

`app/Http/CurrentUser.php`：

```php
public function user(): ?User
{
    if (Context::has('current_user')) {
        return Context::get('current_user');
    }
    $user = $this->userService->getInfo($this->id());
    Context::set('current_user', $user);
    return $user;
}

public function id(): int
{
    return (int) $this->getToken()->claims()->get(RegisteredClaims::ID);
}
```

- 第一次取用户查库，之后走协程 Context
- `Context` 是请求级/协程级，不会串用户
- `RequestScopedTokenTrait` 从 request attribute 拿 token

### 4.3 PermissionMiddleware

`app/Http/Admin/Middleware/PermissionMiddleware.php`：

```php
$user = $this->currentUser->user();
if ($user->status->isDisable()) {
    throw new BusinessException(code: ResultCode::DISABLED);
}
if ($user->isSuperAdmin()) {
    return $handler->handle($request);      // 超管直接放行
}
$this->check($request->getAttribute(Dispatched::class));
```

`check()` 用 `AnnotationCollector` 读控制器/方法上的 `#[Permission]`：

```php
#[Permission(code: 'permission:position:index')]
public function pageList(): Result
```

多个 code 时用 `operation` 控制 AND/OR：

```php
#[Permission(code: ['a', 'b'], operation: Permission::OPERATION_OR)]
```

权限 code 来自菜单表（`databases/seeders/menu_seeder_20240926.php`），例如 `permission:user:index`、`permission:user:save`。

### 4.4 OperationMiddleware

记录操作日志：

- 从 `Dispatched` 拿到当前控制器/方法
- 从 `#[Post]/#[Get]` 注解拿 `summary`
- 派发 `RequestOperationEvent`
- `UserOperationSubscriber` 异步落库

---

## 5. 一个标准 CRUD 的分层

以岗位为例：

```
PositionController
  ├─ #[Get('/admin/position/list')]      pageList()
  ├─ #[Post('/admin/position')]          save(PositionRequest)
  ├─ #[Put('/admin/position/{id}')]      update(int $id, PositionRequest)
  └─ #[Delete('/admin/position/{id}')]   delete(int $id)
        ↓
PositionService extends IService
        ↓
PositionRepository extends IRepository
  ├─ handleSearch(Builder, array)   // 查询条件
  └─ __construct(Position $model)
        ↓
Position extends Model
```

职责：

| 层 | 该做什么 | 不该做什么 |
|---|---|---|
| Controller | 收参、调 Service、返回 Result | 写 SQL、写业务规则 |
| Request | 参数校验、字段白名单 | 查库业务 |
| Service | 业务编排、事务、事件 | 拼 SQL |
| Repository | 查询构造、复用查询 | 业务判断 |
| Model | 关系、casts、访问器 | 复杂查询 |

---

## 6. 响应与异常

### 6.1 Result

`app/Http/Common/Result.php`：

```php
return [
    'code' => $this->code->value,
    'message' => $this->message,
    'data' => $this->data,
];
```

`ResultCode` 是枚举，`getMessage()` 从语言包取文案。

### 6.2 业务异常

```php
throw new BusinessException(ResultCode::FORBIDDEN);
throw new BusinessException(ResultCode::UNPROCESSABLE_ENTITY, '自定义消息');
```

`BusinessExceptionHandler` 会转成统一格式，HTTP 状态码默认 200（前端看 `code`）。

### 6.3 未授权 / 校验 / JWT

- `UnauthorizedExceptionHandler`
- `ValidationExceptionHandler` → `code=422` + 字段错误
- `JwtExceptionHandler` → token 过期/非法
- `AppExceptionHandler` → 兜底，生产环境隐藏堆栈

---

## 7. 数据权限（AOP 实战）

`app/Library/DataPermission/`：

- `Attribute/DataScope.php`：注解，声明部门字段、创建人字段、作用表
- `Aspects/DataScopeAspect.php`：切面
- `Factory.php` / `Scope/`：根据策略生成 SQL 条件

用法（在 Service/Repository 方法上加）：

```php
#[DataScope(
    deptColumn: 'dept_id',
    createdByColumn: 'created_by',
    scopeType: ScopeType::CREATED_BY,
    onlyTables: ['user']
)]
public function page(array $params): array
```

切面逻辑：

1. 切到 `#[DataScope]` → 把配置写进 `Context`
2. 切到 `Builder::runSelect` → 如果当前查询的表在 `onlyTables` 里，就加条件
3. 请求结束销毁 Context

这是学 AOP 最好的例子：业务代码零侵入，SQL 自动加权限。

---

## 8. 模型缓存

`config/autoload/databases.php` 里配了 `cache.handler = RedisHandler`：

```php
'cache' => [
    'handler' => RedisHandler::class,
    'cache_key' => 'MineAdmin:%s:m:%s:%s:%s',
    'ttl' => 86400 * 7,
    'empty_model_ttl' => 60,
],
```

配合 `hyperf/model-cache` 的 `#[Cacheable]` 使用，模型查询自动走 Redis。

注意：

- 缓存是**进程外**（Redis），多 worker 共享
- 更新/删除模型时要让缓存失效（组件会处理，但用 `Db::table()` 直接改库不会）
- 调试时看到数据不一致，先查 Redis key

---

## 9. 插件机制

- `bin/hyperf.php` 里 `Plugin::init()`（`Mine\AppStore\Plugin`）
- 插件目录：`plugin/{vendor}/{name}/`
- 元信息：`mine.json`（name、version、composer psr-4、ConfigProvider）
- 安装：`php bin/hyperf.php mine-extension:install {path}`
- 应用市场：`app-store` 插件提供可视化管理
- `config/autoload/mine-extension.php` 的 `auto_install_list` 控制安装时自动装的插件

插件本质是"自带 ConfigProvider 的 Composer 包"，路由/注解/依赖注入都按包的方式合并。

---

## 10. 建议的阅读顺序

1. `config/autoload/server.php`、`config/autoload/watcher.php`、`config/autoload/swagger.php`
2. `app/Http/Admin/Controller/PassportController.php`
3. `app/Http/Admin/Request/PassportLoginRequest.php`
4. `app/Service/PassportService.php`
5. `app/Repository/Permission/UserRepository.php` + `app/Repository/IRepository.php`
6. `app/Http/CurrentUser.php`
7. `app/Http/Common/Middleware/HeaderTokenMiddleware.php` + vendor `AbstractTokenMiddleware`
8. `app/Http/Admin/Middleware/PermissionMiddleware.php`
9. `app/Http/Common/Middleware/OperationMiddleware.php` + `app/Http/Admin/Subscriber/`
10. `app/Library/DataPermission/Aspects/DataScopeAspect.php`
11. `databases/migrations/` + `databases/seeders/`

每读一个类，问自己三个问题：

- 谁创建它？（容器/手动/事件）
- 谁调用它？（路由/中间件/事件/定时任务）
- 它的状态在哪个范围有效？（请求/协程/worker/进程/全局）

---

## 11. 常用排查命令

```powershell
# 所有可用命令（Hyperf 没有内置 route:list，路由在注解里）
powershell -ExecutionPolicy Bypass -File scripts\remote.ps1 exec -Command "php bin/hyperf.php list"

# tinker
powershell -ExecutionPolicy Bypass -File scripts\remote.ps1 tinker

# 日志
powershell -ExecutionPolicy Bypass -File scripts\remote.ps1 exec -Command "tail -n 200 runtime/logs/debug.log"
powershell -ExecutionPolicy Bypass -File scripts\remote.ps1 exec -Command "tail -n 200 runtime/logs/sql.log"

# 确认注解路由已经注册：直接请求接口
powershell -ExecutionPolicy Bypass -File scripts\remote.ps1 exec -Command "curl -s -X POST http://127.0.0.1:9501/admin/passport/login -H 'Content-Type: application/json' -d '{\"username\":\"admin\",\"password\":\"123456\"}'"
```

> 想看某个 URL 对应哪个方法：全局搜 `path: '/admin/xxx'`，或者用 IDE 的注解跳转。

下一篇：[06-实战-写一个CRUD模块](06-实战-写一个CRUD模块.md)
