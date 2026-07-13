#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  modules/xray_upstream.sh — Xray Upstream Tunnel
#  Маршрутизация исходящего трафика telemt к DC Telegram через Xray
#  telemt → SOCKS5 127.0.0.1:1080 → Xray → внешний сервер → TG DC
# ═══════════════════════════════════════════════════════════════════

XRAY_BIN="/usr/local/bin/xray"
XRAY_CONFIG_DIR="/etc/xray"
XRAY_CONFIG="${XRAY_CONFIG_DIR}/config.json"
XRAY_LOG_DIR="/var/log/xray"
XRAY_SERVICE="xray"
XRAY_SERVICE_FILE="/etc/systemd/system/${XRAY_SERVICE}.service"
XRAY_SOCKS_PORT="40000"
XRAY_LINK=""

# Подсети Telegram DC
TG_IPV4_CIDRS=(
    "91.108.56.0/22"  "91.108.4.0/22"   "91.108.8.0/22"
    "91.108.16.0/22"  "91.108.12.0/22"  "149.154.160.0/20"
    "91.105.192.0/23" "91.108.20.0/22"  "185.76.151.0/24"
)
TG_IPV6_CIDRS=(
    "2001:b28:f23d::/48" "2001:b28:f23f::/48" "2001:67c:4e8::/48"
    "2001:b28:f23c::/48" "2a0a:f280::/32"
)

# ══════════════════════════════════════════════════════════════════
#  Парсинг ссылок
# ══════════════════════════════════════════════════════════════════
_xray_parse_vless() {
    local link="$1"
    local body="${link#vless://}"
    local remark=""
    [[ "$body" == *"#"* ]] && { remark="${body##*#}"; body="${body%%#*}"; }
    remark=$(python3 -c "import urllib.parse; print(urllib.parse.unquote('$remark'))" 2>/dev/null || echo "$remark")

    local uuid="${body%%@*}"
    local rest="${body#*@}"
    local hostport="${rest%%\?*}"
    local params=""
    [[ "$rest" == *"?"* ]] && params="${rest#*\?}"

    local host="${hostport%%:*}"
    local port="${hostport##*:}"

    # Параметры
    local security="none" sni="" fp="" pbk="" sid="" flow="" type="tcp" path="" serviceName=""
    while IFS='=' read -r k v; do
        case "$k" in
            security) security="$v" ;; sni) sni="$v" ;; fp) fp="$v" ;;
            pbk) pbk="$v" ;; sid) sid="$v" ;; flow) flow="$v" ;;
            type) type="$v" ;; path) path="$v" ;; serviceName) serviceName="$v" ;;
        esac
    done < <(echo "$params" | tr '&' '\n')

    [[ -z "$sni" ]] && sni="$host"

    # Построить outbound JSON
    local stream_json flow_json="" reality_json="" tls_json=""

    [[ -n "$flow" ]] && flow_json=", \"flow\": \"$flow\""

    if [[ "$security" == "reality" ]]; then
        reality_json=$(cat << RJSON
"security": "reality",
            "realitySettings": {
                "serverName": "${sni}",
                "fingerprint": "${fp:-chrome}",
                "publicKey": "${pbk}",
                "shortId": "${sid}"
            }
RJSON
)
    elif [[ "$security" == "tls" ]]; then
        reality_json=$(cat << TJSON
"security": "tls",
            "tlsSettings": {
                "serverName": "${sni}",
                "fingerprint": "${fp:-chrome}"
            }
TJSON
)
    else
        reality_json='"security": "none"'
    fi

    local network_json
    case "$type" in
        grpc)
            network_json="\"network\": \"grpc\", \"grpcSettings\": { \"serviceName\": \"${serviceName}\" }"
            ;;
        ws)
            network_json="\"network\": \"ws\", \"wsSettings\": { \"path\": \"${path:-/}\" }"
            ;;
        *)
            network_json="\"network\": \"${type}\""
            ;;
    esac

    cat << OUTJSON
{
    "tag": "proxy",
    "protocol": "vless",
    "settings": {
        "vnext": [{
            "address": "${host}",
            "port": ${port},
            "users": [{
                "id": "${uuid}",
                "encryption": "none"${flow_json}
            }]
        }]
    },
    "streamSettings": {
        ${network_json},
        ${reality_json}
    }
}
OUTJSON
}

_xray_parse_vmess() {
    local link="$1"
    local b64="${link#vmess://}"
    local json
    json=$(echo "$b64" | base64 -d 2>/dev/null) || { msg_err "Невалидный vmess base64"; return 1; }

    local host port uuid aid net path tls sni
    host=$(echo "$json" | jq -r '.add // .host // ""')
    port=$(echo "$json" | jq -r '.port // 443')
    uuid=$(echo "$json" | jq -r '.id // ""')
    aid=$(echo "$json" | jq -r '.aid // 0')
    net=$(echo "$json" | jq -r '.net // "tcp"')
    path=$(echo "$json" | jq -r '.path // ""')
    tls=$(echo "$json" | jq -r '.tls // ""')
    sni=$(echo "$json" | jq -r '.sni // .host // ""')
    [[ -z "$sni" ]] && sni="$host"

    local tls_json='"security": "none"'
    [[ "$tls" == "tls" ]] && tls_json="\"security\": \"tls\", \"tlsSettings\": { \"serverName\": \"${sni}\" }"

    local net_json="\"network\": \"${net}\""
    [[ "$net" == "ws" ]] && net_json="\"network\": \"ws\", \"wsSettings\": { \"path\": \"${path:-/}\" }"

    cat << OUTJSON
{
    "tag": "proxy",
    "protocol": "vmess",
    "settings": {
        "vnext": [{
            "address": "${host}",
            "port": ${port},
            "users": [{
                "id": "${uuid}",
                "alterId": ${aid},
                "security": "auto"
            }]
        }]
    },
    "streamSettings": {
        ${net_json},
        ${tls_json}
    }
}
OUTJSON
}

_xray_parse_ss() {
    local link="$1"
    local body="${link#ss://}"
    [[ "$body" == *"#"* ]] && body="${body%%#*}"

    local userinfo_host method password host port
    if [[ "$body" == *"@"* ]]; then
        local encoded="${body%%@*}"
        local decoded
        decoded=$(echo "$encoded" | base64 -d 2>/dev/null) || decoded="$encoded"
        method="${decoded%%:*}"
        password="${decoded#*:}"
        local hp="${body#*@}"
        host="${hp%%:*}"
        port="${hp##*:}"
    else
        local decoded
        decoded=$(echo "$body" | base64 -d 2>/dev/null) || { msg_err "Невалидный ss://"; return 1; }
        method="${decoded%%:*}"
        local rest="${decoded#*:}"
        password="${rest%%@*}"
        local hp="${rest#*@}"
        host="${hp%%:*}"
        port="${hp##*:}"
    fi

    cat << OUTJSON
{
    "tag": "proxy",
    "protocol": "shadowsocks",
    "settings": {
        "servers": [{
            "address": "${host}",
            "port": ${port},
            "method": "${method}",
            "password": "${password}"
        }]
    }
}
OUTJSON
}

# ══════════════════════════════════════════════════════════════════
#  Установка Xray binary
# ══════════════════════════════════════════════════════════════════
_xray_install_binary() {
    msg_step "Установка Xray"

    # Зависимость: unzip (может отсутствовать на некоторых VPS)
    if ! command -v unzip &>/dev/null; then
        run_with_spinner "Установка unzip" apt-get install -y -qq unzip || {
            msg_err "Не удалось установить unzip"; return 1
        }
    fi

    if [[ -f "$XRAY_BIN" ]]; then
        local ver; ver=$("$XRAY_BIN" version 2>/dev/null | head -1 | awk '{print $2}')
        msg_ok "Xray уже установлен (${ver})"
        return 0
    fi

    local arch
    case "$(uname -m)" in
        x86_64)  arch="64" ;;
        aarch64) arch="arm64-v8a" ;;
        *) msg_err "Неподдерживаемая архитектура"; return 1 ;;
    esac

    local release_url="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
    local download_url
    download_url=$(curl -fsSL "$release_url" 2>/dev/null | jq -r \
        ".assets[] | select(.name | test(\"Xray-linux-${arch}.zip\")) | .browser_download_url" \
        2>/dev/null | head -1)

    if [[ -z "$download_url" || "$download_url" == "null" ]]; then
        msg_err "Не найден Xray для архитектуры ${arch}"
        return 1
    fi

    local tmp_dir; tmp_dir=$(mktemp -d)
    run_with_spinner "Скачивание Xray" curl -fSL --max-time 120 -o "${tmp_dir}/xray.zip" "$download_url" || {
        rm -rf "$tmp_dir"; return 1
    }

    unzip -o "${tmp_dir}/xray.zip" -d "${tmp_dir}/xray" >> "$LOG_FILE" 2>&1 || {
        msg_err "Ошибка распаковки"; rm -rf "$tmp_dir"; return 1
    }

    install -m 0755 "${tmp_dir}/xray/xray" "$XRAY_BIN"
    rm -rf "$tmp_dir"
    rollback_push "rm -f '${XRAY_BIN}'"

    local ver; ver=$("$XRAY_BIN" version 2>/dev/null | head -1 | awk '{print $2}')
    msg_ok "Xray ${ver} установлен"
}

# ══════════════════════════════════════════════════════════════════
#  Генерация config.json (SOCKS5 inbound + routing TG subnets)
# ══════════════════════════════════════════════════════════════════
_xray_generate_config() {
    local outbound_json="$1"
    msg_step "Генерация конфигурации Xray"

    mkdir -p "$XRAY_CONFIG_DIR" "$XRAY_LOG_DIR"

    # Собрать массив IP для routing
    local ipv4_list ipv6_list
    ipv4_list=$(printf '"%s",' "${TG_IPV4_CIDRS[@]}" | sed 's/,$//')
    ipv6_list=$(printf '"%s",' "${TG_IPV6_CIDRS[@]}" | sed 's/,$//')

    cat > "$XRAY_CONFIG" << CFGJSON
{
    "log": {
        "loglevel": "warning",
        "access": "${XRAY_LOG_DIR}/access.log",
        "error": "${XRAY_LOG_DIR}/error.log"
    },
    "inbounds": [{
        "tag": "socks-in",
        "port": ${XRAY_SOCKS_PORT},
        "listen": "127.0.0.1",
        "protocol": "socks",
        "settings": { "udp": true }
    }],
    "outbounds": [
        ${outbound_json},
        {
            "tag": "direct",
            "protocol": "freedom"
        }
    ],
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": [
            {
                "type": "field",
                "ip": [${ipv4_list}, ${ipv6_list}],
                "outboundTag": "proxy"
            },
            {
                "type": "field",
                "domain": ["domain:telegram.org", "domain:t.me", "domain:core.telegram.org"],
                "outboundTag": "proxy"
            },
            {
                "type": "field",
                "network": "tcp,udp",
                "outboundTag": "direct"
            }
        ]
    }
}
CFGJSON

    # Валидация
    if ! jq -e . "$XRAY_CONFIG" &>/dev/null; then
        msg_err "Невалидный JSON — проверьте конфиг"
        return 1
    fi

    rollback_push "rm -rf '${XRAY_CONFIG_DIR}'"
    msg_ok "Конфиг: SOCKS5 :${XRAY_SOCKS_PORT} → ${#TG_IPV4_CIDRS[@]} IPv4 + ${#TG_IPV6_CIDRS[@]} IPv6 подсетей TG"
}

# ══════════════════════════════════════════════════════════════════
#  Systemd сервис
# ══════════════════════════════════════════════════════════════════
_xray_create_service() {
    msg_step "Создание сервиса Xray"

    cat > "$XRAY_SERVICE_FILE" << SVCEOF
[Unit]
Description=Xray Upstream Tunnel for Telemt
After=network-online.target
Wants=network-online.target
Before=telemt.service

[Service]
Type=simple
ExecStart=${XRAY_BIN} run -config ${XRAY_CONFIG}
Restart=on-failure
RestartSec=3
LimitNOFILE=65536
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    systemctl enable "$XRAY_SERVICE" >> "$LOG_FILE" 2>&1
    rollback_push "systemctl stop ${XRAY_SERVICE} 2>/dev/null; systemctl disable ${XRAY_SERVICE} 2>/dev/null; rm -f '${XRAY_SERVICE_FILE}'; systemctl daemon-reload"

    systemctl start "$XRAY_SERVICE" >> "$LOG_FILE" 2>&1
    sleep 2

    if systemctl is-active --quiet "$XRAY_SERVICE"; then
        msg_ok "Xray запущен (SOCKS5 127.0.0.1:${XRAY_SOCKS_PORT})"
    else
        msg_err "Не удалось запустить Xray"
        msg_info "journalctl -u ${XRAY_SERVICE} -n 20 --no-pager"
        return 1
    fi
}

# ══════════════════════════════════════════════════════════════════
#  Тест туннеля
# ══════════════════════════════════════════════════════════════════
_xray_test_tunnel() {
    msg_step "Тест туннеля"

    local http_code
    http_code=$(curl -x socks5h://127.0.0.1:${XRAY_SOCKS_PORT} \
        -so /dev/null -w "%{http_code}" \
        --max-time 10 "https://api.telegram.org/" 2>/dev/null) || true

    if [[ "$http_code" =~ ^(200|301|302|403) ]]; then
        msg_ok "Туннель работает — api.telegram.org доступен (HTTP ${http_code})"
    else
        msg_warn "Тест не прошёл (HTTP ${http_code:-timeout}) — проверьте ключ подключения"
    fi
}

# ══════════════════════════════════════════════════════════════════
#  Привязка telemt → Xray SOCKS5
# ══════════════════════════════════════════════════════════════════
_xray_bind_telemt() {
    msg_step "Привязка telemt → Xray"

    # ВАЖНО: у telemt (см. docs/Config_params/CONFIG_PARAMS) НЕТ ключа
    # "socks5_proxy" — это не поддерживаемый параметр и telemt его просто
    # игнорирует, продолжая идти к DC Telegram напрямую в Middle Proxy
    # Mode. Правильный способ — таблица [[upstreams]] с type="socks5",
    # и это работает ТОЛЬКО при use_middle_proxy = false.

    local cfg=""
    for f in /etc/telemt/telemt.toml /etc/telemt/config.toml; do
        [[ -f "$f" ]] && cfg="$f" && break
    done

    if [[ -z "$cfg" ]]; then
        msg_warn "Конфиг telemt не найден"
        msg_info "Добавьте вручную:"
        echo "  use_middle_proxy = false"
        echo ""
        echo "  [[upstreams]]"
        echo "  type = \"socks5\""
        echo "  address = \"127.0.0.1:${XRAY_SOCKS_PORT}\""
        echo "  weight = 1"
        echo "  enabled = true"
        return 0
    fi

    mkdir -p /opt/telemt/backups
    local backup_file="/opt/telemt/backups/$(basename "$cfg").pre-xray.$(date +%s)"
    cp "$cfg" "$backup_file"
    rollback_push "cp '${backup_file}' '${cfg}' 2>/dev/null; systemctl restart telemt 2>/dev/null || true"

    # Обратная совместимость: убрать неподдерживаемый ключ от старых версий скрипта
    if grep -qE '^socks5_proxy[[:space:]]*=' "$cfg" 2>/dev/null; then
        sed -i '/^socks5_proxy[[:space:]]*=/d' "$cfg"
        msg_warn "Удалён неподдерживаемый ключ socks5_proxy (устаревший формат — telemt его не читает)"
    fi

    # Идемпотентность: если блок от установщика уже есть — снести перед повторной записью
    if grep -q '# >>> Xray upstream (installer)' "$cfg" 2>/dev/null; then
        sed -i '/# >>> Xray upstream (installer)/,/# <<< Xray upstream (installer)/d' "$cfg"
    fi

    # use_middle_proxy обязателен false — иначе telemt игнорирует upstreams
    # и продолжает ходить в DC напрямую (Middle Proxy Mode)
    if grep -qE '^use_middle_proxy[[:space:]]*=' "$cfg" 2>/dev/null; then
        sed -i 's/^use_middle_proxy[[:space:]]*=.*/use_middle_proxy = false/' "$cfg"
    elif grep -q '\[general\]' "$cfg" 2>/dev/null; then
        sed -i '/\[general\]/a use_middle_proxy = false' "$cfg"
    else
        echo -e "\n[general]\nuse_middle_proxy = false" >> "$cfg"
    fi
    msg_warn "use_middle_proxy = false (обязательно для работы upstream socks5)"

    cat >> "$cfg" << UPSEOF

# >>> Xray upstream (installer)
[[upstreams]]
type = "socks5"
address = "127.0.0.1:${XRAY_SOCKS_PORT}"
weight = 1
enabled = true
# <<< Xray upstream (installer)
UPSEOF

    msg_ok "telemt → [[upstreams]] socks5 127.0.0.1:${XRAY_SOCKS_PORT}"

    # Перезапуск telemt с проверкой, что он реально не упал в reject-loop
    if systemctl is-active --quiet telemt 2>/dev/null; then
        systemctl restart telemt >> "$LOG_FILE" 2>&1
        sleep 3
        if systemctl is-active --quiet telemt; then
            msg_ok "telemt перезапущен"
        else
            msg_err "telemt не стартовал после изменения конфига — откат к предыдущему конфигу"
            cp "$backup_file" "$cfg"
            systemctl restart telemt >> "$LOG_FILE" 2>&1
            return 1
        fi
    fi
}

# ══════════════════════════════════════════════════════════════════
#  Удаление (для cleaner)
# ══════════════════════════════════════════════════════════════════
xray_upstream_remove() {
    msg_step "Удаление Xray Upstream"

    systemctl stop "$XRAY_SERVICE" 2>/dev/null || true
    systemctl disable "$XRAY_SERVICE" 2>/dev/null || true
    rm -f "$XRAY_SERVICE_FILE"
    systemctl daemon-reload

    rm -f "$XRAY_BIN"
    rm -rf "$XRAY_CONFIG_DIR" "$XRAY_LOG_DIR"

    # Убрать блок [[upstreams]] и вернуть use_middle_proxy = true в конфиге telemt
    for f in /etc/telemt/telemt.toml /etc/telemt/config.toml; do
        [[ -f "$f" ]] || continue
        local changed=false

        if grep -q '# >>> Xray upstream (installer)' "$f" 2>/dev/null; then
            mkdir -p /opt/telemt/backups
            cp "$f" "/opt/telemt/backups/$(basename "$f").pre-xray-remove.$(date +%s)"
            sed -i '/# >>> Xray upstream (installer)/,/# <<< Xray upstream (installer)/d' "$f"
            changed=true
        fi

        # Обратная совместимость: подчистить устаревший неверный ключ, если остался от старых версий
        if grep -qE '^socks5_proxy[[:space:]]*=' "$f" 2>/dev/null; then
            sed -i '/^socks5_proxy[[:space:]]*=/d' "$f"
            changed=true
        fi

        if grep -qE '^use_middle_proxy[[:space:]]*=[[:space:]]*false' "$f" 2>/dev/null; then
            sed -i 's/^use_middle_proxy[[:space:]]*=.*/use_middle_proxy = true/' "$f"
            changed=true
        fi

        if [[ "$changed" == "true" ]]; then
            msg_ok "Конфиг $(basename "$f") очищен от Xray upstream (use_middle_proxy восстановлен → true)"
            systemctl is-active --quiet telemt 2>/dev/null && systemctl restart telemt >> "$LOG_FILE" 2>&1
        fi
    done

    msg_ok "Xray Upstream удалён"
}

# ══════════════════════════════════════════════════════════════════
#  Главная точка входа
# ══════════════════════════════════════════════════════════════════
xray_upstream_setup() {
    msg_header "Xray Upstream Tunnel"

    msg_info "Исходящий трафик telemt к Telegram DC пойдёт через внешний туннель"
    msg_info "telemt → SOCKS5 (127.0.0.1:${XRAY_SOCKS_PORT}) → Xray → DC Telegram"
    echo ""

    # Запрос ссылки
    prompt_input "Ключ подключения (vless://, vmess://, ss://)" XRAY_LINK '^(vless|vmess|ss)://'

    # Парсинг
    local proto="${XRAY_LINK%%://*}"
    local outbound_json=""

    msg_info "Протокол: ${proto}"

    case "$proto" in
        vless) outbound_json=$(_xray_parse_vless "$XRAY_LINK") || return 1 ;;
        vmess) outbound_json=$(_xray_parse_vmess "$XRAY_LINK") || return 1 ;;
        ss)    outbound_json=$(_xray_parse_ss "$XRAY_LINK")    || return 1 ;;
        *)     msg_err "Неподдерживаемый протокол: ${proto}"; return 1 ;;
    esac

    if ! echo "$outbound_json" | jq -e . &>/dev/null; then
        msg_err "Ошибка парсинга ссылки"
        return 1
    fi
    msg_ok "Ссылка распознана"

    draw_info_box 62 \
        "${C_BOLD}Xray Upstream Tunnel${C_RESET}" \
        "" \
        "Протокол:  ${C_WHITE}${proto}${C_RESET}" \
        "Inbound:   ${C_WHITE}SOCKS5 127.0.0.1:${XRAY_SOCKS_PORT}${C_RESET}" \
        "Routing:   ${C_WHITE}${#TG_IPV4_CIDRS[@]} IPv4 + ${#TG_IPV6_CIDRS[@]} IPv6 подсетей TG${C_RESET}" \
        "Привязка:  ${C_WHITE}telemt → [[upstreams]] (socks5)${C_RESET}"

    # Молчаливая установка
    _xray_install_binary         || return 1
    _xray_generate_config "$outbound_json" || return 1
    _xray_create_service         || return 1
    _xray_test_tunnel            || true
    _xray_bind_telemt            || return 1

    echo ""
    msg_ok "Xray Upstream Tunnel настроен"
    msg_info "telemt маршрутизирует трафик к TG через Xray-туннель"
}
