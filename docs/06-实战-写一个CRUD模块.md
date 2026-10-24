# 06 实战：写一个 CRUD 模块

目标：不复制粘贴框架代码，从 0 加一个「公告管理」模块，跑通 `迁移 → 模型 → 仓储 → 服务 → 校验 → 控制器 → 接口 → 权限`。

约定：

- 表名：`notice`
- URL 前缀：`/admin/notice`
- 权限 code：`notice:index`、`notice:save`、`notice:update`、`notice:delete`
- 用 `admin` 账号测试（超管会跳过权限校验，先把链路跑通）

---

## 0. 先建一个分支，方便回滚

```powershell
cd D:\code\hyperfstu\MineAdmin
git checkout -b learn/notice
```

以后每一步都可以 `git diff` 看自己改了什么。

---

## 1. 迁移：建表

新建 `databases/migrations/2026_10_24_000000_create_notice_table.php`：

```php
<?php

declare(strict_types=1);

use Hyperf\Database\Migrations\Migration;
use Hyperf\Database\Schema\Blueprint;
use Hyperf\Database\Schema\Schema;

class CreateNoticeTable extends Migration
{
    public function up(): void
    {
        Schema::create('notice', static function (Blueprint $table) {
            $table->comment('公告表');
            $table->bigIncrements('id')->comment('主键');
            $table->string('title', 100)->comment('标题');
            $table->text('content')->comment('内容');
            $table->tinyInteger('status')->default(1)->comment('1启用 2停用');
            $table->authorBy();      // MineAdmin 宏：created_by / updated_by
            $table->datetimes();     // MineAdmin 宏：created_at / updated_at
            $table->index('status');
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('notice');
    }
}
```

执行：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\remote.ps1 migrate
```

> 迁移不会热更新，必须手动执行。执行后到数据库里确认表结构。

---

## 2. 模型

新建 `app/Model/Notice.php`：

```php
<?php

declare(strict_types=1);

namespace App\Model;

use Hyperf\DbConnection\Model\Model;

final class Notice extends Model
{
    protected ?string $table = 'notice';

    protected array $fillable = [
        'title', 'content', 'status', 'created_by', 'updated_by',
    ];

    protected array $casts = [
        'id' => 'integer',
        'status' => 'integer',
        'created_at' => 'datetime',
        'updated_at' => 'datetime',
    ];
}
```

要点：

- `$fillable` 决定 `create()/fill()` 能写哪些字段
- `$casts` 把数据库类型转成 PHP 类型/枚举
- 表名不是复数形式，必须显式 `$table`

---

## 3. 仓储

新建 `app/Repository/NoticeRepository.php`：

```php
<?php

declare(strict_types=1);

namespace App\Repository;

use App\Model\Notice;
use Hyperf\Collection\Arr;
use Hyperf\Database\Model\Builder;

final class NoticeRepository extends IRepository
{
    public function __construct(protected readonly Notice $model) {}

    public function handleSearch(Builder $query, array $params): Builder
    {
        return $query
            ->when(Arr::get($params, 'title'), static function (Builder $query, $title) {
                $query->where('title', 'like', '%' . $title . '%');
            })
            ->when(Arr::exists($params, 'status'), static function (Builder $query) use ($params) {
                $query->where('status', (int) Arr::get($params, 'status'));
            })
            ->orderByDesc('id');
    }
}
```

`IRepository` 已经提供：

- `page(array $params, ?int $page, ?int $pageSize): array`
- `list()`、`count()`、`create()`、`updateById()`、`deleteById()`、`findById()`
- `perQuery()` 会先执行 `BootTrait` 的默认逻辑，再调你的 `handleSearch()`

分页返回结构：

```php
['list' => [...], 'total' => 100]
```

---

## 4. 服务

新建 `app/Service/NoticeService.php`：

```php
<?php

declare(strict_types=1);

namespace App\Service;

use App\Repository\NoticeRepository;

final class NoticeService extends IService
{
    public function __construct(protected readonly NoticeRepository $repository) {}
}
```

`IService` 把常用方法代理给 `$repository`。需要业务规则时在这里加，例如：

```php
public function publish(int $id): bool
{
    return $this->repository->updateById($id, ['status' => 1]);
}
```

---

## 5. 参数校验

新建 `app/Http/Admin/Request/NoticeRequest.php`：

```php
<?php

declare(strict_types=1);

namespace App\Http\Admin\Request;

use App\Http\Common\Request\Traits\NoAuthorizeTrait;
use Hyperf\Validation\Request\FormRequest;

class NoticeRequest extends FormRequest
{
    use NoAuthorizeTrait;

    public function rules(): array
    {
        return [
            'title' => 'required|string|max:100',
            'content' => 'required|string',
            'status' => 'sometimes|integer|in:1,2',
        ];
    }

    public function attributes(): array
    {
        return [
            'title' => '标题',
            'content' => '内容',
            'status' => '状态',
        ];
    }
}
```

- `rules()` 由全局 `ValidationMiddleware` 自动执行
- 失败会抛 `ValidationException`，由 `ValidationExceptionHandler` 返回 422
- `$request->validated()` 只返回规则里出现过的字段，天然防脏数据

---

## 6. 控制器

新建 `app/Http/Admin/Controller/NoticeController.php`：

```php
<?php

declare(strict_types=1);

namespace App\Http\Admin\Controller;

use App\Http\Admin\Middleware\PermissionMiddleware;
use App\Http\Admin\Request\NoticeRequest;
use App\Http\Common\Middleware\AccessTokenMiddleware;
use App\Http\Common\Result;
use App\Http\CurrentUser;
use App\Service\NoticeService;
use Hyperf\HttpServer\Annotation\Middleware;
use Hyperf\Swagger\Annotation\Delete;
use Hyperf\Swagger\Annotation\Get;
use Hyperf\Swagger\Annotation\HyperfServer;
use Hyperf\Swagger\Annotation\Post;
use Hyperf\Swagger\Annotation\Put;
use Mine\Access\Attribute\Permission;

#[HyperfServer(name: 'http')]
#[Middleware(middleware: AccessTokenMiddleware::class, priority: 100)]
#[Middleware(middleware: PermissionMiddleware::class, priority: 99)]
final class NoticeController extends AbstractController
{
    public function __construct(
        private readonly NoticeService $service,
        private readonly CurrentUser $currentUser
    ) {}

    #[Get(path: '/admin/notice/list', operationId: 'noticeList', summary: '公告列表', tags: ['公告管理'])]
    #[Permission(code: 'notice:index')]
    public function pageList(): Result
    {
        return $this->success(
            $this->service->page(
                $this->getRequestData(),
                $this->getCurrentPage(),
                $this->getPageSize()
            )
        );
    }

    #[Post(path: '/admin/notice', operationId: 'noticeCreate', summary: '创建公告', tags: ['公告管理'])]
    #[Permission(code: 'notice:save')]
    public function create(NoticeRequest $request): Result
    {
        $this->service->create(array_merge($request->validated(), [
            'created_by' => $this->currentUser->id(),
        ]));
        return $this->success();
    }

    #[Put(path: '/admin/notice/{id}', operationId: 'noticeUpdate', summary: '更新公告', tags: ['公告管理'])]
    #[Permission(code: 'notice:update')]
    public function update(int $id, NoticeRequest $request): Result
    {
        $this->service->updateById($id, array_merge($request->validated(), [
            'updated_by' => $this->currentUser->id(),
        ]));
        return $this->success();
    }

    #[Delete(path: '/admin/notice/{id}', operationId: 'noticeDelete', summary: '删除公告', tags: ['公告管理'])]
    #[Permission(code: 'notice:delete')]
    public function delete(int $id): Result
    {
        $this->service->deleteById($id);
        return $this->success();
    }
}
```

要点：

- `#[HyperfServer(name: 'http')]` 是路由注册的前提（配合 `SWAGGER_ENABLED=true`）
- 类的 `#[Middleware]` 按 `priority` 从大到小执行
- 方法参数 `int $id` 会自动从路由 `{id}` 注入
- 返回 `Result`，框架自动转 JSON

保存后 `server:watch` 会在 2 秒内重启。看日志确认没有语法错误。

---

## 7. 验证

### 7.1 登录拿 token

```powershell
$resp = curl.exe -s -X POST http://你的IP:9501/admin/passport/login `
  -H "Content-Type: application/json" `
  -d "{\"username\":\"admin\",\"password\":\"123456\"}" | ConvertFrom-Json

$token = $resp.data.access_token
$token
```

### 7.2 创建

```powershell
curl.exe -s -X POST http://你的IP:9501/admin/notice `
  -H "Content-Type: application/json" `
  -H "Authorization: Bearer $token" `
  -d "{\"title\":\"第一条公告\",\"content\":\"hello hyperf\",\"status\":1}"
```

### 7.3 列表

```powershell
curl.exe -s "http://你的IP:9501/admin/notice/list?page=1&page_size=10" `
  -H "Authorization: Bearer $token"
```

### 7.4 更新 / 删除

```powershell
curl.exe -s -X PUT http://你的IP:9501/admin/notice/1 `
  -H "Content-Type: application/json" `
  -H "Authorization: Bearer $token" `
  -d "{\"title\":\"改过的标题\",\"content\":\"updated\"}"

curl.exe -s -X DELETE http://你的IP:9501/admin/notice/1 `
  -H "Authorization: Bearer $token"
```

### 7.5 校验失败

```powershell
curl.exe -s -X POST http://你的IP:9501/admin/notice `
  -H "Content-Type: application/json" `
  -H "Authorization: Bearer $token" `
  -d "{\"title\":\"\"}"
```

应该返回 422 和字段错误。

---

## 8. 权限与菜单

用 `admin` 测试时，`PermissionMiddleware` 会因为 `isSuperAdmin()` 直接放行，所以 `notice:index` 这些 code 不存在也能跑通。

要让普通角色也能访问，需要：

1. 后台「菜单管理」新增目录/菜单，`name` 填 `notice:index` 等权限 code
2. 给角色分配这些菜单
3. 重新登录（`CurrentUser` 每次请求从 DB 取角色/菜单，无需清缓存）

菜单的 `path` 对应前端路由，`component` 对应前端页面路径；后端只认 `name`（权限 code）。

---

## 9. 加上操作日志（可选）

`OperationMiddleware` 会从 `#[Get]/#[Post]` 的 `summary` 生成操作日志。它只需要：

```php
#[Middleware(middleware: OperationMiddleware::class, priority: 98)]
```

加到控制器类上即可（参考 `PositionController`）。日志会写到 `user_operation_log` 表。

---

## 10. 加上数据权限（可选）

如果公告需要按部门隔离，在 Service/Repository 方法上加：

```php
use App\Library\DataPermission\Attribute\DataScope;
use App\Library\DataPermission\ScopeType;

#[DataScope(
    deptColumn: 'dept_id',
    createdByColumn: 'created_by',
    scopeType: ScopeType::CREATED_BY,
    onlyTables: ['notice']
)]
public function page(array $params, int $page = 1, int $pageSize = 10): array
{
    return parent::page($params, $page, $pageSize);
}
```

前提是表里有 `dept_id` / `created_by` 字段，并且配置了用户的岗位/部门数据权限。

---

## 11. 常见错误对照表

| 现象 | 原因 | 处理 |
|---|---|---|
| 404 | `SWAGGER_ENABLED=false` | 改 `.env`，`sync -IncludeEnv` |
| 404 | `path` 拼错 / 类没加 `#[HyperfServer]` | 对照本文检查 |
| 404 且日志有 `Class not found` | 命名空间/文件名不匹配 | PSR-4：`App\` → `app/` |
| 401 | 没带 token / token 过期 | 重新登录 |
| 403 | 非超管且没有权限 code | 加菜单/授权 |
| 422 | 校验失败 | 看返回的 `data` 字段错误 |
| 500 `Call to undefined method` | Service 没继承 `IService` 或没注入 repository | 对照第 4 步 |
| 500 `SQLSTATE` | 表不存在/字段名错 | 执行 migrate，核对表结构 |
| 改了代码没生效 | watch 没跑 | 看 `remote.ps1 logs` 是否重启 |
| 新增类后 500 且提示注解错误 | 代理类没重建 | 重启容器，或删 `runtime/container` |

---

## 12. 提交

```powershell
cd D:\code\hyperfstu\MineAdmin
git add app databases
git commit -m "feat: 新增公告 CRUD 学习模块"
```

下一步：把它改成带事务、带事件、带队列的版本，练习 Hyperf 的进阶能力。

---

下一篇：[07-六周学习计划](07-六周学习计划.md)
