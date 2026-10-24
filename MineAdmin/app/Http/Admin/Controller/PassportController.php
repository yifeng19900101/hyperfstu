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

// ===== 依赖引入（下方逐个说明用途）=====
use App\Http\Admin\Request\PassportLoginRequest;      // 登录请求的 FormRequest（自带参数校验 + 客户端 IP）
use App\Http\Admin\Vo\PassportLoginVo;                // 登录返回值的「文档 VO」，只用于生成 Swagger 文档，不参与运行时逻辑
use App\Http\Common\Controller\AbstractController;    // 控制器基类，提供 success()/error()/json() 统一响应封装
use App\Http\Common\Middleware\AccessTokenMiddleware; // 校验 access_token 的中间件
use App\Http\Common\Middleware\RefreshTokenMiddleware; // 校验 refresh_token 的中间件
use App\Http\Common\Result;                            // 统一响应对象（code/message/data），实现 Arrayable 可自动转 JSON
use App\Http\CurrentUser;                              // 当前登录用户的「服务类」，负责从 token 取用户、刷新 token 等
use App\Model\Enums\User\Type;                         // 用户类型枚举（100=系统/后台用户，200=普通前台用户）
use App\Schema\UserSchema;                             // 用户信息的 Swagger Schema（只用于文档）
use App\Service\PassportService;                       // 认证业务逻辑：登录、登出、签发/刷新 JWT、校验黑名单
use Hyperf\HttpServer\Annotation\Middleware;           // 路由中间件注解（会被合并进路由配置）
use Hyperf\HttpServer\Contract\RequestInterface;       // Hyperf 请求对象接口（PSR-7 的增强版）
use Hyperf\Swagger\Annotation as OA;                   // OpenAPI 注解命名空间（文档生成）
use Hyperf\Swagger\Annotation\Post;                    // OpenAPI 的 POST 注解：MineAdmin 里它「身兼两职」——既是文档，也是路由
use Mine\Jwt\Traits\RequestScopedTokenTrait;           // 提供 getToken()：从当前请求上下文取出中间件解析好的 JWT 对象
use Mine\Swagger\Attributes\ResultResponse;            // 自定义注解：用 PHP 类结构描述接口的 200 响应体（只影响文档）

/**
 * 后台管理端「认证（通行证）」控制器。
 *
 * 职责非常单一：只负责接收 HTTP 请求、参数校验、调用 PassportService、包装统一响应；
 * 真正的业务逻辑（密码校验、状态判断、JWT 签发、黑名单）全部在 PassportService 中。
 *
 * 本控制器提供 4 个接口：
 *   POST /admin/passport/login    登录（无鉴权）
 *   POST /admin/passport/logout   退出（需 access_token）
 *   GET  /admin/passport/getInfo  获取当前登录用户信息（需 access_token）
 *   POST /admin/passport/refresh  刷新 token（需 refresh_token）
 *
 * 【关键机制】这里没有 #[Controller] 注解，路由是怎么来的？
 *   Hyperf 的 `Hyperf\Swagger\Annotation\Post` 在 swagger 开启时会被
 *   `Hyperf\Swagger\Listener\BootSwaggerListener` 扫描，并把注解里的 path/method
 *   注册到对应 server（由类上的 #[OA\HyperfServer(name: 'http')] 指定）的路由表里。
 *   因此：**只有 SWAGGER_ENABLED=true 时这些注解路由才会生效**（见 .env 与 config/autoload/swagger.php）。
 */
#[OA\HyperfServer(name: 'http')] // 声明本控制器的注解路由注册到名为 http 的 Hyperf Server 上（对应 config/autoload/server.php 中的 servers.name）
final class PassportController extends AbstractController
{
    // 引入 trait 后即可在方法里调用 $this->getToken()，
    // 它内部是 RequestContext::get()->getAttribute('token')，
    // 而 'token' 这个请求属性正是由 AccessTokenMiddleware / RefreshTokenMiddleware 解析 JWT 后写入的。
    use RequestScopedTokenTrait;

    /**
     * 构造器依赖注入：Hyperf 容器会自动实例化并传入这两个对象。
     * 使用 readonly 表示「注入后不可重新赋值」，避免协程间误改状态。
     *
     * @param PassportService $passportService 认证业务服务
     * @param CurrentUser     $currentUser     当前用户服务（内部依赖 PassportService/UserService/MenuService）
     */
    public function __construct(
        private readonly PassportService $passportService,
        private readonly CurrentUser $currentUser
    ) {}

    /* =========================================================================
     * 1. 登录
     * ========================================================================= */

    // Post 注解同时承担两件事：
    //   1) 生成 OpenAPI 文档（path/method/summary/tags 等）；
    //   2) 在 SWAGGER_ENABLED=true 时，被 BootSwaggerListener 注册成真实的 HTTP 路由。
    // 参数说明：
    //   path        —— 请求路径（最终 URL 就是 /admin/passport/login）
    //   operationId —— OpenAPI 中该操作的唯一标识，前端生成 API 客户端时常用
    //   summary     —— 接口摘要（Swagger UI 上显示）
    //   tags        —— 文档分组，按 'admin:passport' 归类
    #[Post(
        path: '/admin/passport/login',
        operationId: 'passportLogin',
        summary: '系统登录',
        tags: ['admin:passport']
    )]
    // 描述「成功时」的响应结构（仅用于文档，不影响运行）：
    //   instance: new Result(data: new PassportLoginVo()) —— 告诉文档生成器 data 的形状是 PassportLoginVo
    //   example  —— Swagger UI 中展示的示例 JSON
    #[ResultResponse(
        instance: new Result(data: new PassportLoginVo()),
        title: '登录成功',
        description: '登录成功返回对象',
        example: '{"code":200,"message":"成功","data":{"access_token":"eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJpYXQiOjE3MjIwOTQwNTYsIm5iZiI6MTcyMjA5NDAiLCJleHAiOjE3MjIwOTQzNTZ9.7EKiNHb_ZeLJ1NArDpmK6sdlP7NsDecsTKLSZn_3D7k","refresh_token":"eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJpYXQiOjE3MjIwOTQwNTYsIm5iZiI6MTcyMjA5NDAiLCJleHAiOjE3MjIwOTQzNTZ9.7EKiNHb_ZeLJ1NArDpmK6sdlP7NsDecsTKLSZn_3D7k","expire_at":300}}'
    )]
    // 描述请求体（仅用于文档）：
    //   ref      —— 复用 PassportLoginRequest 上 #[Schema] 定义的结构
    //   required —— 必填字段
    //   example  —— Swagger UI 里预填的示例
    #[OA\RequestBody(content: new OA\JsonContent(
        ref: PassportLoginRequest::class,
        title: '登录请求参数',
        required: ['username', 'password'],
        example: '{"username":"admin","password":"123456"}'
    ))]
    public function login(PassportLoginRequest $request): Result
    {
        // 【参数校验】
        // 形参类型是 PassportLoginRequest（FormRequest 子类），Hyperf 会在进入本方法前：
        //   1) 通过容器创建它；
        //   2) 自动执行 rules()（username 必填且必须存在于 user 表、password 必填）；
        //   3) 校验失败则抛 ValidationException，由全局异常处理器直接返回 422，
        //      根本不会执行到下面的代码。
        // 另外它使用了 NoAuthorizeTrait，所以登录接口不会走「接口权限」校验。

        // 显式转成 string，保证后续调用严格类型的 PassportService::login() 不会因类型不匹配报错
        $username = (string) $request->input('username');
        $password = (string) $request->input('password');

        // 取 User-Agent 作为「浏览器」信息写入登录日志；没有该请求头时兜底为 'unknown'
        $browser = $request->header('User-Agent') ?: 'unknown';

        // os() 来自 PassportLoginRequest 引入的 ClientOsTrait：
        // 通过 User-Agent 关键字（win/mac/linux/unix/bsd）粗略识别操作系统
        $os = $request->os();

        // 调用业务层完成真正的登录：
        //   Type::SYSTEM = 100，表示「只允许后台系统用户登录」。
        //   如果用户名存在但类型是 200（前台用户），查询会找不到 → 返回 404/未找到。
        //   $request->ip() 被 PassportLoginRequest 重写过：取客户端真实 IP，取不到时兜底 '0.0.0.0'。
        // 返回值是数组：
        //   ['access_token' => '...', 'refresh_token' => '...', 'expire_at' => 300]
        //   注意 expire_at 实际是「有效期秒数（TTL）」，不是 Unix 时间戳。
        return $this->success(
            $this->passportService->login(
                $username,
                $password,
                Type::SYSTEM,
                $request->ip(),
                $browser,
                $os
            )
        );
    }

    /* =========================================================================
     * 2. 退出登录
     * ========================================================================= */

    // 请求方法：POST（操作有副作用，不适合用 GET）
    // security: [['Bearer' => [], 'ApiKey' => []]] —— 仅用于文档，声明该接口需要鉴权；
    //   两种 scheme 定义在 app/Http/Common/Swagger/Server.php：
    //     Bearer = Authorization: Bearer <access_token>
    //     ApiKey = token: <access_token>
    //   （HeaderTokenMiddleware 会同时兼容这两种传法）
    #[Post(
        path: '/admin/passport/logout',
        operationId: 'passportLogout',
        summary: '退出',
        security: [['Bearer' => [], 'ApiKey' => []]],
        tags: ['admin:passport']
    )]
    // 文档：成功时返回统一 Result，data 为空数组
    #[ResultResponse(instance: new Result(), example: '{"code":200,"message":"成功","data":[]}')]
    // 路由中间件：执行控制器前先校验 access_token。
    // 具体流程（AbstractTokenMiddleware::process）：
    //   1) 从 Authorization: Bearer xxx 或 token 头中取出 JWT；
    //   2) parserAccessToken() 校验签名/过期时间；
    //   3) PassportService::checkJwt()（容器里 CheckTokenInterface 绑定到它）检查 Redis 黑名单；
    //   4) 把解析后的 UnencryptedToken 写入请求属性 'token'，供控制器通过 getToken() 取得。
    // 任一环节失败都会抛异常/返回 401，不会进入 logout()。
    #[Middleware(AccessTokenMiddleware::class)]
    public function logout(RequestInterface $request): Result
    {
        // $request 在本方法体内其实没有被直接使用（getToken() 读的是请求上下文），
        // 保留它是为了明确表达「本动作依赖一次 HTTP 请求」，也可以直接删掉该参数。

        // getToken() 返回中间件写入的 UnencryptedToken（已确认有效且不在黑名单中）。
        // logout() 会把这个 access_token 加入 Redis 黑名单，实现「无状态 JWT 的服务端主动失效」。
        // 之后再用同一个 token 请求任何接口，checkJwt() 会抛 JwtInBlackException → 401。
        $this->passportService->logout($this->getToken());

        // 返回 {"code":200,"message":"成功","data":[]}
        return $this->success();
    }

    /* =========================================================================
     * 3. 获取当前登录用户信息
     * ========================================================================= */

    #[OA\Get(
        path: '/admin/passport/getInfo',
        operationId: 'getInfo',
        summary: '获取用户信息',
        security: [['Bearer' => [], 'ApiKey' => []]],
        tags: ['admin:passport']
    )]
    // 同样先经过 access_token 中间件：未登录/过期/已登出 → 401
    #[Middleware(AccessTokenMiddleware::class)]
    // 文档：data 的结构按 UserSchema 描述
    // 注意：这只是「文档」，实际运行时 formatUserInfo() 返回的字段比 UserSchema 少
    //      （没有 user_type/status/login_ip/login_time/created_at 等），以实际返回为准。
    #[ResultResponse(
        instance: new Result(data: UserSchema::class),
    )]
    public function getInfo(): Result
    {
        // $this->currentUser->user() 的取值顺序：
        //   1) 先看当前协程 Context 中是否已有 'current_user'（同一次请求内缓存，避免重复查库）；
        //   2) 没有就从 getToken() 的 claims 里取出用户 ID，再调用 UserService::getInfo($id) 查库；
        //   3) 查到的模型写回 Context，供后续调用复用。
        //
        // formatUserInfo() 把 User 模型整理成前端需要的扁平数组：
        //   id/username/nickname/avatar/signed/backend_setting/phone/email
        //   + departments（部门）、positions（岗位）、roles（只含正常状态角色，按 sort 排序）
        return $this->success($this->passportService->formatUserInfo($this->currentUser->user()));
    }

    /* =========================================================================
     * 4. 刷新 Token
     * ========================================================================= */

    #[Post(
        path: '/admin/passport/refresh',
        operationId: 'refresh',
        summary: '刷新token',
        security: [['Bearer' => [], 'ApiKey' => []]],
        tags: ['admin:passport']
    )]
    // 关键差异：这里校验的是 refresh_token，不是 access_token。
    // RefreshTokenMiddleware 的处理流程：
    //   1) 用 parserRefreshToken() 解析请求头里的 JWT，要求它必须是 refresh 类型；
    //   2) 通过 PassportService::checkJwt() 检查该 refresh_token 是否已在黑名单；
    //   3) 把解析后的 token 重新写入请求属性 'token'（覆盖式 setAttribute）。
    // 所以下面注入的 CurrentUser 调用 getToken() 时，拿到的是「refresh_token」。
    #[Middleware(RefreshTokenMiddleware::class)]
    // 文档：返回结构与登录一致（新 access_token + 新 refresh_token + expire_at）
    #[ResultResponse(
        instance: new Result(data: new PassportLoginVo())
    )]
    // 形参 CurrentUser $user 不是路由参数，而是 Hyperf 的「方法参数依赖注入」：
    // 框架发现它是类类型且容器能解析，就用 $container->get(CurrentUser::class) 生成后传入。
    // CurrentUser 内部同样 use RequestScopedTokenTrait，因此它拿到的是中间件刚写入的 refresh_token。
    public function refresh(CurrentUser $user): Result
    {
        // CurrentUser::refresh() → PassportService::refreshToken($this->getToken())
        // 业务逻辑：
        //   1) 把「本次使用的 refresh_token」加入黑名单（防止重复使用）；
        //   2) 用该 token 的 claims ID（用户 ID）重新签发一对新的 access_token + refresh_token；
        //   3) 返回 ['access_token' => ..., 'refresh_token' => ..., 'expire_at' => TTL 秒数]。
        //
        // 注意：刷新只会使旧的 refresh_token 失效，**不会**让旧的 access_token 立刻失效，
        // 旧 access_token 仍可继续使用直到自然过期（测试用例也验证了这一点）。
        // 如需「改密/强制下线立刻踢掉所有会话」，需要额外按用户维度维护黑名单/版本号。
        return $this->success($user->refresh());
    }
}
