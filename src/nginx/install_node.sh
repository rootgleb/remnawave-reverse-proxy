#!/bin/bash
# Module: Install Node Only
#
# Fork: one node, every transport on port 443.
#
#   TCP 443  xray  VLESS raw + Vision + REALITY  (<tag>-vision)
#     └─ not this REALITY ─▶ unix:/dev/shm/xhttp.sock  (PROXY v1)
#          xray  VLESS XHTTP + REALITY              (<tag>-xhttp)
#            └─ not this REALITY ─▶ unix:/dev/shm/nginx.sock (PROXY v1)
#                 nginx, real Let's Encrypt certificate
#                   ├─ /<grpc service>/  ─▶ unix:/dev/shm/grpc.sock
#                   │     xray  VLESS gRPC, TLS terminated by nginx (<tag>-grpc)
#                   └─ everything else    ─▶ selfsteal site
#   UDP 443  xray  Hysteria2, same certificate     (<tag>-hy2)
#
# The ready-to-paste config profile is written to /opt/remnanode/config.txt,
# client-side host settings to /opt/remnanode/hosts.txt. No outbounds besides
# DIRECT and BLOCK — bridges are added by hand.

# 32-byte X25519 key pair, base64url without padding — the format xray uses.
# Prints "<private> <public>".
xray_x25519_pair() {
    local tmp
    tmp=$(mktemp) || return 1
    openssl genpkey -algorithm X25519 -out "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    local priv pub
    priv=$(openssl pkey -in "$tmp" -outform DER 2>/dev/null | tail -c 32 | base64 -w0 | tr '+/' '-_' | tr -d '=')
    pub=$(openssl pkey -in "$tmp" -pubout -outform DER 2>/dev/null | tail -c 32 | base64 -w0 | tr '+/' '-_' | tr -d '=')
    rm -f "$tmp"
    [ ${#priv} -eq 43 ] && [ ${#pub} -eq 43 ] || return 1
    echo "$priv $pub"
}

# Something that reads like an ordinary internal API name in an access log.
random_grpc_service() {
    local nouns=(metrics telemetry sync events billing storage media search feed notify)
    local verbs=(Collector Ingest Stream Gateway Relay Exchange Dispatch Bridge)
    local n=${nouns[$((RANDOM % ${#nouns[@]}))]}
    local v=${verbs[$((RANDOM % ${#verbs[@]}))]}
    echo "${n}.v$((RANDOM % 3 + 1)).${v}$(openssl rand -hex 2)"
}

generate_node_xray_params() {
    local pair
    pair=$(xray_x25519_pair) || { echo -e "${COLOR_RED}X25519 key generation failed (openssl)${COLOR_RESET}"; return 1; }
    VISION_PRIVATE_KEY=${pair% *}; VISION_PUBLIC_KEY=${pair#* }
    pair=$(xray_x25519_pair) || { echo -e "${COLOR_RED}X25519 key generation failed (openssl)${COLOR_RESET}"; return 1; }
    XHTTP_PRIVATE_KEY=${pair% *}; XHTTP_PUBLIC_KEY=${pair#* }

    VISION_SHORT_ID_1=$(openssl rand -hex 8)
    VISION_SHORT_ID_2=$(openssl rand -hex 8)
    XHTTP_SHORT_ID_1=$(openssl rand -hex 8)
    XHTTP_SHORT_ID_2=$(openssl rand -hex 8)
    XHTTP_PATH="/$(openssl rand -hex 6)"
    GRPC_SERVICE=$(random_grpc_service)

    # Inbound tags are global in the panel: prefix them with the first label
    # of the selfsteal domain so two nodes never collide.
    NODE_TAG=$(echo "${SELFSTEAL_DOMAIN%%.*}" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9-\n' '-')
    [ -z "$NODE_TAG" ] && NODE_TAG="node$(openssl rand -hex 2)"
    return 0
}

write_node_config_profile() {
    local cert_dir="/etc/letsencrypt/live/$NODE_CERT_DOMAIN"

    cat > /opt/remnanode/config.txt <<EOL
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "${NODE_TAG}-vision",
      "port": 443,
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "flow": "xtls-rprx-vision",
        "clients": [],
        "decryption": "none"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      },
      "streamSettings": {
        "network": "raw",
        "sockopt": {
          "tcpKeepAliveIdle": 300,
          "tcpKeepAliveInterval": 60
        },
        "security": "reality",
        "realitySettings": {
          "show": false,
          "xver": 1,
          "target": "/dev/shm/xhttp.sock",
          "shortIds": ["${VISION_SHORT_ID_1}", "${VISION_SHORT_ID_2}"],
          "privateKey": "${VISION_PRIVATE_KEY}",
          "maxTimeDiff": 60000,
          "serverNames": ["${SELFSTEAL_DOMAIN}"]
        }
      }
    },
    {
      "tag": "${NODE_TAG}-xhttp",
      "port": 0,
      "listen": "/dev/shm/xhttp.sock,0600",
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      },
      "streamSettings": {
        "network": "xhttp",
        "sockopt": {
          "acceptProxyProtocol": true
        },
        "security": "reality",
        "xhttpSettings": {
          "mode": "auto",
          "path": "${XHTTP_PATH}"
        },
        "realitySettings": {
          "show": false,
          "xver": 1,
          "target": "/dev/shm/nginx.sock",
          "shortIds": ["${XHTTP_SHORT_ID_1}", "${XHTTP_SHORT_ID_2}"],
          "privateKey": "${XHTTP_PRIVATE_KEY}",
          "maxTimeDiff": 60000,
          "serverNames": ["${SELFSTEAL_DOMAIN}"]
        }
      }
    },
    {
      "tag": "${NODE_TAG}-grpc",
      "port": 0,
      "listen": "/dev/shm/grpc.sock,0666",
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      },
      "streamSettings": {
        "network": "grpc",
        "security": "none",
        "grpcSettings": {
          "serviceName": "${GRPC_SERVICE}"
        }
      }
    },
    {
      "tag": "${NODE_TAG}-hy2",
      "port": 443,
      "listen": "0.0.0.0",
      "protocol": "hysteria",
      "settings": {
        "clients": [],
        "version": 2
      },
      "streamSettings": {
        "network": "hysteria",
        "security": "tls",
        "finalmask": {
          "quicParams": {
            "debug": false,
            "congestion": "bbr"
          }
        },
        "tlsSettings": {
          "alpn": ["h3"],
          "serverName": "${SELFSTEAL_DOMAIN}",
          "certificates": [
            {
              "certificateFile": "${cert_dir}/fullchain.pem",
              "keyFile": "${cert_dir}/privkey.pem"
            }
          ]
        },
        "hysteriaSettings": {
          "version": 2
        }
      }
    }
  ],
  "outbounds": [
    {
      "tag": "DIRECT",
      "protocol": "freedom",
      "settings": {}
    },
    {
      "tag": "BLOCK",
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "rules": [
      {
        "ip": ["geoip:private"],
        "outboundTag": "BLOCK"
      }
    ]
  }
}
EOL

    cat > /opt/remnanode/hosts.txt <<EOL
Hosts to create in the panel (Hosts → +). Address everywhere: ${SELFSTEAL_DOMAIN}, port 443.
The panel derives REALITY public keys from the private keys in the profile;
they are listed here only for checking.

1. ${NODE_TAG}-vision   VLESS Vision REALITY
   SNI: ${SELFSTEAL_DOMAIN}   fingerprint: chrome
   publicKey: ${VISION_PUBLIC_KEY}
   shortIds:  ${VISION_SHORT_ID_1}, ${VISION_SHORT_ID_2}

2. ${NODE_TAG}-xhttp    VLESS XHTTP REALITY
   SNI: ${SELFSTEAL_DOMAIN}   fingerprint: chrome   path: ${XHTTP_PATH}   mode: auto
   publicKey: ${XHTTP_PUBLIC_KEY}
   shortIds:  ${XHTTP_SHORT_ID_1}, ${XHTTP_SHORT_ID_2}

3. ${NODE_TAG}-grpc     VLESS gRPC over real TLS (nginx)
   Security layer: TLS (override in the host — the inbound itself is "none")
   SNI: ${SELFSTEAL_DOMAIN}   ALPN: h2   fingerprint: chrome
   serviceName: ${GRPC_SERVICE}

4. ${NODE_TAG}-hy2      Hysteria2 (UDP 443)
   SNI: ${SELFSTEAL_DOMAIN}   ALPN: h3   no obfuscation

Then enable all four inbounds on the node (Nodes → node → config profile)
and add them to the users' internal squad.
EOL
    chmod 600 /opt/remnanode/config.txt /opt/remnanode/hosts.txt
}

install_node_nginx() {
    # Load selfsteal templates module
    load_selfsteal_templates_module

    mkdir -p /opt/remnanode && cd /opt/remnanode

    reading "${LANG[SELFSTEAL]}" SELFSTEAL_DOMAIN

    check_domain "$SELFSTEAL_DOMAIN" true false
    local domain_check_result=$?
    if [ $domain_check_result -eq 2 ]; then
        echo -e "${COLOR_RED}${LANG[ABORT_MESSAGE]}${COLOR_RESET}"
        exit 1
    fi

    while true; do
        reading "${LANG[PANEL_IP_PROMPT]}" PANEL_IP
        if echo "$PANEL_IP" | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' >/dev/null && \
           [[ $(echo "$PANEL_IP" | tr '.' '\n' | wc -l) -eq 4 ]] && \
           [[ ! $(echo "$PANEL_IP" | tr '.' '\n' | grep -vE '^[0-9]{1,3}$') ]] && \
           [[ ! $(echo "$PANEL_IP" | tr '.' '\n' | grep -E '^(25[6-9]|2[6-9][0-9]|[3-9][0-9]{2})$') ]]; then
            break
        else
            echo -e "${COLOR_RED}${LANG[IP_ERROR]}${COLOR_RESET}"
        fi
    done

    echo -n "$(question "${LANG[CERT_PROMPT]}")"
    CERTIFICATE=""
    while IFS= read -r line; do
        if [ -z "$line" ]; then
            if [ -n "$CERTIFICATE" ]; then
                break
            fi
        else
            CERTIFICATE="$CERTIFICATE$line\n"
        fi
    done

    echo -e "${COLOR_YELLOW}${LANG[CERT_CONFIRM]}${COLOR_RESET}"
    read_yn confirm || { echo -e "${COLOR_RED}${LANG[ABORT_MESSAGE]}${COLOR_RESET}"; exit 1; }

    generate_node_xray_params || exit 1

SELFSTEAL_BASE_DOMAIN=$(extract_domain "$SELFSTEAL_DOMAIN")

unique_domains["$SELFSTEAL_BASE_DOMAIN"]=1

cat > docker-compose.yml <<EOL
x-common: &common
  ulimits:
    nofile:
      soft: 1048576
      hard: 1048576
  restart: always

x-logging: &logging
  logging:
    driver: json-file
    options:
      max-size: 100m
      max-file: 5

services:
  remnawave-nginx:
    image: nginx:1.30
    container_name: remnawave-nginx
    hostname: remnawave-nginx
    <<: [*common, *logging]
    network_mode: host
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
EOL
}

installation_node() {
    check_node_not_running
    check_port_443_free
    load_certificates_module
    echo -e "${COLOR_YELLOW}${LANG[INSTALLING_NODE]}${COLOR_RESET}"
    sleep 1

    declare -A unique_domains
    install_node_nginx

    declare -A domains_to_check
    domains_to_check["$SELFSTEAL_DOMAIN"]=1

    handle_certificates domains_to_check "$CERT_METHOD" "$LETSENCRYPT_EMAIL" "/opt/remnanode" || return 1

    # The certificate directory is the lineage that actually covers the
    # domain — a wildcard base or a -0001 renewal suffix, not a guess from
    # the issuance method
    NODE_CERT_DOMAIN=$(resolve_certificate_domain "$SELFSTEAL_DOMAIN") || return 1

    # remnanode gets the whole /etc/letsencrypt: Hysteria2 reads the same
    # certificate, and a directory mount follows certbot's symlinks to the
    # renewed files (a per-file mount would pin the old inode).
    cat >> /opt/remnanode/docker-compose.yml <<EOL
      - /dev/shm:/dev/shm:rw
      - /var/www/html:/var/www/html:ro
    command: sh -c 'rm -f /dev/shm/nginx.sock && exec nginx -g "daemon off;"'

  remnanode:
    image: remnawave/node:latest
    container_name: remnanode
    hostname: remnanode
    <<: [*common, *logging]
    network_mode: host
    cap_add:
      - NET_ADMIN
    environment:
      - NODE_PORT=2222
      - SECRET_KEY=$(echo -e "$CERTIFICATE")
    volumes:
      - /dev/shm:/dev/shm:rw
      - /var/log/remnanode:/var/log/remnanode
      - /etc/letsencrypt:/etc/letsencrypt:ro
EOL

cat > /opt/remnanode/nginx.conf <<EOL
server_names_hash_bucket_size 64;

map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ""      close;
}

ssl_protocols TLSv1.2 TLSv1.3;
ssl_ecdh_curve X25519:prime256v1:secp384r1;
ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305';
ssl_prefer_server_ciphers on;
ssl_session_timeout 1d;
ssl_session_cache shared:MozSSL:10m;
ssl_session_tickets off;
server_tokens off;

# Real client address arrives in the PROXY header xray adds on the socket
set_real_ip_from unix:;
real_ip_header proxy_protocol;

server {
    server_name $SELFSTEAL_DOMAIN;
    listen unix:/dev/shm/nginx.sock ssl proxy_protocol;
    http2 on;

    ssl_certificate "/etc/nginx/ssl/$NODE_CERT_DOMAIN/fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/$NODE_CERT_DOMAIN/privkey.pem";
    ssl_trusted_certificate "/etc/nginx/ssl/$NODE_CERT_DOMAIN/fullchain.pem";

    root /var/www/html;
    index index.html;
    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet, noimageindex" always;

    # gRPC tunnel (inbound ${NODE_TAG}-grpc). Anything that is not gRPC gets
    # the same 404 as any other missing page.
    location /$GRPC_SERVICE/ {
        if (\$content_type !~ "^application/grpc") {
            return 404;
        }
        grpc_pass unix:/dev/shm/grpc.sock;
        grpc_set_header X-Real-IP \$remote_addr;
        grpc_socket_keepalive on;
        grpc_read_timeout 1d;
        grpc_send_timeout 1d;
        client_body_timeout 1d;
        client_max_body_size 0;
        client_body_buffer_size 512k;
    }
}

server {
    listen unix:/dev/shm/nginx.sock ssl proxy_protocol default_server;
    server_name _;
    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet, noimageindex" always;
    ssl_reject_handshake on;
    return 444;
}
EOL

    write_node_config_profile

    ufw allow from $PANEL_IP to any port 2222 > /dev/null 2>&1
    # Hysteria2 listens on UDP 443 next to the TCP listener
    ufw allow 443/udp comment 'Hysteria2' > /dev/null 2>&1
    ufw reload > /dev/null 2>&1

    echo -e "${COLOR_YELLOW}${LANG[STARTING_NODE]}${COLOR_RESET}"
    sleep 3
    cd /opt/remnanode
    docker compose up -d > /dev/null 2>&1 &

    spinner $! "${LANG[WAITING]}"

    randomhtml || exit 1

    # Until the profile from config.txt is assigned in the panel nothing
    # listens on 443, so check the containers and nginx's socket instead
    # of fetching https://domain.
    printf "${COLOR_YELLOW}${LANG[NODE_CHECK]}${COLOR_RESET}\n" "$SELFSTEAL_DOMAIN"
    local max_attempts=5
    local attempt=1
    local delay=15

    while [ $attempt -le $max_attempts ]; do
        printf "${COLOR_YELLOW}${LANG[NODE_ATTEMPT]}${COLOR_RESET}\n" "$attempt" "$max_attempts"
        if [ -S /dev/shm/nginx.sock ] && \
           [ "$(docker inspect -f '{{.State.Running}}' remnawave-nginx 2>/dev/null)" = "true" ] && \
           docker exec remnawave-nginx nginx -t >/dev/null 2>&1 && \
           [ "$(docker inspect -f '{{.State.Running}}' remnanode 2>/dev/null)" = "true" ]; then
            step_ok "${LANG[NODE_LAUNCHED]}"
            break
        else
            printf "${COLOR_RED}${LANG[NODE_UNAVAILABLE]}${COLOR_RESET}\n" "$attempt"
            if [ $attempt -eq $max_attempts ]; then
                printf "${COLOR_RED}${LANG[NODE_NOT_CONNECTED]}${COLOR_RESET}\n" "$max_attempts"
                echo -e "${COLOR_YELLOW}${LANG[CHECK_CONFIG]}${COLOR_RESET}"
                exit 1
            fi
            sleep $delay
        fi
        ((attempt++))
    done

    echo
    echo -e "${COLOR_GREEN}Config profile: /opt/remnanode/config.txt${COLOR_RESET}"
    echo -e "${COLOR_WHITE}Panel → Config profiles → + → paste the file → save → assign to this node.${COLOR_RESET}"
    echo -e "${COLOR_GREEN}Host settings:  /opt/remnanode/hosts.txt${COLOR_RESET}"
    echo
    cat /opt/remnanode/config.txt
}
