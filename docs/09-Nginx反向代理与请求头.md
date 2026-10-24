# 09 Nginx 反向代理：配置、请求头与参数获取

这一篇专门讲「请求从浏览器进来，经过 Nginx，到 Swoole」这一段发生了什么，以及在后端怎么把 header、query、body、cookie、真实 IP 取出来。

对应文件：

- Nginx 配置：`deploy/nginx/default.conf`（docker 内 nginx 用这个）
- 宝塔站点配置片段：`deploy/bt/nginx-site.conf`（服务器用宝塔时改这个，见 [10-宝塔面板部署](10-宝塔面板部署.md)）
- 后端回显接口：`MineAdmin/app/Http/Admin/Controller/ProxyDebugController.php`
- 信任代理中间件：`MineAdmin/app/Http/Common/Middleware/TrustedProxyMiddleware.php`
- 测试脚本：`scripts/proxy.ps1`

---

## 1. 链路

> 下面的配置基于「docker 内 nginx 直接对公网」。服务器装了宝塔时，把这一层换成面板 Nginx，`location` 内容基本一致，见 [10-宝塔面板部署](10-宝塔面板部署.md)。

```
浏览器
  │  GET /hyperfproapi/admin/proxy/debug?page=2     Host: 1.2.3.4
  ▼
nginx:80
  │  location /hyperfproapi/  →  proxy_pass http://app:9501/
  │  剥掉 /hyperfproapi，补 6 个 X-Forwarded-* 头
  ▼
app:9501  (Swoole / Hyperf)
     $request->getUri()->getPath()      = /admin/proxy/debug
     $request->getQueryParams()         = ['page' => '2']
     $request->getHeaderLine('x-real-ip')   = 真实客户端 IP
     $request->getServerParams()['remote_addr'] = 172.x.x.x（nginx 容器 IP）
```

两个必须记住的事实：

1. **后端看到的 `remote_addr` 永远是 Nginx 的地址**，不是用户的。真实 IP 只能从 header 里取。
2. **`/hyperfproapi` 是 Nginx 剥掉的，后端根本没有这个前缀**。所以后端路由仍然是 `/admin/...`。

---

## 2. 先验证，再看原理

三条命令，分别验证三个层次：

```powershell
# ① 只经过 nginx：看 nginx 这一层拿到了什么
curl.exe -i "http://你的服务器IP/__echo?x=1" -H "X-Custom: hello"

# ② 经过完整代理链：看后端到底收到了什么（GET + query + header）
curl.exe -s "http://你的服务器IP/hyperfproapi/admin/proxy/debug?page=2&name=test" -H "X-Custom: hello"

# ③ JSON body
curl.exe -s -X POST "http://你的服务器IP/hyperfproapi/admin/proxy/debug" ^
  -H "Content-Type: application/json" ^
  -d "{\"username\":\"admin\",\"password\":\"123456\"}"
```

> PowerShell 里 `curl` 是 `Invoke-WebRequest` 的别名，参数不兼容，请显式写 `curl.exe`。
> 上面的 `^` 是 cmd 的续行符；PowerShell 用反引号 `` ` ``，或者直接写成一行。

也可以直接用脚本，省得拼参数：

```powershell
# GET + query + 自定义头
powershell -File scripts\proxy.ps1 -Path /admin/proxy/debug -Query @{ page = 2; name = 'test' } -Headers @{ 'X-Custom' = 'hello' }

# POST JSON
powershell -File scripts\proxy.ps1 -Path /admin/proxy/debug -Method POST `
  -Body '{"username":"admin","password":"123456"}'
```

`/__echo` 的期望输出（注意 `remote_addr` 是你的公网 IP）：

```
remote_addr=203.0.113.10
host=203.0.113.10
http_host=203.0.113.10
server_port=80
scheme=http
request_method=GET
request_uri=/__echo?x=1
uri=/__echo
args=x=1
request_id=3f9c1a2b4d5e6f708192a3b4c5d6e7f8
user_agent=curl/8.5.0
x_custom=hello
x_real_ip=
x_forwarded_for=
```

`x_real_ip` / `x_forwarded_for` 在这里是空的，因为这两个头是 **nginx 往后端转发时才加的**，`location = /__echo` 不经过 `proxy_pass`。这也正好说明：客户端自己不带这两个头，值完全由 nginx 决定。

`/hyperfproapi/admin/proxy/debug` 的关键字段：

```json
{
  "code": 200,
  "data": {
    "path": "/admin/proxy/debug",
    "query": { "page": "2", "name": "test" },
    "ip": {
      "x-real-ip": "203.0.113.10",
      "x-forwarded-for": "203.0.113.10",
      "remote_addr": "172.18.0.6",
      "getClientIps": ["203.0.113.10"]
    },
    "headers": {
      "host": ["203.0.113.10"],
      "x-forwarded-proto": ["http"],
      "x-forwarded-port": ["80"],
      "x-forwarded-prefix": ["/hyperfproapi"],
      "x-original-uri": ["/hyperfproapi/admin/proxy/debug?page=2&name=test"]
    }
  }
}
```

对比 `path`（`/admin/...`）和 `x-original-uri`（`/hyperfproapi/admin/...`），就能直观看到前缀是在哪一层被剥掉的。

---

## 3. 配置逐段讲

### 3.1 `proxy_pass` 的尾斜杠（最容易错的一处）

```nginx
location /hyperfproapi/ {
    proxy_pass http://app:9501/;   # 注意结尾的 /
}
```

| 写法 | 浏览器请求 | 后端收到 |
|---|---|---|
| `proxy_pass http://app:9501/;` | `/hyperfproapi/admin/x` | `/admin/x` |
| `proxy_pass http://app:9501;` | `/hyperfproapi/admin/x` | `/hyperfproapi/admin/x` |

规则：`proxy_pass` 里**带了 URI（哪怕只是一个 `/`）**，就用它替换掉 `location` 匹配的那一段；**没带 URI**，就原样透传。

MineAdmin 前端 `.env.production` 里 `VITE_OPEN_PROXY=true`，axios 的 baseURL 是 `/hyperfproapi`，后端又没有 `/hyperfproapi` 前缀，所以这里必须带斜杠。

### 3.2 转发头，逐个说明

```nginx
proxy_set_header Host              $host;
proxy_set_header X-Real-IP         $remote_addr;
proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Forwarded-Host  $host;
proxy_set_header X-Forwarded-Port  $server_port;
proxy_set_header X-Forwarded-Prefix /hyperfproapi;
proxy_set_header X-Original-URI    $request_uri;
proxy_set_header X-Request-Id      $request_id;
```

| Header | 值 | 作用 |
|---|---|---|
| `Host` | `$host` | 保持用户访问的域名。后端拼绝对 URL、生成上传链接时依赖它 |
| `X-Real-IP` | `$remote_addr` | 单个真实 IP，**最省事的取值方式** |
| `X-Forwarded-For` | `$proxy_add_x_forwarded_for` | 追加式 IP 链，用于多级代理 |
| `X-Forwarded-Proto` | `$scheme` | `http` / `https`。后端判断是否安全连接、拼链接用 |
| `X-Forwarded-Host` | `$host` | 原始 Host，多域名时用 |
| `X-Forwarded-Port` | `$server_port` | 原始端口 |
| `X-Forwarded-Prefix` | 固定 `/hyperfproapi` | 告诉后端「我被挂在了哪个子路径下」 |
| `X-Original-URI` | `$request_uri` | 原始请求行（含 query），排障用 |
| `X-Request-Id` | `$request_id` | nginx 生成的唯一 ID，用于串日志 |

### 3.3 `X-Forwarded-For` 为什么必须用 `$proxy_add_x_forwarded_for`

`$proxy_add_x_forwarded_for` 的语义是「**客户端传来的 XFF + `,` + `$remote_addr`**」。

| 用哪个变量 | 客户端发 `X-Forwarded-For: 1.1.1.1` | 后端收到 | 是否可伪造 |
|---|---|---|---|
| `$proxy_add_x_forwarded_for` | 追加 | `1.1.1.1, 203.0.113.10` | 前面那截可伪造，**最后一跳可信** |
| `$http_x_forwarded_for` | 原样透传 | `1.1.1.1` | **完全可伪造**，等于没有防护 |

所以取值原则是：**从右往左读，第一个不在信任网段里的 IP 才是真实客户端**，不要直接取最左边那个。

如果不需要多级信息，直接用 `X-Real-IP` 更安全，因为它每跳都被覆盖成当前直连对端。

### 3.4 `real_ip` 模块：前面还有 CDN / 负载均衡时才开

我们的结构里 Nginx 是唯一入口，`$remote_addr` 已经是真实客户端，所以这段**默认注释掉**。

如果以后前面加了 CDN、SLB、WAF：

```nginx
set_real_ip_from  10.0.0.0/8;
set_real_ip_from  172.16.0.0/12;
real_ip_header    X-Forwarded-For;
real_ip_recursive on;
```

打开后，`$remote_addr` 会被替换成还原后的真实 IP，下面的 `X-Real-IP` 和 `X-Forwarded-For` 自动跟着正确。

**安全红线**：`set_real_ip_from` 只能写你自己的代理网段。写 `0.0.0.0/0` 等于允许任何人伪造 IP，登录日志、限流、封禁全部失效。

### 3.5 WebSocket / SSE

```nginx
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      '';
}

proxy_http_version 1.1;
proxy_set_header Upgrade    $http_upgrade;
proxy_set_header Connection $connection_upgrade;
```

- `proxy_http_version 1.1` 是必须的，HTTP/1.0 不支持 Upgrade。
- 普通请求 `Connection` 置空，可以走长连接复用；带 `Upgrade` 头的才切换成 `upgrade`。
- SSE / 流式响应还要 `proxy_buffering off;`，否则 Nginx 会攒一批才吐。

### 3.6 超时、缓冲、上传

```nginx
client_max_body_size 100m;      # 请求体上限，超过直接 413
client_body_timeout  300s;

proxy_connect_timeout 30s;      # 连后端
proxy_send_timeout    300s;     # 往后端写
proxy_read_timeout    300s;     # 等后端响应（导出 Excel 要放宽）
proxy_request_buffering off;    # 大文件不落磁盘，直接流式转发
proxy_buffering off;            # 响应不缓冲，SSE 能实时输出
proxy_redirect off;             # 不改写后端返回的 Location
```

`client_max_body_size` 要和 PHP 的 `upload_max_filesize`、`post_max_size` 对齐，否则会出现「Nginx 过了，PHP 还是收不到文件」。

### 3.7 静态资源与缓存

| 路径 | 谁处理 | 缓存 |
|---|---|---|
| `/` | `MineAdmin-Vue/dist` 里的文件，找不到就回 `index.html` | — |
| `/static/*` | 构建产物（文件名带 hash） | 30 天 + immutable |
| `/index.html` | 构建产物 | **不缓存**，否则发布后还加载旧 hash |
| `/uploads/*` | `MineAdmin/storage/uploads` | 7 天 |
| `/__echo` | Nginx 自己 | — |

`/uploads/` 用的是 `alias`，不是 `root`：`alias /srv/uploads/;` 表示把 `location` 匹配的那段**替换**成磁盘路径，所以 `/uploads/a.png` → `/srv/uploads/a.png`。

**注意 `alias` 不能和 `try_files` 一起用**：`try_files` 会把完整 `$uri` 再拼一次，变成 `/srv/uploads//uploads/a.png`，必然 404。`/static/` 用的是 `root`，所以可以放心用 `try_files`。

### 3.8 改完配置先验证

配置文件挂载进容器后，先用 `nginx -t` 检查语法，再 reload：

```bash
# 在服务器 /opt/hyperfstu 下
docker compose -f deploy/docker-compose.yml exec nginx nginx -t
docker compose -f deploy/docker-compose.yml exec nginx nginx -s reload
```

`nginx -t` 输出 `syntax is ok` / `test is successful` 才算通过。直接 `reload` 一个语法错误的配置会保留旧配置继续跑，容易误以为改动生效了。

---

## 4. Nginx 变量速查

| 变量 | `/hyperfproapi/admin/x?a=1` 时的值 | 说明 |
|---|---|---|
| `$uri` | `/hyperfproapi/admin/x` | 规范化后的路径，不含 query，可能被 `rewrite` 改过 |
| `$request_uri` | `/hyperfproapi/admin/x?a=1` | **原始**请求行，含 query，不被改写 |
| `$args` | `a=1` | query string |
| `$is_args` | `?` | 有 query 时是 `?`，否则空 |
| `$host` | 域名或 IP | 优先取请求行，其次 Host 头 |
| `$http_host` | `1.2.3.4` | 原始 Host 头（带端口） |
| `$scheme` | `http` | 协议 |
| `$server_port` | `80` | Nginx 监听端口 |
| `$remote_addr` | 客户端 IP | 开了 `real_ip` 后是还原后的真实 IP |
| `$proxy_add_x_forwarded_for` | 见 3.3 | XFF 追加 |
| `$request_id` | 32 位十六进制 | 每请求唯一 |
| `$http_xxx` | 请求头 `Xxx` 的值 | 如 `$http_user_agent`、`$http_x_custom` |
| `$status` | `200` | 响应码（日志里用） |

---

## 5. 后端怎么取（Hyperf）

`Hyperf\HttpServer\Contract\RequestInterface` 同时提供 PSR-7 方法和框架便捷方法。

### 5.1 速查表

| 需求 | 写法 |
|---|---|
| 单个请求头 | `$request->getHeaderLine('x-real-ip')` / `$request->header('User-Agent')` |
| 全部请求头 | `$request->getHeaders()` → `['host' => ['1.2.3.4'], ...]` |
| 单个 query | `$request->query('page', 1)` |
| 全部 query | `$request->getQueryParams()` |
| JSON body 字段 | `$request->input('username')` |
| 仅 body | `$request->post()` / `$request->getParsedBody()` |
| body + query | `$request->all()` |
| 上传文件 | `$request->file('file')` |
| cookie | `$request->cookie('name')` / `$request->getCookieParams()` |
| Swoole 层信息 | `$request->getServerParams()` |
| 请求方法 | `$request->getMethod()` |
| 路径 | `$request->getUri()->getPath()` |
| 原始 URI（含 query） | `$request->server('request_uri')` |
| Bearer Token | `$request->getHeaderLine('Authorization')` 去掉前缀 |
| 真实客户端 IP | `$request->getHeaderLine('x-real-ip')`（推荐） |

### 5.2 代码示例

在控制器里（MineAdmin 的控制器继承 `App\Http\Admin\Controller\AbstractController`，有 `getRequest()`）：

```php
use Hyperf\HttpServer\Contract\RequestInterface;

public function demo(RequestInterface $request): Result
{
    // 1) 请求头：大小写不敏感，多值头用数组返回
    $realIp  = $request->getHeaderLine('x-real-ip');
    $ua      = $request->header('User-Agent', 'unknown');
    $allHead = $request->getHeaders();

    // 2) query：只从 URL 参数里取
    $page = (int) $request->query('page', 1);

    // 3) body：JSON 或 form 都走 input()，它会自动合并 query
    $username = (string) $request->input('username', '');
    $payload  = $request->all();        // query + body
    $onlyBody = $request->post();       // 只有 body

    // 4) 文件
    $file = $request->file('file');     // Hyperf\HttpMessage\Upload\UploadedFile|null

    // 5) cookie
    $token = $request->cookie('token');

    return $this->success([
        'real_ip' => $realIp,
        'ua' => $ua,
        'page' => $page,
        'username' => $username,
        'has_file' => $file !== null,
    ]);
}
```

### 5.3 一个必须知道的坑：`input()` 里 query 优先

Hyperf 的合并逻辑是：

```php
// vendor/hyperf/http-server/src/Request.php
return $request->getQueryParams() + $data;   // $data = parsedBody
```

`+` 是「左边优先」的数组并集，所以 **同名参数时 query 覆盖 body**。

`POST /admin/x?id=1`，body 是 `{"id": 2}`，`$request->input('id')` 得到的是 `"1"`。

要精确取值就用 `query()` 或 `post()` 分开取，不要混用 `input()`。

### 5.4 真实 IP：`getClientIps()` 的坑

MineAdmin 的登录日志用的是 `ClientIpRequestTrait::getClientIps()`：

```php
$ip = $this->server('remote_addr');

if (! $this->isFromTrustedProxy()) {
    return [$ip];                 // ← 默认走这里
}

return $this->getTrustedValues(HEADER_X_FORWARDED_FOR, $ip) ?: [$ip];
```

`$trustedProxies` 默认是空数组，所以它**直接返回 `remote_addr`**。走 Nginx 后那就是 `172.x` 容器 IP，于是登录日志、操作日志里全是内网地址。

解决办法是登记受信任代理，见 `TrustedProxyMiddleware`：

```php
private const PROXIES = ['PRIVATE_SUBNETS'];   // docker 网络 172.16.0.0/12

private function register(): void
{
    Request::setTrustedProxies(self::PROXIES, self::HEADER_SET);
    PassportLoginRequest::setTrustedProxies(self::PROXIES, self::HEADER_SET);
}
```

注意两点：

1. **trait 的 static 属性按类各存一份**。`Mine\Support\Request` 和 `PassportLoginRequest` 各有一份 `$trustedProxies`，必须分别登记。以后新增直接 `use ClientIpRequestTrait` 的 FormRequest，也要加进这个中间件。
2. 它已注册为第一个全局中间件（`config/autoload/middlewares.php`），所以后续所有中间件、控制器都生效。

另外，调试接口里注入的是 `Mine\Support\Request`（带 trait 的那个类），所以能直接看到 `getClientIps()` 的真实结果。如果注入的是 `RequestInterface`，拿到的是 Hyperf 原生 `Request`，它没有这个方法。

如果你的 Nginx 和 app 不在同一个内网（比如分开两台公网机器），把 `PRIVATE_SUBNETS` 换成 Nginx 的具体 IP；也支持 `'remote_addr'` 表示无条件信任——**不要在生产上这么写**。

---

## 6. 上传文件经过代理

```bash
curl.exe -s -X POST "http://你的服务器IP/hyperfproapi/admin/proxy/debug" \
  -F "file=@D:\tmp\a.txt" \
  -F "name=test"
```

回显里会看到：

```json
{
  "parsed_body": {
    "name": "test",
    "file": { "client_filename": "a.txt", "size": 12, "error": 0 }
  }
}
```

链路要点：

| 环节 | 限制项 | 默认值 |
|---|---|---|
| Nginx | `client_max_body_size` | 我们设为 `100m` |
| Nginx | `proxy_request_buffering` | 我们设为 `off`，流式转发 |
| PHP | `upload_max_filesize` / `post_max_size` | 看镜像里的 `php.ini` |
| MineAdmin | 业务校验（后缀、大小） | 见 `UploadRequest` |

任何一层超限的表现都不一样：Nginx 超限是 **413**，PHP 超限是 **空 $_FILES + 200**，业务校验失败是 **422**。

---

## 7. 常见坑

| 现象 | 原因 | 处理 |
|---|---|---|
| 所有 `/hyperfproapi/admin/*` 404 | `proxy_pass` 少写尾斜杠，后端收到带 `/hyperfproapi` 的路径 | 改成 `proxy_pass http://app:9501/;` |
| 静态资源 404，页面白屏 | `root` 指向错误 / `MineAdmin-Vue/dist` 为空 | `ls MineAdmin-Vue/dist/index.html`，重跑 `update.sh` |
| 登录日志 IP 全是 `172.x` | 没登记受信任代理 | 加 `TrustedProxyMiddleware`（见 5.4） |
| 客户端能伪造 IP | 用了 `$http_x_forwarded_for` 透传 | 换成 `$proxy_add_x_forwarded_for` |
| 发布后还加载旧 JS | `index.html` 被缓存 | 加 `location = /index.html { no-cache; }`，浏览器 `Ctrl+F5` |
| 上传大文件 413 | `client_max_body_size` 太小 | 调大，并同步 PHP 配置 |
| 导出/长请求 504 | `proxy_read_timeout` 太短 | 调大到 300s 以上 |
| 后端拿到的是 `http` 但页面是 `https` | 没传 `X-Forwarded-Proto` | 补上，并让后端读它 |
| SSE 不实时 | `proxy_buffering on` | 设 `off` |
| 502 且后端日志正常 | 容器名解析不到 / app 没起来 | `docker compose ps`，确认服务名是 `app` |

---

## 8. 以后上 HTTPS

1. 证书放在 Nginx，后端继续跑 HTTP，`X-Forwarded-Proto` 会变成 `https`。
2. `MineAdmin/.env` 的 `APP_URL` 要改成 `https://域名`，否则上传附件返回的绝对地址仍是 `http://`，浏览器会报混合内容。
3. 前端同域部署不用改 `VITE_APP_API_BASEURL`，`/hyperfproapi` 相对路径天然跟随协议。
4. 加了 HSTS 之后再用 HTTP 访问会被强制跳转，调试时注意清理浏览器缓存。

---

## 9. 安全清单

- [ ] `set_real_ip_from` 只写自己的代理网段，绝不写 `0.0.0.0/0`
- [ ] 使用 `$proxy_add_x_forwarded_for`，不要透传客户端给的 XFF
- [ ] 后端优先信任 `X-Real-IP`，取 XFF 时从右往左读
- [ ] `server_tokens off`，不暴露 Nginx 版本
- [ ] `proxy_hide_header X-Powered-By`，不暴露后端信息
- [ ] MySQL / Redis 端口只绑 `127.0.0.1`（compose 已处理）
- [ ] `ProxyDebugController` 只留在学习环境，上线前删除或加鉴权
- [ ] 跨域交给 Nginx 统一处理，`CorsMiddleware` 在生产可关闭
