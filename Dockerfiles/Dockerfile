FROM caddy:latest

ENV MYPASSWD=123456 \
    MYDOMAIN=1.1.1.1.nip.io \
	MYEMAIL=admin@nip.io \
	MYDOMAINCF=1.1.1.1.nip.io \
	MYPROXY=""

# 为 entrypoint 脚本设置可执行权限，并安装 caddy-trojan 扩展
COPY docker_entrypoint.sh /docker_entrypoint.sh
RUN chmod +x /docker_entrypoint.sh \
    && caddy add-package github.com/imgk/caddy-trojan
# 下载 web.tar.gz 并解压到 /www/web 目录
    && wget -O web.tar.gz https://raw.githubusercontent.com/Besson1412/caddy-trojan/main/basic/web.tar.gz \
    && tar xzf web.tar.gz -C /www/web \
    && rm -f web.tar.gz
EXPOSE 80
EXPOSE 443

ENTRYPOINT ["/docker_entrypoint.sh"]