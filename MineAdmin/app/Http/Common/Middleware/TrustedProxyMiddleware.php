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

namespace App\Http\Common\Middleware;

use App\Http\Admin\Request\PassportLoginRequest;
use Mine\Support\Request;
use Mine\Support\Request\ClientIpRequestConstant;
use Psr\Http\Message\ResponseInterface;
use Psr\Http\Message\ServerRequestInterface;
use Psr\Http\Server\MiddlewareInterface;
use Psr\Http\Server\RequestHandlerInterface;

/**
 * 让 MineAdmin 的 getClientIps() 在 nginx 反代之后仍然拿得到真实客户端 IP。
 *
 * 背景：
 *   ClientIpRequestTrait::getClientIps() 只有在「remote_addr 属于受信任代理」时，
 *   才会去读 X-Forwarded-For；否则直接返回 remote_addr。
 *   走 nginx 后 remote_addr 是 nginx 容器的内网 IP（172.x），
 *   所以登录日志、操作日志里的 IP 会变成 172.x。
 *
 * 注意（PHP 语义）：
 *   trait 里的 static 属性是「每个使用该 trait 的类各存一份」，
 *   所以必须把用到 ClientIpRequestTrait 的类逐个登记。
 *   新增了直接 use ClientIpRequestTrait 的 FormRequest，也要加到这里。
 */
final class TrustedProxyMiddleware implements MiddlewareInterface
{
    /** 受信任的代理地址段；docker compose 默认网络是 172.16.0.0/12 */
    private const PROXIES = ['PRIVATE_SUBNETS'];

    /** 需要信任的转发头 */
    private const HEADER_SET = ClientIpRequestConstant::HEADER_X_FORWARDED_FOR
        | ClientIpRequestConstant::HEADER_X_FORWARDED_HOST
        | ClientIpRequestConstant::HEADER_X_FORWARDED_PROTO
        | ClientIpRequestConstant::HEADER_X_FORWARDED_PORT;

    public function process(ServerRequestInterface $request, RequestHandlerInterface $handler): ResponseInterface
    {
        $this->register();

        return $handler->handle($request);
    }

    private function register(): void
    {
        Request::setTrustedProxies(self::PROXIES, self::HEADER_SET);
        PassportLoginRequest::setTrustedProxies(self::PROXIES, self::HEADER_SET);
    }
}
