#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  modules/site_mask.sh — selfmask: маскировка прокси под свой сайт
#  Источник: assyoucandy.github.io/telemt-server-guide/telemt-selfmask-guide
# ═══════════════════════════════════════════════════════════════════

MASK_DOMAIN=""
MASK_NGINX_BACKEND_PORT="8444"
MASK_SITE_DIR="/var/www/html"
MASK_SITE_SOURCE=""

# ══════════════════════════════════════════════════════════════════
#  Шаг 1: Сбор параметров
# ══════════════════════════════════════════════════════════════════
sitemask_collect_params() {
    msg_header "Параметры selfmask"

    msg_info "Selfmask маскирует прокси под реальный сайт на вашем домене."
    msg_info "Трафик на :443 принимает telemt (MTProto), а неизвестный SNI"
    msg_info "и браузерные запросы уходят в nginx с вашим сайтом."
    msg_info "Требуется домен с A-записью, указывающей на этот сервер."
    echo ""

    prompt_input "Ваш домен (A-запись → этот сервер)" MASK_DOMAIN '^[a-zA-Z0-9._-]+\.[a-zA-Z]{2,}$'

    # Проверка DNS
    local server_ip="" resolved_ip=""
    server_ip=$(_get_public_ipv4)
    msg_info "IP сервера: ${server_ip}"

    # Ставим dnsutils если нет dig
    if ! command -v dig &>/dev/null; then
        apt-get install -y -qq dnsutils >> "$LOG_FILE" 2>&1 || true
    fi

    if command -v dig &>/dev/null; then
        resolved_ip=$(dig +short "$MASK_DOMAIN" A 2>/dev/null | tail -1)
    elif command -v nslookup &>/dev/null; then
        resolved_ip=$(nslookup "$MASK_DOMAIN" 2>/dev/null | awk '/^Address:/{a=$2} END{print a}')
    elif command -v host &>/dev/null; then
        resolved_ip=$(host "$MASK_DOMAIN" 2>/dev/null | awk '/has address/{print $4; exit}')
    fi

    if [[ -n "$resolved_ip" ]]; then
        if [[ "$resolved_ip" == "$server_ip" ]]; then
            msg_ok "DNS подтверждён: ${MASK_DOMAIN} → ${resolved_ip}"
        else
            msg_warn "DNS: ${MASK_DOMAIN} → ${resolved_ip} (ожидался ${server_ip})"
            msg_warn "Let's Encrypt НЕ СМОЖЕТ выдать сертификат, если DNS не совпадает!"
            if ! confirm_yn "Продолжить несмотря на несовпадение?" "n"; then return 1; fi
        fi
    else
        msg_warn "Не удалось проверить DNS — убедитесь, что A-запись настроена"
    fi

    # ── Выбор шаблона сайта ───────────────────────────────────────
    echo ""
    msg_step "Выбор шаблона сайта-маски"
    echo -e "    ${C_GREEN}[1]${C_RESET} ${C_BOLD}Market-Terminal-Template${C_RESET} (vaalaav)"
    echo -e "        ${C_DIM}https://github.com/vaalaav/Market-Terminal-Template${C_RESET}"
    echo -e "    ${C_GREEN}[2]${C_RESET} ${C_BOLD}kotorunner${C_RESET} (vaalaav)"
    echo -e "        ${C_DIM}https://github.com/vaalaav/kotorunner${C_RESET}"
    echo -e "    ${C_CYAN}[3]${C_RESET} ${C_BOLD}Указать свой git-репозиторий${C_RESET}"
    echo -e "    ${C_DIM}[4]${C_RESET} ${C_BOLD}Простая HTML-заглушка${C_RESET}"
    echo -ne "  ${C_BOLD}Выбор${C_RESET} [1-4]: "

    local choice
    read -r choice
    case "$choice" in
        1)
            MASK_SITE_SOURCE="https://github.com/vaalaav/Market-Terminal-Template.git"
            msg_ok "Выбран шаблон: Market-Terminal-Template"
            ;;
        2)
            MASK_SITE_SOURCE="https://github.com/vaalaav/kotorunner.git"
            msg_ok "Выбран шаблон: kotorunner"
            ;;
        3)
            prompt_input "URL git-репозитория" MASK_SITE_SOURCE '^https?://'
            msg_ok "Кастомный шаблон: ${MASK_SITE_SOURCE}"
            ;;
        4|*)
            MASK_SITE_SOURCE="stub"
            msg_info "Будет создана простая HTML-заглушка"
            ;;
    esac

    echo ""
    draw_info_box 62 \
        "${C_BOLD}Параметры selfmask:${C_RESET}" \
        "" \
        "Домен:     ${C_WHITE}${MASK_DOMAIN}${C_RESET}" \
        "Бэкенд:   ${C_WHITE}127.0.0.1:${MASK_NGINX_BACKEND_PORT}${C_RESET}" \
        "Шаблон:    ${C_WHITE}${MASK_SITE_SOURCE}${C_RESET}" \
        "Web root:  ${C_WHITE}${MASK_SITE_DIR}${C_RESET}" \
        "" \
        "${C_DIM}telemt :443 → MTProto + mask → nginx :${MASK_NGINX_BACKEND_PORT}${C_RESET}"

    confirm_yn "Начать настройку selfmask?" "y" || return 1
}

# ══════════════════════════════════════════════════════════════════
#  Шаг 2: Установка зависимостей
# ══════════════════════════════════════════════════════════════════
sitemask_install_deps() {
    msg_step "Установка зависимостей"

    local pkgs_needed=()

    command -v nginx   &>/dev/null || pkgs_needed+=(nginx)
    command -v certbot &>/dev/null || pkgs_needed+=(certbot python3-certbot-nginx)
    command -v git     &>/dev/null || pkgs_needed+=(git)
    command -v rsync   &>/dev/null || pkgs_needed+=(rsync)

    # python3-certbot-nginx может быть не установлен даже если certbot есть
    if command -v certbot &>/dev/null; then
        if ! dpkg -s python3-certbot-nginx &>/dev/null 2>&1; then
            pkgs_needed+=(python3-certbot-nginx)
        fi
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

    # Убедимся nginx запущен
    systemctl enable nginx >> "$LOG_FILE" 2>&1 || true
    systemctl start nginx >> "$LOG_FILE" 2>&1 || true

    msg_ok "Зависимости установлены: nginx, certbot, python3-certbot-nginx, git, rsync"
}

# ══════════════════════════════════════════════════════════════════
#  Шаг 3: Развёртывание шаблона сайта из GitHub
# ══════════════════════════════════════════════════════════════════
sitemask_deploy_site() {
    msg_step "Развёртывание сайта-маски"

    mkdir -p "$MASK_SITE_DIR"

    if [[ "$MASK_SITE_SOURCE" == "stub" ]]; then
        # ── HTML-заглушка ─────────────────────────────────────────
        cat > "${MASK_SITE_DIR}/index.html" << 'STUBHTML'
<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Welcome</title>
<style>
  body { font-family: system-ui, -apple-system, sans-serif; max-width: 640px;
         margin: 80px auto; padding: 0 20px; color: #333; background: #fafafa; }
  h1 { font-size: 1.5rem; color: #111; }
  p  { color: #666; line-height: 1.6; }
  .footer { margin-top: 60px; font-size: 0.8rem; color: #aaa; }
</style></head>
<body>
  <h1>Welcome</h1>
  <p>This site is currently under construction. Please check back later.</p>
  <p class="footer">&copy; 2024</p>
</body></html>
STUBHTML
        msg_ok "HTML-заглушка создана в ${MASK_SITE_DIR}"

    else
        # ── Клонирование git-репозитория ──────────────────────────
        local tmp_dir
        tmp_dir=$(mktemp -d)

        msg_info "Клонирование: ${MASK_SITE_SOURCE}"

        if run_with_spinner "git clone шаблона" git clone --depth 1 "$MASK_SITE_SOURCE" "${tmp_dir}/repo"; then
            # Очистить старый контент (сохраняем .well-known для ACME)
            find "$MASK_SITE_DIR" -mindepth 1 -maxdepth 1 ! -name '.well-known' -exec rm -rf {} + 2>/dev/null || true

            # Копировать содержимое без .git (rsync → find fallback)
            if command -v rsync &>/dev/null; then
                rsync -a --exclude='.git' "${tmp_dir}/repo/" "${MASK_SITE_DIR}/"
            else
                find "${tmp_dir}/repo" -mindepth 1 -maxdepth 1 ! -name '.git' \
                    -exec cp -a {} "${MASK_SITE_DIR}/" \;
            fi

            rm -rf "$tmp_dir"
            msg_ok "Шаблон развёрнут в ${MASK_SITE_DIR}"

            # Показать что развернулось
            local file_count
            file_count=$(find "$MASK_SITE_DIR" -type f | wc -l)
            msg_info "Файлов в web root: ${file_count}"
        else
            rm -rf "$tmp_dir"
            msg_warn "Не удалось склонировать репозиторий"
            msg_info "Создаём HTML-заглушку вместо шаблона..."
            MASK_SITE_SOURCE="stub"
            # Создаём заглушку напрямую, без рекурсии
            cat > "${MASK_SITE_DIR}/index.html" << 'FALLBACKHTML'
<!doctype html><html lang="ru"><head><meta charset="utf-8">
<title>Welcome</title></head>
<body><h1>Site is under construction</h1></body></html>
FALLBACKHTML
            msg_ok "Fallback-заглушка создана"
        fi
    fi

    # Права для nginx
    chown -R www-data:www-data "$MASK_SITE_DIR" 2>/dev/null || true
    chmod -R 755 "$MASK_SITE_DIR" 2>/dev/null || true

    rollback_push "rm -rf '${MASK_SITE_DIR}/'* 2>/dev/null; echo '<h1>nginx</h1>' > '${MASK_SITE_DIR}/index.html' 2>/dev/null"
}

# ══════════════════════════════════════════════════════════════════
#  Шаг 4: Let's Encrypt сертификат (webroot)
#  webroot, НЕ standalone — потому что :80 занят nginx,
#  и standalone сломает автопродление (certbot renew)
# ══════════════════════════════════════════════════════════════════
sitemask_obtain_cert() {
    msg_step "Получение Let's Encrypt сертификата"

    local cert_dir="/etc/letsencrypt/live/${MASK_DOMAIN}"

    # Уже есть?
    if [[ -f "${cert_dir}/fullchain.pem" ]]; then
        msg_ok "Сертификат уже существует для ${MASK_DOMAIN}"
        local expiry
        expiry=$(openssl x509 -enddate -noout -in "${cert_dir}/cert.pem" 2>/dev/null | cut -d= -f2)
        [[ -n "$expiry" ]] && msg_info "Истекает: ${expiry}"
        if ! confirm_yn "Перевыпустить сертификат?" "n"; then
            return 0
        fi
    fi

    # Временный nginx-конфиг для ACME webroot-валидации
    mkdir -p "${MASK_SITE_DIR}/.well-known/acme-challenge"

    cat > /etc/nginx/sites-available/acme-temp << ACMETMPEOF
server {
    listen 80;
    server_name ${MASK_DOMAIN};
    root ${MASK_SITE_DIR};
    location /.well-known/acme-challenge/ { allow all; }
    location / { return 200 'ok'; add_header Content-Type text/plain; }
}
ACMETMPEOF

    ln -sf /etc/nginx/sites-available/acme-temp /etc/nginx/sites-enabled/acme-temp
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

    if ! nginx -t >> "$LOG_FILE" 2>&1; then
        msg_err "Ошибка nginx конфига для ACME — проверьте nginx -t"
        rm -f /etc/nginx/sites-available/acme-temp /etc/nginx/sites-enabled/acme-temp
        return 1
    fi
    systemctl restart nginx >> "$LOG_FILE" 2>&1

    # Открыть порт 80 для ACME
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow 80/tcp >> "$LOG_FILE" 2>&1 || true
    fi

    # Получение сертификата через webroot
    msg_info "Запрашиваем сертификат для ${MASK_DOMAIN}..."
    if run_with_spinner "certbot (webroot)" \
        certbot certonly --webroot -w "$MASK_SITE_DIR" \
        -d "$MASK_DOMAIN" --non-interactive --agree-tos \
        -m "admin@${MASK_DOMAIN}" --cert-name "$MASK_DOMAIN"; then

        msg_ok "Сертификат получен: ${cert_dir}"
        rollback_push "certbot delete --cert-name '${MASK_DOMAIN}' --non-interactive 2>/dev/null || true"

        # Проверка
        local expiry
        expiry=$(openssl x509 -enddate -noout -in "${cert_dir}/cert.pem" 2>/dev/null | cut -d= -f2)
        [[ -n "$expiry" ]] && msg_info "Действителен до: ${expiry}"
    else
        msg_err "Не удалось получить сертификат"
        msg_info "Чеклист:"
        echo -e "    ${C_YELLOW}•${C_RESET} DNS A-запись ${MASK_DOMAIN} → IP сервера"
        echo -e "    ${C_YELLOW}•${C_RESET} Порт 80/tcp открыт и доступен извне"
        echo -e "    ${C_YELLOW}•${C_RESET} Нет другого процесса на :80"
        rm -f /etc/nginx/sites-available/acme-temp /etc/nginx/sites-enabled/acme-temp
        return 1
    fi

    # Убрать временный конфиг (заменим боевым на следующем шаге)
    rm -f /etc/nginx/sites-enabled/acme-temp
}

# ══════════════════════════════════════════════════════════════════
#  Шаг 5: Nginx — боевой конфиг (3 server-блока по selfmask-guide)
#
#  Блок 1: default_server — чужой Host / прямой IP → 444 (обрыв)
#  Блок 2: :80 domain    — ACME challenge + redirect → https
#  Блок 3: :8444 ssl     — локальный бэкенд для telemt mask
#
#  Маршрут: telemt :443 (MTProto) → unknown SNI → mask → nginx :8444
# ══════════════════════════════════════════════════════════════════
sitemask_configure_nginx() {
    msg_step "Настройка Nginx (3 server-блока для selfmask)"

    local nginx_conf="/etc/nginx/sites-available/site"
    local cert_dir="/etc/letsencrypt/live/${MASK_DOMAIN}"

    # Проверяем наличие сертификата
    if [[ ! -f "${cert_dir}/fullchain.pem" ]]; then
        msg_err "Сертификат не найден в ${cert_dir} — пропускаем настройку Nginx"
        return 1
    fi

    # Генерация конфига — НЕ используем heredoc с подстановкой для nginx-переменных!
    # Записываем через tee, чтобы $request_uri / $uri не интерпретировались bash-ом
    python3 -c "
domain = '${MASK_DOMAIN}'
backend = '${MASK_NGINX_BACKEND_PORT}'
webroot = '${MASK_SITE_DIR}'
cert    = '/etc/letsencrypt/live/${MASK_DOMAIN}'

cfg = f'''# telemt selfmask nginx — сгенерировано telemt VPS Installer
# Домен: {domain}
# Схема: telemt :443 → unknown SNI → mask → nginx :{backend}

# Блок 1: default — чужой Host / прямой IP → обрыв соединения
server {{
    listen 80 default_server;
    listen 127.0.0.1:{backend} ssl default_server;
    server_name _;
    ssl_certificate     {cert}/fullchain.pem;
    ssl_certificate_key {cert}/privkey.pem;
    return 444;
}}

# Блок 2: :80 — ACME webroot для автопродления + редирект на https
server {{
    listen 80;
    server_name {domain};
    location /.well-known/acme-challenge/ {{
        root {webroot};
        allow all;
    }}
    location / {{
        return 301 https://{domain}\$request_uri;
    }}
}}

# Блок 3: :8444 ssl — сам сайт (локальный бэкенд для telemt mask)
server {{
    listen 127.0.0.1:{backend} ssl;
    server_name {domain};
    server_tokens off;

    ssl_certificate     {cert}/fullchain.pem;
    ssl_certificate_key {cert}/privkey.pem;

    root {webroot};
    index index.html index.htm;

    # Безопасность
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header Referrer-Policy no-referrer always;

    # Фильтр-ловушка: режет сканеры по пути URI
    location ~* \"(wget|curl|chmod|/tmp/|eval\\\\(|base64)\" {{
        return 403;
    }}

    location / {{
        try_files \$uri \$uri/ =404;
    }}
}}
'''
with open('${nginx_conf}', 'w') as f:
    f.write(cfg)
print('OK')
" >> "$LOG_FILE" 2>&1

    if [[ ! -f "$nginx_conf" ]]; then
        msg_err "Не удалось создать конфиг Nginx"
        return 1
    fi

    # Активация
    ln -sf "$nginx_conf" /etc/nginx/sites-enabled/site
    rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-enabled/acme-temp 2>/dev/null || true

    # Проверка
    if nginx -t >> "$LOG_FILE" 2>&1; then
        systemctl restart nginx >> "$LOG_FILE" 2>&1
        rollback_push "rm -f '${nginx_conf}' /etc/nginx/sites-enabled/site; ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default 2>/dev/null; systemctl restart nginx 2>/dev/null"
        msg_ok "Nginx настроен (3 блока: default-drop, ACME+redirect, SSL-site)"
    else
        msg_err "Ошибка конфигурации Nginx — запуск: nginx -t"
        cat "$nginx_conf" >> "$LOG_FILE"
        rm -f "$nginx_conf" /etc/nginx/sites-enabled/site
        return 1
    fi

    # Открыть 80 и 443 в firewall
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow 80/tcp  >> "$LOG_FILE" 2>&1 || true
        ufw allow 443/tcp >> "$LOG_FILE" 2>&1 || true
        rollback_push "ufw delete allow 80/tcp 2>/dev/null; ufw delete allow 443/tcp 2>/dev/null"
        msg_ok "UFW: порты 80, 443 открыты"
    fi
}

# ══════════════════════════════════════════════════════════════════
#  Шаг 6: Обновление конфига telemt для selfmask
#  port=443, mask=true, mask_port=8444, tls_domain=DOMAIN
# ══════════════════════════════════════════════════════════════════
sitemask_update_telemt_config() {
    msg_step "Настройка telemt для selfmask"

    local cfg=""
    # Сначала пробуем через _opt_detect_config (из optimization.sh)
    if declare -F _opt_detect_config &>/dev/null; then
        cfg=$(_opt_detect_config 2>/dev/null)
    fi
    # Fallback
    if [[ -z "$cfg" ]]; then
        for f in /etc/telemt/telemt.toml /etc/telemt/config.toml "${TELEMT_CONFIG:-}"; do
            [[ -f "$f" ]] && cfg="$f" && break
        done
    fi

    if [[ -z "$cfg" || ! -f "$cfg" ]]; then
        msg_warn "Конфиг telemt не найден"
        msg_info "Убедитесь, что telemt установлен, и добавьте вручную:"
        echo ""
        echo -e "  ${C_DIM}[server]${C_RESET}"
        echo -e "  ${C_WHITE}port = 443${C_RESET}"
        echo ""
        echo -e "  ${C_DIM}[censorship]${C_RESET}"
        echo -e "  ${C_WHITE}tls_domain = \"${MASK_DOMAIN}\"${C_RESET}"
        echo -e "  ${C_WHITE}mask = true${C_RESET}"
        echo -e "  ${C_WHITE}mask_port = ${MASK_NGINX_BACKEND_PORT}${C_RESET}"
        echo ""
        return 0
    fi

    msg_info "Конфиг telemt: ${cfg}"

    # Бэкап
    mkdir -p /opt/telemt/backups
    cp "$cfg" "/opt/telemt/backups/$(basename "$cfg").pre-mask.$(date +%s)"
    rollback_push "cp '/opt/telemt/backups/$(basename "$cfg").pre-mask.'* '${cfg}' 2>/dev/null || true"

    # ── port = 443 ────────────────────────────────────────────────
    if grep -qE '^port[[:space:]]*=' "$cfg"; then
        sed -i 's/^port[[:space:]]*=.*/port = 443/' "$cfg"
    elif grep -q '\[server\]' "$cfg"; then
        sed -i '/\[server\]/a port = 443' "$cfg"
    fi
    msg_ok "port = 443"

    # ── [censorship] tls_domain ───────────────────────────────────
    if grep -qE '^tls_domain[[:space:]]*=' "$cfg"; then
        sed -i "s|^tls_domain[[:space:]]*=.*|tls_domain = \"${MASK_DOMAIN}\"|" "$cfg"
    elif grep -q '\[censorship\]' "$cfg"; then
        sed -i "/\[censorship\]/a tls_domain = \"${MASK_DOMAIN}\"" "$cfg"
    else
        echo -e "\n[censorship]\ntls_domain = \"${MASK_DOMAIN}\"" >> "$cfg"
    fi
    msg_ok "tls_domain = ${MASK_DOMAIN}"

    # ── mask = true ───────────────────────────────────────────────
    if grep -qE '^#?[[:space:]]*mask[[:space:]]*=' "$cfg"; then
        sed -i 's/^#\?[[:space:]]*mask[[:space:]]*=.*/mask = true/' "$cfg"
    elif grep -q '\[censorship\]' "$cfg"; then
        sed -i '/\[censorship\]/a mask = true' "$cfg"
    fi
    msg_ok "mask = true"

    # ── mask_port = 8444 ──────────────────────────────────────────
    if grep -qE '^#?[[:space:]]*mask_port[[:space:]]*=' "$cfg"; then
        sed -i "s/^#\?[[:space:]]*mask_port[[:space:]]*=.*/mask_port = ${MASK_NGINX_BACKEND_PORT}/" "$cfg"
    elif grep -q '\[censorship\]' "$cfg"; then
        sed -i "/\[censorship\]/a mask_port = ${MASK_NGINX_BACKEND_PORT}" "$cfg"
    fi
    msg_ok "mask_port = ${MASK_NGINX_BACKEND_PORT}"

    # ── public_host = DOMAIN ──────────────────────────────────────
    if grep -qE '^#?[[:space:]]*public_host[[:space:]]*=' "$cfg"; then
        sed -i "s|^#\?[[:space:]]*public_host[[:space:]]*=.*|public_host = \"${MASK_DOMAIN}\"|" "$cfg"
    elif grep -q '\[general.links\]' "$cfg"; then
        sed -i "/\[general\.links\]/a public_host = \"${MASK_DOMAIN}\"" "$cfg"
    fi
    msg_ok "public_host = ${MASK_DOMAIN}"

    # Перезапуск telemt
    if systemctl is-active --quiet telemt 2>/dev/null; then
        run_with_spinner "Перезапуск telemt" systemctl restart telemt
    else
        msg_info "telemt не запущен — перезапуск пропущен"
    fi

    msg_ok "telemt настроен: :443 → mask → nginx:${MASK_NGINX_BACKEND_PORT}"
}

# ══════════════════════════════════════════════════════════════════
#  Шаг 7: Автопродление сертификата
# ══════════════════════════════════════════════════════════════════
sitemask_setup_renewal() {
    msg_step "Автопродление сертификата"

    if systemctl is-enabled certbot.timer &>/dev/null 2>&1; then
        msg_ok "certbot.timer уже активен — автопродление работает"
    elif [[ -f /etc/cron.d/certbot ]]; then
        msg_ok "certbot cron уже настроен"
    else
        # Ручной cron с reload nginx после обновления
        local cron_line="0 3 * * * certbot renew --quiet --deploy-hook 'systemctl reload nginx'"
        if ! crontab -l 2>/dev/null | grep -q 'certbot renew'; then
            (crontab -l 2>/dev/null; echo "$cron_line") | crontab -
            msg_ok "Cron для автопродления настроен (03:00 ежедневно)"
        else
            msg_info "Cron для certbot renew уже существует"
        fi
    fi
}

# ══════════════════════════════════════════════════════════════════
#  Шаг 8: Финальная проверка
# ══════════════════════════════════════════════════════════════════
sitemask_verify() {
    msg_step "Финальная проверка"

    local ok=true

    # nginx работает?
    if systemctl is-active --quiet nginx; then
        msg_ok "nginx — активен"
    else
        msg_err "nginx — НЕ работает"
        ok=false
    fi

    # telemt работает?
    if systemctl is-active --quiet telemt; then
        msg_ok "telemt — активен"
    else
        msg_warn "telemt — не запущен (проверьте journalctl -u telemt)"
    fi

    # Сертификат на месте?
    if [[ -f "/etc/letsencrypt/live/${MASK_DOMAIN}/fullchain.pem" ]]; then
        msg_ok "SSL-сертификат — на месте"
    else
        msg_err "SSL-сертификат — ОТСУТСТВУЕТ"
        ok=false
    fi

    # Сайт отвечает локально?
    local http_code
    http_code=$(curl -sk -o /dev/null -w "%{http_code}" "https://127.0.0.1:${MASK_NGINX_BACKEND_PORT}/" \
        --resolve "${MASK_DOMAIN}:${MASK_NGINX_BACKEND_PORT}:127.0.0.1" 2>/dev/null) || true
    if [[ "$http_code" == "200" ]]; then
        msg_ok "Сайт-маска отвечает на :${MASK_NGINX_BACKEND_PORT} (HTTP ${http_code})"
    else
        msg_warn "Сайт-маска: HTTP ${http_code:-timeout} (может быть ок — проверьте вручную)"
    fi

    if [[ "$ok" == "true" ]]; then
        msg_ok "Все проверки пройдены"
    fi
}

# ══════════════════════════════════════════════════════════════════
#  Главная точка входа
# ══════════════════════════════════════════════════════════════════
sitemask_setup() {
    sitemask_collect_params       || return 1
    sitemask_install_deps         || return 1
    sitemask_deploy_site          || return 1
    sitemask_obtain_cert          || return 1
    sitemask_configure_nginx      || return 1
    sitemask_update_telemt_config || return 1
    sitemask_setup_renewal        || true
    sitemask_verify

    echo ""
    draw_info_box 62 \
        "${C_BOLD}Selfmask настроен${C_RESET}" \
        "" \
        "Домен:   ${C_WHITE}https://${MASK_DOMAIN}${C_RESET}" \
        "Сайт:    ${C_WHITE}${MASK_SITE_DIR}${C_RESET}" \
        "Шаблон:  ${C_WHITE}${MASK_SITE_SOURCE}${C_RESET}" \
        "Серт:    ${C_WHITE}Let's Encrypt (авто)${C_RESET}" \
        "telemt:  ${C_WHITE}:443 → mask → nginx:${MASK_NGINX_BACKEND_PORT}${C_RESET}" \
        "" \
        "${C_YELLOW}Браузер: https://${MASK_DOMAIN} → ваш сайт${C_RESET}" \
        "${C_YELLOW}Telegram: tg://proxy → MTProto через :443${C_RESET}"

    msg_ok "Selfmask настройка завершена"
}
