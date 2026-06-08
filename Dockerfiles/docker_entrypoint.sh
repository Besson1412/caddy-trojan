#!/bin/sh

# 0. 兼容变量别名
if [ -z "$MYDOMAINCF" ] && [ -n "$MYDOMAIN_CF" ]; then
    MYDOMAINCF="$MYDOMAIN_CF"
fi

# 1. 验证核心环境变量
if [[ "$MYPASSWD" == "123456" || "$MYPASSWD" == "MY_PASSWORD" ]]; then
    echo "Error: Please reset your MYPASSWD." && exit 1
fi

if [[ "$MYDOMAIN" == "1.1.1.1.nip.io" || "$MYDOMAIN" == "MY_DOMAIN.COM" ]]; then
    echo "Error: Please reset your MYDOMAIN." && exit 1
fi

# 2. 动态设置前置代理与运行命令
TROJAN_PROXY_MODE="no_proxy"
RUN_CMD="caddy run --config /etc/caddy/Caddyfile --adapter caddyfile"
if [ -n "$MYPROXY" ]; then
    TROJAN_PROXY_MODE="env_proxy"
    RUN_CMD="env ALL_PROXY=$MYPROXY caddy run --config /etc/caddy/Caddyfile --adapter caddyfile"
    echo "Info: Starting Caddy with outbound proxy: $MYPROXY"
fi

# 3. 构造 Caddyfile 全局配置块
cat <<EOF >/etc/caddy/Caddyfile
{
    order trojan before respond
    order trojan before route
    https_port 443
    servers :443 {
        listener_wrappers {
            trojan
        }
        protocols h2 h1
    }
    servers :80 {
        protocols h1
    }
    trojan {
        caddy
        $TROJAN_PROXY_MODE
        users $MYPASSWD
    }
    log {
        output file /var/log/caddy/access.log
        format json {
            time_local
            time_format wall_milli
        }
    }
}
EOF

# 4. 构造直接连接的服务块 (MYDOMAIN)
cat <<EOF >>/etc/caddy/Caddyfile
:443, $MYDOMAIN {
EOF

# 判断是否配置了证书邮箱
if [ -n "$MYEMAIL" ]; then
    cat <<EOF >>/etc/caddy/Caddyfile
    tls $MYEMAIL {
        protocols tls1.2 tls1.2
        ciphers TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256 TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256
    }
EOF
else
    cat <<EOF >>/etc/caddy/Caddyfile
    tls {
        protocols tls1.2 tls1.2
        ciphers TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256 TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256
    }
EOF
fi

cat <<EOF >>/etc/caddy/Caddyfile
    log {
        level ERROR
    }
    trojan {
        websocket
    }
EOF

# 判断是否启用了 CDN 伪装站模式 (双域名分离)
if [ -n "$MYDOMAINCF" ]; then
    # 动态检测网页目录是否存在。如果不含有首页内容，则自动从分叉库拉取经典伪装网页模板
    mkdir -p /www/web
    if [ ! -f "/www/web/index.html" ] && [ ! -f "/www/web/index.php" ]; then
        echo "Info: /www/web is empty. Downloading decoy web template automatically..."
        if wget -q -O /tmp/web.tar.gz https://raw.githubusercontent.com/Besson1412/caddy-trojan/main/basic/web.tar.gz; then
            tar xzf /tmp/web.tar.gz -C /www/web
            rm -f /tmp/web.tar.gz
            echo "Success: Decoy web template loaded successfully."
        else
            echo "Warning: Failed to download template. Generating default placeholder index.html."
            cat <<EOF >/www/web/index.html
<html>
<head><title>Under Construction</title></head>
<body><h1>Site is under construction. Please check back later.</h1></body>
</html>
EOF
        fi
    fi

    # 启用防探测模式：直连域名访问普通 HTTP/HTTPS 直接返回 503 阻断连接
    cat <<EOF >>/etc/caddy/Caddyfile
    respond "Service Unavailable" 503 {
        close
    }
}
EOF

    # 构造 CDN 域名伪装站块 (MYDOMAINCF)
    cat <<EOF >>/etc/caddy/Caddyfile
$MYDOMAINCF {
EOF
    if [ -n "$MYEMAIL" ]; then
        cat <<EOF >>/etc/caddy/Caddyfile
    tls $MYEMAIL {
        protocols tls1.2 tls1.3
    }
EOF
    else
        cat <<EOF >>/etc/caddy/Caddyfile
    tls {
        protocols tls1.2 tls1.3
    }
EOF
    fi

    cat <<EOF >>/etc/caddy/Caddyfile
    log {
        level ERROR
    }
    trojan {
        websocket
    }
    file_server {
        root /www/web
    }
}
EOF
else
    # 未启用 CDN 伪装站模式：行为与上游 100% 一致，普通请求 fallback 到静态测试页面
    cat <<EOF >>/etc/caddy/Caddyfile
    @host host $MYDOMAIN
    route @host {
        file_server {
            root /usr/share/caddy
        }
    }
}
EOF
fi

# 5. 端口 80 强制跳转
cat <<EOF >>/etc/caddy/Caddyfile
:80 {
    redir https://{host}{uri} permanent
}
EOF

echo "Info: Dynamic Caddyfile compiled successfully."

# 6. 运行 Caddy
exec $RUN_CMD