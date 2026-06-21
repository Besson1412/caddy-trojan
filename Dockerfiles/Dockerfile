FROM caddy:latest

ENV MYPASSWD=123456 \
    MYDOMAIN=1.1.1.1.nip.io \
    MYEMAIL="" \
    MYDOMAINCF="" \
    MYPROXY=""

# 为 entrypoint 脚本设置可执行权限，并使用 add-package 构建 caddy-trojan 扩展
COPY docker_entrypoint.sh /docker_entrypoint.sh
RUN chmod +x /docker_entrypoint.sh \
    && caddy add-package github.com/imgk/caddy-trojan \
    && mkdir -p /www/web \
    && echo '<html><head><title>Welcome</title></head><body><h1>Service is running.</h1></body></html>' > /www/web/index.html \
    && rm -f /etc/caddy/Caddyfile

EXPOSE 80
EXPOSE 443

ENTRYPOINT ["/docker_entrypoint.sh"]
