#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  modules/web_proxy.sh — WEB proxy: отдельный вариант установки
#  telemt >= 3.5.1, режим transport="web" (MTProto внутри HTTPS)
#
#  ВАЖНО — архитектурное ограничение (сознательное):
#  В WEB-режиме TLS на публичном :443 терминирует nginx, а не telemt
#  (в отличие от Базовой установки и Selfmask, где :443 напрямую
#  занимает telemt). Это несовместимо с уже занятым :443 — поэтому
#  модуль ТРЕБУЕТ свободный порт 443 и ОТКАЗЫВАЕТСЯ работать, если
#  telemt (Базовый или Selfmask) уже на нём висит. Существующие
#  сценарии 1/2 этот модуль не трогает и не меняет.
#
#  Источник схемы конфига: Telemt docs/WEB/WEB_PROXY.*.md (transport
#  "web", [web], [[web.vhosts]], [web.vhosts.decoy], [[web.vhosts.profiles]])
# ═══════════════════════════════════════════════════════════════════

WEBPROXY_DOMAIN=""
WEBPROXY_SECRET=""
WEBPROXY_USER="web-user"
WEBPROXY_LISTEN_PORT="18080"
WEBPROXY_DECOY_DIR="/opt/telemt-web/public"
WEBPROXY_DECOY_SOURCE=""
WEBPROXY_NGINX_CONF="/etc/nginx/sites-available/telemt-web"
WEBPROXY_CONFIG="/etc/telemt/telemt.toml"
WEBPROXY_LINK_FILE="/opt/telemt/web_proxy_link.txt"
WEBPROXY_MIN_VERSION="3.5.1"

# ══════════════════════════════════════════════════════════════════
#  Проверка предпосылок: версия telemt, занятость порта 443
# ══════════════════════════════════════════════════════════════════
_webproxy_ver_ge() {
    # true, если $1 >= $2 (сравнение через sort -V)
    [[ "$1" == "$2" ]] && return 0
    [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" == "$2" ]]
}

webproxy_check_prereqs() {
    msg_step "Проверка предпосылок для WEB proxy"

    # ── Версия telemt (если уже установлен) ────────────────────────
    if [[ -f /bin/telemt ]]; then
        local ver
        ver=$(/bin/telemt --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        if [[ -z "$ver" ]]; then
            msg_warn "Не удалось определить версию установленного telemt — продолжаем на свой риск"
        elif ! _webproxy_ver_ge "$ver" "$WEBPROXY_MIN_VERSION"; then
            msg_err "Установлена telemt ${ver}, WEB proxy требует >= ${WEBPROXY_MIN_VERSION}"
            msg_info "Обновите telemt (mytelemtinfo → пункт обновления) и повторите"
            return 1
        else
            msg_ok "Версия telemt: ${ver} (достаточно для WEB)"
        fi
    fi

    # ── Порт 443 должен быть свободен ───────────────────────────────
    # WEB proxy отдаёт TLS-терминацию на :443 nginx-у. Если telemt уже
    # установлен Базовым или Selfmask-сценарием, он сам слушает :443 —
    # это несовместимо, и мы НЕ лезем переделывать существующую установку.
    if ss -tlnp 2>/dev/null | grep -q ':443[[:space:]]'; then
        local holder
        holder=$(ss -tlnp 2>/dev/null | grep ':443[[:space:]]' | grep -oE 'users:\(\("[^"]+"' | head -1 | tr -d '"(' )
        msg_err "Порт 443 уже занят${holder:+ (похоже, процессом: ${holder#users:})}"
        echo ""
        msg_info "WEB proxy требует, чтобы 443 терминировал nginx — а не telemt напрямую."
        msg_info "Если это существующая установка telemt (Базовая или Selfmask) — модуль"
        msg_info "её не трогает. Варианты:"
        echo -e "    ${C_YELLOW}•${C_RESET} разверните WEB proxy на отдельном сервере/IP"
        echo -e "    ${C_YELLOW}•${C_RESET} либо сначала полностью удалите текущую установку telemt"
        echo -e "      (пункт «Полная или пошаговая очистка» в главном меню)"
        return 1
    fi

    msg_ok "Порт 443 свободен — можно продолжать"

    # ── Существующий конфиг Базовой/Selfmask установки ──────────────
    # WEB-режим пишет СВОЙ конфиг целиком. Если на диске лежит конфиг
    # другого режима (telemt сейчас просто остановлен) — не затираем его
    # молча: только с явного согласия и с бэкапом.
    if [[ -f "$WEBPROXY_CONFIG" ]] && ! grep -q 'web_proxy.sh' "$WEBPROXY_CONFIG" 2>/dev/null; then
        msg_warn "Найден существующий конфиг telemt (${WEBPROXY_CONFIG}) от другого режима"
        msg_info "WEB-режим заменит его своим; копия сохранится в /opt/telemt/backups"
        confirm_yn "Заменить существующий конфиг конфигом WEB proxy?" "n" || {
            msg_info "Отменено — существующая установка не тронута"
            return 1
        }
    fi
}

# ══════════════════════════════════════════════════════════════════
#  Шаг 1: Параметры (домен, decoy-сайт)
# ══════════════════════════════════════════════════════════════════
webproxy_collect_params() {
    msg_header "Параметры WEB proxy"

    msg_info "WEB proxy маскирует MTProto под обычный HTTPS-сайт на вашем"
    msg_info "домене. В отличие от Selfmask, TLS терминирует nginx, а не telemt —"
    msg_info "нужен отдельный домен с A-записью на этот сервер и порт 443."
    msg_warn "Ссылка (tg://webproxy) сейчас открывается ТОЛЬКО в Telegram Desktop"
    msg_warn "(Windows/macOS/Linux). На телефонах WEB-ссылки пока не работают —"
    msg_warn "держите классическую ee-ссылку (Базовая/Selfmask установка) как основную."
    echo ""

    prompt_input "Домен для WEB proxy (A-запись → этот сервер)" WEBPROXY_DOMAIN '^[a-zA-Z0-9._-]+\.[a-zA-Z]{2,}$'

    # ── Проверка DNS (тот же стиль, что в site_mask.sh) ─────────────
    local server_ip="" resolved_ip=""
    server_ip=$(_get_public_ipv4)
    msg_info "IP сервера: ${server_ip}"

    if ! command -v dig &>/dev/null; then
        apt-get install -y -qq dnsutils >> "$LOG_FILE" 2>&1 || true
    fi
    if command -v dig &>/dev/null; then
        resolved_ip=$(dig +short "$WEBPROXY_DOMAIN" A 2>/dev/null | tail -1)
    elif command -v host &>/dev/null; then
        resolved_ip=$(host "$WEBPROXY_DOMAIN" 2>/dev/null | awk '/has address/{print $4; exit}')
    fi

    if [[ -n "$resolved_ip" && "$resolved_ip" == "$server_ip" ]]; then
        msg_ok "DNS подтверждён: ${WEBPROXY_DOMAIN} → ${resolved_ip}"
    else
        msg_warn "DNS: ${WEBPROXY_DOMAIN} → ${resolved_ip:-(не резолвится)} (ожидался ${server_ip})"
        msg_warn "Let's Encrypt НЕ СМОЖЕТ выдать сертификат, если DNS не совпадает"
        confirm_yn "Продолжить несмотря на это?" "n" || return 1
    fi

    # ── Decoy-сайт ───────────────────────────────────────────────────
    echo ""
    msg_step "Decoy-сайт (что видят браузеры и сканеры на этом домене)"

    if [[ -d /var/www/html ]] && [[ -n "$(ls -A /var/www/html 2>/dev/null)" ]]; then
        msg_info "Обнаружено содержимое в /var/www/html"
        if confirm_yn "Использовать его как decoy-сайт для WEB proxy?" "y"; then
            WEBPROXY_DECOY_SOURCE="reuse:/var/www/html"
        fi
    fi

    if [[ -z "$WEBPROXY_DECOY_SOURCE" ]]; then
        echo -e "    ${C_GREEN}[1]${C_RESET} ${C_BOLD}Market-Terminal-Template${C_RESET} (vaalaav)"
        echo -e "    ${C_GREEN}[2]${C_RESET} ${C_BOLD}kotorunner${C_RESET} (vaalaav)"
        echo -e "    ${C_CYAN}[3]${C_RESET} ${C_BOLD}Указать свой git-репозиторий${C_RESET}"
        echo -e "    ${C_DIM}[4]${C_RESET} ${C_BOLD}Простая HTML-заглушка${C_RESET}"
        echo -ne "  ${C_BOLD}Выбор${C_RESET} [1-4]: "
        local choice; read -r choice
        case "$choice" in
            1) WEBPROXY_DECOY_SOURCE="https://github.com/vaalaav/Market-Terminal-Template.git" ;;
            2) WEBPROXY_DECOY_SOURCE="https://github.com/vaalaav/kotorunner.git" ;;
            3) prompt_input "URL git-репозитория" WEBPROXY_DECOY_SOURCE '^https?://' ;;
            4|*) WEBPROXY_DECOY_SOURCE="stub" ;;
        esac
    fi

    echo ""
    draw_info_box 62 \
        "${C_BOLD}Параметры WEB proxy:${C_RESET}" \
        "" \
        "Домен:      ${C_WHITE}${WEBPROXY_DOMAIN}${C_RESET}" \
        "Внутр.порт: ${C_WHITE}127.0.0.1:${WEBPROXY_LISTEN_PORT}${C_RESET} (nginx → telemt)" \
        "Decoy:      ${C_WHITE}${WEBPROXY_DECOY_SOURCE}${C_RESET}" \
        "Carrier:    ${C_WHITE}https${C_RESET} (совместимо со всеми платформами, вкл. iOS)" \
        "" \
        "${C_DIM}nginx :443 (TLS) → telemt :${WEBPROXY_LISTEN_PORT} (web) → Telegram${C_RESET}"

    confirm_yn "Начать установку WEB proxy?" "y" || return 1
}

# ══════════════════════════════════════════════════════════════════
#  Шаг 2: Зависимости
# ══════════════════════════════════════════════════════════════════
webproxy_install_deps() {
    msg_step "Установка зависимостей"

    local pkgs_needed=()
    command -v nginx   &>/dev/null || pkgs_needed+=(nginx)
    command -v certbot &>/dev/null || pkgs_needed+=(certbot python3-certbot-nginx)
    command -v git     &>/dev/null || pkgs_needed+=(git)
    command -v rsync   &>/dev/null || pkgs_needed+=(rsync)

    if command -v certbot &>/dev/null && ! dpkg -s python3-certbot-nginx &>/dev/null 2>&1; then
        pkgs_needed+=(python3-certbot-nginx)
    fi

    if [[ ${#pkgs_needed[@]} -gt 0 ]]; then
        msg_info "Устанавливаем: ${pkgs_needed[*]}"
        run_with_spinner "apt update" apt-get update -qq || true
        run_with_spinner "apt install ${pkgs_needed[*]}" \
            apt-get install -y -qq "${pkgs_needed[@]}" || {
            msg_err "Не удалось установить пакеты: ${pkgs_needed[*]}"
            return 1
        }
    fi

    systemctl enable nginx >> "$LOG_FILE" 2>&1 || true
    systemctl start nginx  >> "$LOG_FILE" 2>&1 || true
    msg_ok "Зависимости готовы: nginx, certbot, python3-certbot-nginx, git, rsync"
}

# ══════════════════════════════════════════════════════════════════
#  Шаг 3: Decoy-сайт
# ══════════════════════════════════════════════════════════════════
webproxy_deploy_decoy() {
    msg_step "Развёртывание decoy-сайта"

    if [[ "$WEBPROXY_DECOY_SOURCE" == "reuse:"* ]]; then
        WEBPROXY_DECOY_DIR="${WEBPROXY_DECOY_SOURCE#reuse:}"
        msg_ok "Используем существующий сайт: ${WEBPROXY_DECOY_DIR}"
        return 0
    fi

    mkdir -p "$WEBPROXY_DECOY_DIR"

    if [[ "$WEBPROXY_DECOY_SOURCE" == "stub" ]]; then
        cat > "${WEBPROXY_DECOY_DIR}/index.html" << 'STUBHTML'
<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Welcome</title>
<style>
  body { font-family: system-ui, -apple-system, sans-serif; max-width: 640px;
         margin: 80px auto; padding: 0 20px; color: #333; background: #fafafa; }
  h1 { font-size: 1.5rem; color: #111; }
  p  { color: #666; line-height: 1.6; }
</style></head>
<body><h1>Welcome</h1><p>This site is currently under construction. Please check back later.</p></body></html>
STUBHTML
        msg_ok "HTML-заглушка создана в ${WEBPROXY_DECOY_DIR}"
    else
        local tmp_dir; tmp_dir=$(mktemp -d)
        msg_info "Клонирование: ${WEBPROXY_DECOY_SOURCE}"
        if run_with_spinner "git clone шаблона" git clone --depth 1 "$WEBPROXY_DECOY_SOURCE" "${tmp_dir}/repo"; then
            if command -v rsync &>/dev/null; then
                rsync -a --exclude='.git' "${tmp_dir}/repo/" "${WEBPROXY_DECOY_DIR}/"
            else
                find "${tmp_dir}/repo" -mindepth 1 -maxdepth 1 ! -name '.git' -exec cp -a {} "${WEBPROXY_DECOY_DIR}/" \;
            fi
            rm -rf "$tmp_dir"
            msg_ok "Шаблон развёрнут в ${WEBPROXY_DECOY_DIR}"
        else
            rm -rf "$tmp_dir"
            msg_warn "Не удалось склонировать — создаём HTML-заглушку"
            WEBPROXY_DECOY_SOURCE="stub"
            cat > "${WEBPROXY_DECOY_DIR}/index.html" << 'FALLBACKHTML'
<!doctype html><html lang="ru"><head><meta charset="utf-8"><title>Welcome</title></head>
<body><h1>Site is under construction</h1></body></html>
FALLBACKHTML
        fi
    fi

    # telemt сам читает эту директорию для decoy — владелец telemt,
    # не www-data (в отличие от Selfmask, тут сайт отдаёт не nginx, а telemt)
    chown -R telemt:telemt "$WEBPROXY_DECOY_DIR" 2>/dev/null || true
    chmod -R 755 "$WEBPROXY_DECOY_DIR" 2>/dev/null || true

    rollback_push "rm -rf '${WEBPROXY_DECOY_DIR}' 2>/dev/null || true"
}

# ══════════════════════════════════════════════════════════════════
#  Шаг 4: Let's Encrypt сертификат (webroot, временный :80 от nginx)
# ══════════════════════════════════════════════════════════════════
webproxy_obtain_cert() {
    msg_step "Получение Let's Encrypt сертификата"

    local cert_dir="/etc/letsencrypt/live/${WEBPROXY_DOMAIN}"
    if [[ -f "${cert_dir}/fullchain.pem" ]]; then
        msg_ok "Сертификат для ${WEBPROXY_DOMAIN} уже существует"
        return 0
    fi

    local acme_root="/var/www/telemt-web-acme"
    mkdir -p "${acme_root}/.well-known/acme-challenge"

    cat > /etc/nginx/sites-available/telemt-web-acme-temp << ACMEEOF
server {
    listen 80;
    server_name ${WEBPROXY_DOMAIN};
    root ${acme_root};
    location /.well-known/acme-challenge/ { allow all; }
    location / { return 200 'ok'; add_header Content-Type text/plain; }
}
ACMEEOF
    ln -sf /etc/nginx/sites-available/telemt-web-acme-temp /etc/nginx/sites-enabled/telemt-web-acme-temp

    if ! nginx -t >> "$LOG_FILE" 2>&1; then
        msg_err "Ошибка временного конфига Nginx для ACME"
        rm -f /etc/nginx/sites-available/telemt-web-acme-temp /etc/nginx/sites-enabled/telemt-web-acme-temp
        return 1
    fi
    systemctl reload nginx >> "$LOG_FILE" 2>&1

    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow 80/tcp >> "$LOG_FILE" 2>&1 || true
    elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --add-port=80/tcp >> "$LOG_FILE" 2>&1 || true
    elif ! iptables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null; then
        iptables -I INPUT 1 -p tcp --dport 80 -j ACCEPT
    fi

    msg_info "Запрашиваем сертификат для ${WEBPROXY_DOMAIN}..."
    if run_with_spinner "certbot (webroot)" \
        certbot certonly --webroot -w "$acme_root" \
        -d "$WEBPROXY_DOMAIN" --non-interactive --agree-tos \
        -m "admin@${WEBPROXY_DOMAIN}" --cert-name "$WEBPROXY_DOMAIN"; then
        msg_ok "Сертификат получен: ${cert_dir}"
        rollback_push "certbot delete --cert-name '${WEBPROXY_DOMAIN}' --non-interactive 2>/dev/null || true"
    else
        msg_err "Не удалось получить сертификат"
        msg_info "Чеклист: DNS A-запись, порт 80/tcp открыт, нет другого процесса на :80"
        rm -f /etc/nginx/sites-available/telemt-web-acme-temp /etc/nginx/sites-enabled/telemt-web-acme-temp
        return 1
    fi

    rm -f /etc/nginx/sites-enabled/telemt-web-acme-temp
}

# ══════════════════════════════════════════════════════════════════
#  Шаг 5: Nginx — реверс-прокси на telemt WEB-листенер
#  (НЕ 3-блочная TLS-терминация Selfmask — тут nginx сам отдаёт сайт)
# ══════════════════════════════════════════════════════════════════
webproxy_configure_nginx() {
    msg_step "Настройка Nginx (реверс-прокси → telemt WEB)"

    local cert_dir="/etc/letsencrypt/live/${WEBPROXY_DOMAIN}"
    if [[ ! -f "${cert_dir}/fullchain.pem" ]]; then
        msg_err "Сертификат не найден в ${cert_dir}"
        return 1
    fi

    # Пишем через python3 (как в site_mask.sh) — чтобы $-переменные nginx
    # (upgrade/host/forwarded-for) не интерпретировались bash-ом
    python3 -c "
domain = '${WEBPROXY_DOMAIN}'
backend_port = '${WEBPROXY_LISTEN_PORT}'
cert = '/etc/letsencrypt/live/${WEBPROXY_DOMAIN}'

cfg = f'''# telemt WEB proxy nginx — сгенерировано telemt VPS Installer
# Домен: {domain}
# Схема: клиент → nginx :443 (TLS) → telemt :{backend_port} (transport=web)

map \$http_upgrade \$telemt_web_connection_upgrade {{
    default upgrade;
    ''      '';
}}

upstream telemt_web_backend {{
    server 127.0.0.1:{backend_port};
    keepalive 64;
}}

server {{
    listen 80;
    server_name {domain};
    location /.well-known/acme-challenge/ {{
        root /var/www/telemt-web-acme;
        allow all;
    }}
    location / {{
        return 301 https://{domain}\$request_uri;
    }}
}}

server {{
    listen 443 ssl;
    http2 on;
    server_name {domain};
    access_log off;

    ssl_certificate     {cert}/fullchain.pem;
    ssl_certificate_key {cert}/privkey.pem;

    client_max_body_size 2m;

    location / {{
        proxy_pass http://telemt_web_backend;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$telemt_web_connection_upgrade;

        proxy_connect_timeout 5s;
        proxy_send_timeout 65s;
        proxy_read_timeout 65s;
        proxy_request_buffering off;
        proxy_buffering off;
        proxy_next_upstream off;
    }}
}}
'''
with open('${WEBPROXY_NGINX_CONF}', 'w') as f:
    f.write(cfg)
print('OK')
" >> "$LOG_FILE" 2>&1

    if [[ ! -f "$WEBPROXY_NGINX_CONF" ]]; then
        msg_err "Не удалось создать конфиг Nginx"
        return 1
    fi

    ln -sf "$WEBPROXY_NGINX_CONF" /etc/nginx/sites-enabled/telemt-web
    rm -f /etc/nginx/sites-enabled/telemt-web-acme-temp 2>/dev/null || true

    if nginx -t >> "$LOG_FILE" 2>&1; then
        systemctl reload nginx >> "$LOG_FILE" 2>&1
        rollback_push "rm -f '${WEBPROXY_NGINX_CONF}' /etc/nginx/sites-enabled/telemt-web; systemctl reload nginx 2>/dev/null || true"
        msg_ok "Nginx настроен: :443 → telemt :${WEBPROXY_LISTEN_PORT}"
    else
        msg_err "Ошибка конфигурации Nginx — запуск: nginx -t"
        cat "$WEBPROXY_NGINX_CONF" >> "$LOG_FILE"
        rm -f "$WEBPROXY_NGINX_CONF" /etc/nginx/sites-enabled/telemt-web
        return 1
    fi

    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow 80/tcp >> "$LOG_FILE" 2>&1 || true
        ufw allow 443/tcp >> "$LOG_FILE" 2>&1 || true
        rollback_push "ufw delete allow 80/tcp 2>/dev/null; ufw delete allow 443/tcp 2>/dev/null"
        msg_ok "UFW: порты 80, 443 открыты"
    elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --add-port=80/tcp  >> "$LOG_FILE" 2>&1 || true
        firewall-cmd --permanent --add-port=443/tcp >> "$LOG_FILE" 2>&1 || true
        firewall-cmd --reload >> "$LOG_FILE" 2>&1 || true
        rollback_push "firewall-cmd --permanent --remove-port=80/tcp 2>/dev/null; firewall-cmd --permanent --remove-port=443/tcp 2>/dev/null; firewall-cmd --reload 2>/dev/null"
        msg_ok "firewalld: порты 80, 443 открыты"
    else
        for p in 80 443; do
            iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p tcp --dport "$p" -j ACCEPT
        done
        command -v netfilter-persistent &>/dev/null && netfilter-persistent save >> "$LOG_FILE" 2>&1
        rollback_push "iptables -D INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null; iptables -D INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null"
        msg_ok "iptables: порты 80, 443 открыты"
    fi

    # Внутренний порт telemt (18080) — только loopback, наружу не торчит,
    # поэтому отдельного файрвол-правила для него не требуется.
}

# ══════════════════════════════════════════════════════════════════
#  Шаг 6: Установка ядра telemt (если ещё не установлено) + конфиг
#  Переиспользуем ТОЛЬКО нейтральные функции telemt_core.sh — скачивание
#  бинарника, создание пользователя/группы, systemd-юнит. Генерацию
#  конфига делаем свою — classic/FakeTLS-конфиг telemt_core.sh тут не
#  подходит (другая модель: нет классического слушателя на 443).
# ══════════════════════════════════════════════════════════════════
webproxy_generate_config() {
    msg_step "Генерация конфигурации telemt (WEB-режим)"

    mkdir -p /etc/telemt

    if [[ -f "$WEBPROXY_CONFIG" ]]; then
        mkdir -p /opt/telemt/backups
        cp "$WEBPROXY_CONFIG" "/opt/telemt/backups/$(basename "$WEBPROXY_CONFIG").pre-webproxy.$(date +%s)"
        msg_info "Существующий конфиг сохранён в .pre-webproxy backup"
    fi

    local server_ip; server_ip=$(_get_public_ipv4)

    cat > "$WEBPROXY_CONFIG" << TOMLEOF
### telemt WEB proxy config — сгенерировано telemt VPS Installer (web_proxy.sh)
### $(date '+%Y-%m-%d %H:%M:%S')
### ВНИМАНИЕ: классического слушателя на :443 здесь нет сознательно —
### порт 443 отдан nginx под TLS-терминацию WEB-режима.

[general]
use_middle_proxy = false
log_level = "normal"

[general.modes]
classic = false
secure = true
tls = false

[general.links]
show = ["${WEBPROXY_USER}"]

[server]
port = ${WEBPROXY_LISTEN_PORT}

[server.api]
enabled = true
listen = "127.0.0.1:9091"

# WEB-листенер: plain HTTP только для локального nginx, наружу не торчит
[[server.listeners]]
ip = "127.0.0.1"
port = ${WEBPROXY_LISTEN_PORT}
transport = "web"
proxy_protocol = false
reuse_allow = false
web_client_ip_source = "x_forwarded_for"
web_trusted_proxy_cidrs = ["127.0.0.1/32"]

[web]
enabled = true
carrier = "https"

[[web.vhosts]]
host = "${WEBPROXY_DOMAIN}"
public_addr = "${server_ip}:443"

[web.vhosts.decoy]
mode = "static_directory"
directory = "${WEBPROXY_DECOY_DIR}"
index = "index.html"

[[web.vhosts.profiles]]
user = "${WEBPROXY_USER}"
secret_mode = "dd"
max_sessions = 16
max_streams = 512
max_streams_per_session = 64

[access.users]
${WEBPROXY_USER} = "${WEBPROXY_SECRET}"
TOMLEOF

    chown telemt:telemt "$WEBPROXY_CONFIG" 2>/dev/null || true
    chmod 640 "$WEBPROXY_CONFIG" 2>/dev/null || true

    rollback_push "rm -f '${WEBPROXY_CONFIG}'"
    msg_ok "Конфиг записан: ${WEBPROXY_CONFIG}"
}

webproxy_install_telemt() {
    msg_step "Установка ядра telemt"

    WEBPROXY_SECRET=$(_generate_secret) || return 1

    if [[ -f /bin/telemt ]]; then
        msg_ok "Бинарник telemt уже установлен — пропускаем скачивание"
    else
        telemt_download || return 1
    fi

    telemt_setup_env || return 1

    # Пользователь telemt создан только сейчас — отдаём ему decoy-директорию
    # (только свою, не чужой /var/www/html из режима reuse)
    if [[ "$WEBPROXY_DECOY_DIR" == "/opt/telemt-web/public" ]]; then
        chown -R telemt:telemt /opt/telemt-web 2>/dev/null || true
    fi

    webproxy_generate_config || return 1
    telemt_create_service || return 1

    msg_ok "telemt установлен и настроен для WEB-режима"
}

# ══════════════════════════════════════════════════════════════════
#  Шаг 7: Ссылка подключения
# ══════════════════════════════════════════════════════════════════
webproxy_print_link() {
    msg_step "Ссылка WEB proxy"

    local link="tg://webproxy?server=${WEBPROXY_DOMAIN}&secret=dd${WEBPROXY_SECRET}"

    echo ""
    draw_info_box 70 \
        "${C_BOLD}tg://${C_RESET}  ${C_CYAN}${link}${C_RESET}"
    echo ""

    mkdir -p "$(dirname "$WEBPROXY_LINK_FILE")"
    {
        echo "# telemt WEB proxy link — $(date)"
        echo "# domain: ${WEBPROXY_DOMAIN}"
        echo "# user: ${WEBPROXY_USER}"
        echo "# secret: ${WEBPROXY_SECRET}"
        echo "$link"
    } > "$WEBPROXY_LINK_FILE"
    chmod 600 "$WEBPROXY_LINK_FILE"
    msg_ok "Ссылка сохранена в ${WEBPROXY_LINK_FILE}"

    msg_warn "Работает сейчас только в Telegram Desktop (Windows/macOS/Linux)"
}

# ══════════════════════════════════════════════════════════════════
#  Шаг 8: Проверка (по чеклисту из документации WEB-режима)
# ══════════════════════════════════════════════════════════════════
webproxy_verify() {
    msg_step "Финальная проверка"

    local ok=true

    if systemctl is-active --quiet nginx; then
        msg_ok "nginx — активен"
    else
        msg_err "nginx — НЕ работает"; ok=false
    fi

    if systemctl is-active --quiet telemt; then
        msg_ok "telemt — активен"
    else
        msg_warn "telemt — не запущен (проверьте: journalctl -u telemt -n 30)"
        ok=false
    fi

    local code_root code_404 code_bridge
    code_root=$(curl -sk -o /dev/null -w "%{http_code}" "https://${WEBPROXY_DOMAIN}/" --max-time 8 2>/dev/null) || true
    code_404=$(curl -sk -o /dev/null -w "%{http_code}" "https://${WEBPROXY_DOMAIN}/no-such-page" --max-time 8 2>/dev/null) || true
    code_bridge=$(curl -sk -o /dev/null -w "%{http_code}" "https://${WEBPROXY_DOMAIN}/?bridge=fake" --max-time 8 2>/dev/null) || true

    if [[ "$code_root" == "200" ]]; then
        msg_ok "Decoy-сайт отвечает на / (HTTP ${code_root})"
    else
        msg_warn "/ вернул HTTP ${code_root:-timeout} (ожидался 200 — decoy-сайт)"
    fi
    [[ "$code_404" == "404" ]] && msg_ok "Несуществующий путь → 404 (как у обычного сайта)" \
        || msg_warn "Несуществующий путь вернул ${code_404:-timeout} (ожидался 404)"
    [[ "$code_bridge" == "200" ]] && msg_ok "Запрос с фиктивным bridge → decoy (ожидаемо)" \
        || msg_warn "?bridge=fake вернул ${code_bridge:-timeout} (ожидался 200 — decoy)"

    [[ "$ok" == "true" ]] && msg_ok "Базовые проверки пройдены — добавьте ссылку в Telegram Desktop"
}

# ══════════════════════════════════════════════════════════════════
#  Главная точка входа
# ══════════════════════════════════════════════════════════════════
webproxy_setup() {
    webproxy_check_prereqs      || return 1
    webproxy_collect_params     || return 1
    webproxy_install_deps       || return 1
    webproxy_deploy_decoy       || return 1
    webproxy_obtain_cert        || return 1
    webproxy_configure_nginx    || return 1
    webproxy_install_telemt     || return 1
    webproxy_print_link
    webproxy_verify

    echo ""
    draw_info_box 62 \
        "${C_BOLD}WEB proxy настроен${C_RESET}" \
        "" \
        "Домен:   ${C_WHITE}https://${WEBPROXY_DOMAIN}${C_RESET}" \
        "Decoy:   ${C_WHITE}${WEBPROXY_DECOY_DIR}${C_RESET}" \
        "Серт:    ${C_WHITE}Let's Encrypt (авто)${C_RESET}" \
        "Схема:   ${C_WHITE}nginx :443 → telemt :${WEBPROXY_LISTEN_PORT} (web)${C_RESET}" \
        "" \
        "${C_YELLOW}Браузер:  https://${WEBPROXY_DOMAIN} → decoy-сайт${C_RESET}" \
        "${C_YELLOW}Telegram: tg://webproxy → только Desktop${C_RESET}"

    msg_ok "Установка WEB proxy завершена"
}

# ══════════════════════════════════════════════════════════════════
#  Удаление WEB proxy (без запросов — подтверждение берёт вызывающий)
#  Срезает только web-таблицы конфига и nginx-вхост, остальное не трогает.
#  Сертификат Let's Encrypt остаётся (можно переиспользовать).
# ══════════════════════════════════════════════════════════════════
_webproxy_strip_config() {
    local cfg="$1"
    python3 - "$cfg" << 'PYEOF'
import re, sys
p = sys.argv[1]
txt = open(p, encoding="utf-8").read()
blocks = re.split(r"(?m)^(?=\[)", txt)
out = []
for b in blocks:
    head = b.split("\n", 1)[0].strip()
    if re.match(r"^\[\[?web(\]|\.)", head):
        continue
    if head == "[[server.listeners]]" and re.search(r'(?m)^transport\s*=\s*"web"', b):
        continue
    out.append(b)
res = "".join(out)
res = re.sub(r"(?m)^# WEB-листенер.*\n", "", res)
open(p, "w", encoding="utf-8").write(res)
PYEOF
}

webproxy_remove() {
    msg_step "Удаление WEB proxy"

    rm -f /etc/nginx/sites-available/telemt-web /etc/nginx/sites-enabled/telemt-web
    rm -f /etc/nginx/sites-available/telemt-web-acme-temp /etc/nginx/sites-enabled/telemt-web-acme-temp

    local cfg="$WEBPROXY_CONFIG"
    if [[ -f "$cfg" ]]; then
        mkdir -p /opt/telemt/backups
        cp "$cfg" "/opt/telemt/backups/$(basename "$cfg").pre-webproxy-remove.$(date +%s)"
        if _webproxy_strip_config "$cfg"; then
            msg_ok "Web-блоки удалены из ${cfg} (бэкап в /opt/telemt/backups)"
        else
            msg_warn "Не удалось автоматически вычистить конфиг — проверьте ${cfg} вручную"
        fi
        # Без листенеров telemt не имеет смысла запускать
        if ! grep -q '^\[\[server\.listeners\]\]' "$cfg" 2>/dev/null; then
            systemctl stop telemt >> "$LOG_FILE" 2>&1 || true
            msg_warn "В конфиге не осталось листенеров — telemt остановлен"
        else
            systemctl restart telemt >> "$LOG_FILE" 2>&1 || true
        fi
    fi

    rm -rf /opt/telemt-web /var/www/telemt-web-acme 2>/dev/null
    rm -f "$WEBPROXY_LINK_FILE" 2>/dev/null
    nginx -t >> "$LOG_FILE" 2>&1 && systemctl reload nginx >> "$LOG_FILE" 2>&1
    msg_ok "WEB proxy удалён (сертификат Let's Encrypt оставлен)"
}
