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

use App\Http\Common\Controller\AbstractController;
use App\Http\Common\Result;
use Hyperf\Swagger\Annotation as OA;
use Hyperf\Swagger\Annotation\Get;
use Hyperf\Swagger\Annotation\Post;
use Mine\Support\Request;
use Psr\Http\Message\UploadedFileInterface;

/**
 * 代理层调试：把后端真正收到的请求原样回显。
 *
 * 用途：验证 nginx 转发后 header / query / body / cookie 到底变成了什么。
 * 学习环境专用，生产环境请删除本文件（或加 AccessTokenMiddleware）。
 */
#[OA\HyperfServer(name: 'http')]
final class ProxyDebugController extends AbstractController
{
    #[Get(
        path: '/admin/proxy/debug',
        operationId: 'proxyDebug',
        summary: '回显后端收到的请求（GET）',
        tags: ['admin:proxy']
    )]
    public function debug(Request $request): Result
    {
        return $this->success($this->payload($request));
    }

    #[Post(
        path: '/admin/proxy/debug',
        operationId: 'proxyDebugPost',
        summary: '回显后端收到的请求（POST）',
        tags: ['admin:proxy']
    )]
    public function debugPost(Request $request): Result
    {
        return $this->success($this->payload($request));
    }

    private function payload(Request $request): array
    {
        $server = $request->getServerParams();

        return [
            'request_line' => sprintf('%s %s', $request->getMethod(), (string) $request->getUri()),
            'method' => $request->getMethod(),
            'path' => $request->getUri()->getPath(),
            'query_string' => $request->getUri()->getQuery(),
            'scheme' => $request->getUri()->getScheme(),
            'port' => $request->getUri()->getPort(),
            'host_header' => $request->getHeaderLine('host'),

            // 三种「客户端 IP」来源，放在一起对比
            'ip' => [
                // nginx: proxy_set_header X-Real-IP $remote_addr
                'x-real-ip' => $request->getHeaderLine('x-real-ip'),
                // nginx: proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for
                'x-forwarded-for' => $request->getHeaderLine('x-forwarded-for'),
                // Swoole 看到的 TCP 对端，未经代理就是 nginx 容器的内网 IP
                'remote_addr' => $server['remote_addr'] ?? null,
                // MineAdmin 的 ClientIpRequestTrait；没登记信任代理时等于 remote_addr
                'getClientIps' => $request->getClientIps(),
            ],

            'headers' => $request->getHeaders(),
            'query' => $request->getQueryParams(),
            'parsed_body' => $this->sanitize($request->getParsedBody()),
            'input_all' => $this->sanitize($request->all()),
            'cookies' => $request->getCookieParams(),
            'server' => $server,
        ];
    }

    /**
     * 上传文件是对象，不能直接 JSON 序列化，转成可读数组。
     */
    private function sanitize(mixed $value): mixed
    {
        if ($value instanceof UploadedFileInterface) {
            return [
                'client_filename' => $value->getClientFilename(),
                'client_media_type' => $value->getClientMediaType(),
                'size' => $value->getSize(),
                'error' => $value->getError(),
            ];
        }

        if (is_array($value)) {
            return array_map(fn ($item) => $this->sanitize($item), $value);
        }

        return $value;
    }
}
