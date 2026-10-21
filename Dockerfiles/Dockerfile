FROM caddy:latest

ENV MYPASSWD=123456 \
    MYDOMAIN=1.1.1.1.nip.io \
    MYEMAIL="" \
    MYDOMAINCF="" \
    MYPROXY=""
# CF_DNS_API_TOKEN（可选，ACME DNS-01）故意不在这里声明默认值：它是密钥，只应在运行时
# 通过 docker run -e / compose 传入，不能出现在镜像层里（也避免 BuildKit 的
# SecretsUsedInArgOrEnv 警告）。未设置时 entrypoint 按旧方式签证书。

# 为 entrypoint 脚本设置可执行权限，并使用 add-package 构建 caddy-trojan 扩展；
# caddy-dns/cloudflare 用于可选的 ACME DNS-01 验证（设置 CF_DNS_API_TOKEN 时启用，
# 见 docker_entrypoint.sh 第 3 步）
COPY docker_entrypoint.sh /docker_entrypoint.sh
RUN chmod +x /docker_entrypoint.sh \
    && caddy add-package github.com/imgk/caddy-trojan github.com/caddy-dns/cloudflare \
    && mkdir -p /www/web \
    && echo '<html><head><title>Welcome</title></head><body><h1>Service is running.</h1></body></html>' > /www/web/index.html \
    && rm -f /etc/caddy/Caddyfile

EXPOSE 80
EXPOSE 443

ENTRYPOINT ["/docker_entrypoint.sh"]
