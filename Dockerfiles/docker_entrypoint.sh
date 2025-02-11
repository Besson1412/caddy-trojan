#!/bin/sh

if [[ "$MYPASSWD" == "123456" || "$MYPASSWD" == "MY_PASSWORD" ]]; then
    echo please reset your password && exit 1
fi

if [[ "$MYDOMAIN" == "1.1.1.1.nip.io" || "$MYDOMAIN" == "MY_DOMAIN.COM" ]]; then
    echo please reset your domain name && exit 1
fi

if [[ "$MYEMAIL" == "admin@nip.io" || "$MYEMAIL" == "MY_EMAIL" ]]; then
    echo please reset your email && exit 1
fi

if [[ "$MYDOMAINCF" == "1.1.1.1.nip.io" || "$MYDOMAINCF" == "MY_DOMAIN.COM" ]]; then
    echo please reset your domain name && exit 1
fi

# 根据 MYPROXY 是否为空来决定使用 no_proxy 还是 env_proxy
if [ -z "$MYPROXY" ]; then
    TROJAN_PROXY_MODE="no_proxy"
    RUN_CMD="caddy run --config /etc/caddy/Caddyfile --adapter caddyfile"
else
    TROJAN_PROXY_MODE="env_proxy"
    RUN_CMD="env ALL_PROXY=$MYPROXY caddy run --config /etc/caddy/Caddyfile --adapter caddyfile"
fi

# config
cat <<EOF >/etc/caddy/Caddyfile
{
    order trojan before respond
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
:443, $MYDOMAIN {
    tls $MYEMAIL {
        protocols tls1.2 tls1.2
        ciphers TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256 TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256
    }
    log {
        level ERROR
    }
    trojan {
        websocket
    }
    respond "Service Unavailable" 503 {
        close
    }
}
$MYDOMAINCF {
    tls $MYEMAIL {
		protocols tls1.2 tls1.3
		ciphers TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256 TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384 TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256 TLS_AES_128_GCM_SHA256 TLS_AES_256_GCM_SHA384 TLS_CHACHA20_POLY1305_SHA256
	}
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
:80 {
    redir https://{host}{uri} permanent
}
EOF

# 启动 Caddy
exec $RUN_CMD