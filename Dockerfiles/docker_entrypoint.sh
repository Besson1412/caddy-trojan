#!/bin/sh

# 0. 兼容变量别名
if [ -z "$MYDOMAINCF" ] && [ -n "$MYDOMAIN_CF" ]; then
    MYDOMAINCF="$MYDOMAIN_CF"
fi

# 启动 Caddy 的统一入口：若设置了出站代理 MYPROXY，则注入 ALL_PROXY 供 trojan env_proxy 使用
run_caddy() {
    if [ -n "$MYPROXY" ]; then
        echo "Info: Starting Caddy with outbound proxy: $MYPROXY"
        exec env ALL_PROXY="$MYPROXY" caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
    fi
    exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
}

# 间接变量读取：POSIX/busybox ash 没有 bash 的 ${!name}，用 eval 代替。
# 用法：get_var "MYDOMAIN_$NN"
get_var() {
    eval "printf '%s' \"\${$1:-}\""
}

# 确保伪装网站模板已就绪（多个 CDN 域名 profile 共用同一份，只需下载一次，
# 这里做成幂等函数供各处复用，而不是每个 profile 各自复制一遍下载逻辑）。
ensure_decoy_web() {
    mkdir -p /www/web
    if [ -f "/www/web/index.html" ] || [ -f "/www/web/index.php" ]; then
        return 0
    fi
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
}

# A. 自带 Caddyfile 模式：
# 如果用户挂载了一个非空的 /etc/caddy/Caddyfile，则完全尊重该配置，原样运行；
# 跳过自动生成以及 MYPASSWD / MYDOMAIN 校验（此时这两个变量可以不传）。
# 镜像构建时已删除 base 镜像自带的默认 Caddyfile，因此该文件存在即代表是用户挂载进来的。
if [ -s /etc/caddy/Caddyfile ]; then
    echo "Info: Detected a user-provided /etc/caddy/Caddyfile. Using it as-is (skip auto-generation)."
    run_caddy
fi

# 1. 验证核心环境变量
# 注意：base 镜像为 Alpine，/bin/sh 是 busybox ash，不支持 [[ ]]，这里统一使用 POSIX 的 [ ] 语法
if [ -z "$MYPASSWD" ] || [ "$MYPASSWD" = "123456" ] || [ "$MYPASSWD" = "MY_PASSWORD" ]; then
    echo "Error: Please reset your MYPASSWD." && exit 1
fi

# 未指定域名（为空或仍为默认占位符）时，自动探测公网 IP 并回退到 <IP>.nip.io，实现免域名开箱即用
if [ -z "$MYDOMAIN" ] || [ "$MYDOMAIN" = "1.1.1.1.nip.io" ] || [ "$MYDOMAIN" = "MY_DOMAIN.COM" ]; then
    echo "Info: MYDOMAIN not set. Detecting public IP for nip.io fallback..."
    PUBIP=$(wget -qO- https://api.ipify.org 2>/dev/null \
        || wget -qO- https://ifconfig.me 2>/dev/null \
        || wget -qO- https://ipinfo.io/ip 2>/dev/null)
    # 去掉可能的换行/空白
    PUBIP=$(echo "$PUBIP" | tr -d '[:space:]')
    if [ -n "$PUBIP" ]; then
        MYDOMAIN="${PUBIP}.nip.io"
        echo "Info: Using auto-generated domain: $MYDOMAIN"
    else
        echo "Error: MYDOMAIN not set and failed to auto-detect public IP. Please set MYDOMAIN explicitly." && exit 1
    fi
fi

# 1.5 扫描编号 profile（01~99）：多域名/多入口支持。
# 每个编号 NN 通过三个变量配置，全部可选，但至少要有一个域名才算这个 profile 生效：
#   MYDOMAIN_NN     直连域名（有自己的证书，直接暴露）
#   MYDOMAIN_CF_NN  经 CDN（如 Cloudflare）转发的域名（伪装成普通网站，未命中 trojan 认证时用 file_server 兜底）
#   MYPROXY_NN      这个入口的出站代理，纯 host:port（socks5，无需 scheme 前缀，也兼容带 socks5:// 前缀直接抄
#                   MYPROXY 格式的写法——会被自动去掉），不设置则该入口直连不经代理
# 不设置任何编号变量时，行为跟旧版完全一致（只有下面 MYDOMAIN/MYDOMAINCF/MYPROXY 这一个默认入口）。
NUMBERED_PROFILES=""
i=1
while [ "$i" -le 99 ]; do
    NN=$(printf '%02d' "$i")
    i=$((i + 1))
    d=$(get_var "MYDOMAIN_$NN")
    dcf=$(get_var "MYDOMAIN_CF_$NN")
    if [ -n "$d" ] || [ -n "$dcf" ]; then
        NUMBERED_PROFILES="$NUMBERED_PROFILES $NN"
    fi
done
if [ -n "$NUMBERED_PROFILES" ]; then
    echo "Info: Detected numbered entry profiles:$NUMBERED_PROFILES"
fi

# 2. 动态设置前置代理模式（写入自动生成的 Caddyfile）
TROJAN_PROXY_MODE="no_proxy"
if [ -n "$MYPROXY" ]; then
    TROJAN_PROXY_MODE="env_proxy"
fi

# 3. 构造 Caddyfile 全局配置块（trojan app 级配置，users/默认代理是全局共享的——
# 所有域名/入口用同一个 MYPASSWD 认证，区别只在于连的是哪个域名，从而在下面第 4/4.5
# 步走到哪个 proxy_name）
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
EOF

# 每个编号 profile 在这里注册一个具名代理（named_proxy），下面第 4.5 步生成的
# 对应 site block 用 `proxy_name $NN` 引用它——这样同一个 Caddy 进程里，不同域名
# 天然就能各自转发到不同的出口，不需要多起几个 Caddy 容器。
for NN in $NUMBERED_PROFILES; do
    proxy_target=$(get_var "MYPROXY_$NN")
    # 允许直接照抄 MYPROXY 那种 socks5://host:port 写法，这里统一去掉 scheme 前缀，
    # 因为 named_proxy 的 socks_proxy 类型只认 host:port（跟顶层 ALL_PROXY 的语义不同）。
    proxy_target=${proxy_target#socks5://}
    proxy_target=${proxy_target#socks://}
    if [ -n "$proxy_target" ]; then
        echo "        named_proxy $NN socks_proxy $proxy_target" >>/etc/caddy/Caddyfile
    else
        echo "        named_proxy $NN no_proxy" >>/etc/caddy/Caddyfile
    fi
done

cat <<EOF >>/etc/caddy/Caddyfile
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

# 4. 构造默认入口的服务块（MYDOMAIN / MYDOMAINCF）——跟旧版本完全一致，走的是全局
# 默认代理（第 2 步的 $TROJAN_PROXY_MODE / MYPROXY），不带 proxy_name。
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
    ensure_decoy_web

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

# 4.5 构造编号 profile 的服务块。跟第 4 步同一套写法，唯一区别是 trojan 子块里
# 多了一行 `proxy_name $NN`，指向第 3 步注册的那个具名代理；direct/CF 两种域名
# 独立可选（都不设置就整段跳过），互不依赖。
for NN in $NUMBERED_PROFILES; do
    d=$(get_var "MYDOMAIN_$NN")
    dcf=$(get_var "MYDOMAIN_CF_$NN")

    if [ -n "$d" ]; then
        # 注意：这里不能像默认入口那样写成 ":443, $d {"——裸 ":443" 是个通配地址
        # （不看 SNI，兜底吃掉所有连接），默认入口已经占了这一个通配，编号入口
        # 只按自己的域名（SNI）匹配即可，多个 site block 都声明 ":443" 会被 Caddy
        # 判定为 "ambiguous site definition"（实测踩过这个坑，见 CI 失败记录）。
        cat <<EOF >>/etc/caddy/Caddyfile
$d {
EOF
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
        proxy_name $NN
    }
EOF

        # 防探测姿态跟这个 NN 有没有自己的 CDN 伪装站companion（$dcf）无关，看整个
        # 部署有没有在用 CDN 伪装站模式（$MYDOMAINCF，全局那一个）——多域名场景下
        # 通常只共用一个伪装网站（比如 caddyray：18 个编号入口全部指向同一份
        # MYDOMAINCF，没有一个单独配自己的 MYDOMAIN_CF_NN），这时每一个直连域名
        # （包括编号入口）未认证访问都该表现成"服务暂时不可用"，不该有的编号入口
        # 502/503、有的却露出一个空的默认 file_server 目录列表——那反而是能被扫描器
        # 用来区分"哪些域名是真入口"的信号。没有任何 CDN 伪装站的部署（$MYDOMAINCF
        # 和这个 NN 的 $dcf 都没配）则维持原来的 file_server 兜底，不强加 503。
        if [ -n "$dcf" ] || [ -n "$MYDOMAINCF" ]; then
            cat <<EOF >>/etc/caddy/Caddyfile
    respond "Service Unavailable" 503 {
        close
    }
}
EOF
        else
            cat <<EOF >>/etc/caddy/Caddyfile
    @host_$NN host $d
    route @host_$NN {
        file_server {
            root /usr/share/caddy
        }
    }
}
EOF
        fi
    fi

    if [ -n "$dcf" ]; then
        ensure_decoy_web

        cat <<EOF >>/etc/caddy/Caddyfile
$dcf {
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
        proxy_name $NN
    }
    file_server {
        root /www/web
    }
}
EOF
    fi
done

# 5. 端口 80 强制跳转
cat <<EOF >>/etc/caddy/Caddyfile
:80 {
    redir https://{host}{uri} permanent
}
EOF

echo "Info: Dynamic Caddyfile compiled successfully."

# 6. 运行 Caddy
run_caddy
