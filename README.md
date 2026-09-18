# Caddy-Trojan -- A Caddy Module for Trojan Proxy

## Build with xcaddy
```
$ xcaddy build --with github.com/imgk/caddy-trojan
```

##  Config (Caddyfile)
```
{
	order trojan before file_server
	servers :443 {
		listener_wrappers {
			trojan
		}
	}
	trojan {
		caddy
		# memory

		no_proxy
		# env_proxy
		# socks_proxy server user passwd
		# socks_proxy server
		# http_proxy server user passwd
		# http_proxy server
		# named_proxy proxy_name proxy_type args...

		users pass1234 word5678
	}
}
:443, example.com {
	tls your@email.com #optional,recommended
	trojan {
		connect_method
		websocket
	}
	file_server {
		root /var/www/html
	}
}
```
##  Config (JSON)
```
{
  "apps": {
    "http": {
      "servers": {
        "srv0": {
          "listen": [":443"],
          "listener_wrappers": [{
            "wrapper": "trojan",
            "proxy_name": "proxy_2"
          }],
          "routes": [{
            "handle": [{
              "handler": "trojan",
              "connect_method": true,
              "websocket": true,
              "proxy_name": "proxy_3"
            },
            {
              "handler": "file_server",
              "root": "/var/www/html"
            }]
          }]
        }
      }
    },
    "trojan": {
      "named_proxy": {
        "proxy_1": {
          "proxy": "none"
        },
        "proxy_2": {
          "proxy": "socks",
          "server": "127.0.0.1:1080"
        },
        "proxy_3": {
          "proxy": "http",
          "server": "127.0.0.1:8080"
        }
      },
      "proxy": { //optional
        "proxy": "none"
      },
      "upstream": { //optional
        "upstream": "caddy"
      },
      "users": ["pass1234","word5678"]
    },
    "tls": {
      "certificates": {
        "automate": ["example.com"]
      },
      "automation": {
        "policies": [{
          "issuers": [{
            "module": "acme",
            "email": "your@email.com" //optional,recommended
          },
          {
            "module": "acme",
            "ca": "https://acme.zerossl.com/v2/DV90",
            "email": "your@email.com" //optional,recommended
          }]
        }]
      }
    }
  }
}
```

## Manage Users

1. Add user.
```
curl -X POST -H "Content-Type: application/json" -d '{"password": "test1234"}' http://localhost:2019/trojan/users/add
```

## Docker

```
git clone https://github.com/imgk/caddy-trojan
cd caddy-trojan/Dockerfiles
docker build -t caddy-trojan .
docker run --env MYPASSWD=MY_PASSWORD --env MYDOMAIN=MY_DOMAIN.COM -itd --name caddy-trojan --restart always -p 80:80 -p 443:443 caddy-trojan
```

## Multiple entry domains, one container (Besson1412 fork)

`Dockerfiles/docker_entrypoint.sh` in this fork generates the Caddyfile from environment
variables at container startup. Besides the single default entry (`MYPASSWD` / `MYDOMAIN` /
`MYDOMAINCF` / `MYPROXY`, unchanged from upstream), it also supports up to 99 additional
numbered entries, each an independent domain (or domain pair) that forwards to its own
upstream proxy — useful for exposing several regional exits (e.g. a JP entry and a US entry)
behind one Trojan password, without running multiple Caddy containers. This relies entirely
on the upstream `named_proxy` / `proxy_name` Caddyfile directives already documented above —
no code changes to the Go module were needed.

For each two-digit number `NN` (`01`–`99`):

| Variable | Required | Meaning |
|---|---|---|
| `MYDOMAIN_NN` | at least one of `MYDOMAIN_NN` / `MYDOMAIN_CF_NN` | Direct-connect domain for this entry, gets its own TLS cert. |
| `MYDOMAIN_CF_NN` | " | CDN-fronted domain for this entry (e.g. behind Cloudflare), served with the decoy site like `MYDOMAINCF`. |
| `MYPROXY_NN` | no | Outbound SOCKS5 proxy for traffic from this entry, as `host:port` (a `socks5://` prefix is accepted and stripped). If unset, this entry connects directly with no proxy. |

A numbered entry is only generated if at least one of `MYDOMAIN_NN` / `MYDOMAIN_CF_NN` is
set; you can set just one of the two, or both (same direct-vs-CDN semantics as the default
entry). Entries you don't configure simply don't exist — setting none of these variables
reproduces the exact behavior of the unmodified upstream image.

An unauthenticated request to `MYDOMAIN_NN` (a direct entry with no `MYDOMAIN_CF_NN` of its
own) gets a bare `503 Service Unavailable` if this entry has its own `MYDOMAIN_CF_NN`, *or*
if the top-level `MYDOMAINCF` is set anywhere in this deployment — that second case covers
the common pattern of one shared decoy site fronting many direct-connect entries, where you
want every direct domain to look equally "unavailable" rather than only the ones with their
own dedicated CDN companion. With no CDN pattern configured at all, it falls back to serving
`/usr/share/caddy` like the default entry does.

```
docker run \
  --env MYPASSWD=MY_PASSWORD \
  --env MYDOMAIN=direct.example.com \
  --env MYDOMAIN_01=jp.example.com --env MYPROXY_01=jp-exit.internal:1080 \
  --env MYDOMAIN_02=us.example.com --env MYDOMAIN_CF_02=us-cf.example.com --env MYPROXY_02=us-exit.internal:1080 \
  -itd --name caddy-trojan --restart always -p 80:80 -p 443:443 caddy-trojan
```

Here, connecting to `direct.example.com` uses the default (no-proxy) exit as before; connecting
to `jp.example.com` or `us.example.com` (with the same `MYPASSWD`) is transparently forwarded
through `jp-exit.internal:1080` / `us-exit.internal:1080` respectively — the client just dials
a different hostname to pick a different exit.
