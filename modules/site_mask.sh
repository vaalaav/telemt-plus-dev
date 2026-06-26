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
    msg_info "Требуется домен с A-записью, указывающей на этот сервер."
    echo ""

    prompt_input "Ваш домен (A-запись → этот сервер)" MASK_DOMAIN '^[a-zA-Z0-9._-]+\.[a-zA-Z]{2,}$'

    # Проверка DNS
    local server_ip resolved_ip
    server_ip=$(_get_public_ipv4)
    msg_info "IP сервера: ${server_ip}"

    if command -v dig &>/dev/null; then
        resolved_ip=$(dig +short "$MASK_DOMAIN" A 2>/dev/null | tail -1)
    elif command -v nslookup &>/dev/null; then
        resolved_ip=$(nslookup "$MASK_DOMAIN" 2>/dev/null | awk '/^Address:/{a=$2} END{print a}')
    fi

    if [[ -n "$resolved_ip" ]]; then
        if [[ "$resolved_ip" == "$server_ip" ]]; then
            msg_ok "DNS: ${MASK_DOMAIN} → ${resolved_ip}"
        else
            msg_warn "DNS: ${MASK_DOMAIN} → ${resolved_ip} (ожидался ${server_ip})"
            msg_warn "Let's Encrypt НЕ СМОЖЕТ выдать сертификат, если DNS не совпадает!"
            if ! confirm_yn "Продолжить?" "n"; then return 1; fi
        fi
    else
        msg_warn "Не удалось проверить DNS"
    fi

    # Выбор шаблона сайта
    echo ""
    msg_step "Выбор шаблона сайта-маски"
    echo -e "    ${C_GREEN}[1]${C_RESET} Market-Terminal-Template (vaalaav)"
    echo -e "    ${C_GREEN}[2]${C_RESET} kotorunner (vaalaav)"
    echo -e "    ${C_CYAN}[3]${C_RESET} Указать свой git-репозиторий"
    echo -e "    ${C_DIM}[4]${C_RESET} Простая HTML-заглушка"
    echo -ne "  ${C_BOLD}Выбор${C_RESET} [1-4]: "

    local choice
    read -r choice
    case "$choice" in
        1) MASK_SITE_SOURCE="https://github.com/vaalaav/Market-Terminal-Template.git" ;;
        2) MASK_SITE_SOURCE="https://github.com/vaalaav/kotorunner.git" ;;
        3) prompt_input "URL git-репозитория" MASK_SITE_SOURCE '^https?://' ;;
        4|*) MASK_SITE_SOURCE="stub" ;;
    esac

    echo ""
    draw_info_box 60 \
        "Домен:     ${C_WHITE}${MASK_DOMAIN}${C_RESET}" \
        "Бэкенд:   ${C_WHITE}127.0.0.1:${MASK_NGINX_BACKEND_PORT}${C_RESET}" \
        "Шаблон:    ${C_WHITE}${MASK_SITE_SOURCE}${C_RESET}" \
        "Web root:  ${C_WHITE}${MASK_SITE_DIR}${C_RESET}"

    confirm_yn "Начать настройку selfmask?" "y" || return 1
}

# ══════════════════════════════════════════════════════════════════
#  Шаг 2: Установка зависимостей
# ══════════════════════════════════════════════════════════════════
sitemask_install_deps() {
    msg_step "Установка зависимостей (nginx, certbot)"

    local pkgs=()
    command -v nginx &>/dev/null    || pkgs+=(nginx)
    command -v certbot &>/dev/null  || pkgs+=(certbot)

    if [[ ${#pkgs[@]} -gt 0 ]]; then
        run_with_spinner "apt install ${pkgs[*]}" apt-get install -y -qq "${pkgs[@]}" || {
            msg_err "Не удалось установить пакеты"
            return 1
        }
    fi
    msg_ok "Зависимости в порядке"
}

# ══════════════════════════════════════════════════════════════════
#  Шаг 3: Let's Encrypt сертификат (webroot)
# ══════════════════════════════════════════════════════════════════
sitemask_obtain_cert() {
    msg_step "Получение Let's Encrypt сертификата"

    local cert_dir="/etc/letsencrypt/live/${MASK_DOMAIN}"

    # Уже есть?
    if [[ -f "${cert_dir}/fullchain.pem" ]]; then
        msg_ok "Сертификат уже существует"
        if ! confirm_yn "Получить новый (перевыпустить)?" "n"; then
            return 0
        fi
    fi

    # Временный nginx для ACME-валидации
    mkdir -p "${MASK_SITE_DIR}/.well-known/acme-challenge"

    cat > /etc/nginx/sites-available/acme-temp << ACMEEOF
server {
    listen 80;
    server_name ${MASK_DOMAIN};
    root ${MASK_SITE_DIR};
    location /.well-known/acme-challenge/ { allow all; }
}
ACMEEOF

    ln -sf /etc/nginx/sites-available/acme-temp /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default
    nginx -t >> "$LOG_FILE" 2>&1 && systemctl restart nginx >> "$LOG_FILE" 2>&1

    # Открыть порт 80 для ACME
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow 80/tcp >> "$LOG_FILE" 2>&1
    fi

    # Получение сертификата
    if run_with_spinner "certbot (webroot)" \
        certbot certonly --webroot -w "$MASK_SITE_DIR" \
        -d "$MASK_DOMAIN" --non-interactive --agree-tos \
        -m "admin@${MASK_DOMAIN}" --cert-name "$MASK_DOMAIN"; then
        msg_ok "Сертификат получен: ${cert_dir}"
        rollback_push "certbot delete --cert-name '${MASK_DOMAIN}' --non-interactive 2>/dev/null || true"
    else
        msg_err "Не удалось получить сертификат"
        msg_info "Проверьте: DNS A-запись, порт 80 открыт, домен указывает на сервер"
        rm -f /etc/nginx/sites-available/acme-temp /etc/nginx/sites-enabled/acme-temp
        return 1
    fi

    # Убрать временный конфиг
    rm -f /etc/nginx/sites-enabled/acme-temp
}

# ══════════════════════════════════════════════════════════════════
#  Шаг 4: Развёртывание шаблона сайта
# ══════════════════════════════════════════════════════════════════
sitemask_deploy_site() {
    msg_step "Развёртывание сайта-маски"

    if [[ "$MASK_SITE_SOURCE" == "stub" ]]; then
        cat > "${MASK_SITE_DIR}/index.html" << 'STUBEOF'
<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Welcome</title>
<style>body{font-family:system-ui;max-width:640px;margin:80px auto;padding:0 20px;color:#333}
h1{font-size:1.5rem}p{color:#666;line-height:1.6}</style></head>
<body><h1>Welcome</h1><p>This site is under construction. Please check back later.</p></body></html>
STUBEOF
        msg_ok "HTML-заглушка создана"
    else
        # Клонирование git-репозитория
        local tmp_dir
        tmp_dir=$(mktemp -d)
        if run_with_spinner "Клонирование шаблона" git clone --depth 1 "$MASK_SITE_SOURCE" "$tmp_dir"; then
            # Очистить старый контент (кроме .well-known)
            find "$MASK_SITE_DIR" -mindepth 1 -maxdepth 1 ! -name '.well-known' -exec rm -rf {} + 2>/dev/null
            # Копировать содержимое (без .git)
            rsync -a --exclude='.git' "${tmp_dir}/" "${MASK_SITE_DIR}/" 2>/dev/null || \
                cp -a "${tmp_dir}"/!(\.git) "${MASK_SITE_DIR}/" 2>/dev/null || \
                { find "$tmp_dir" -mindepth 1 -maxdepth 1 ! -name '.git' -exec cp -a {} "${MASK_SITE_DIR}/" \; ; }
            rm -rf "$tmp_dir"
            msg_ok "Шаблон развёрнут в ${MASK_SITE_DIR}"
        else
            rm -rf "$tmp_dir"
            msg_warn "Не удалось склонировать — используем заглушку"
            sitemask_deploy_site  # рекурсия с stub
            MASK_SITE_SOURCE="stub"
        fi
    fi

    chown -R www-data:www-data "$MASK_SITE_DIR" 2>/dev/null || true
    rollback_push "rm -rf '${MASK_SITE_DIR}/'* 2>/dev/null || true"
}

# ══════════════════════════════════════════════════════════════════
#  Шаг 5: Nginx — боевой конфиг (3 блока из selfmask-guide)
# ══════════════════════════════════════════════════════════════════
sitemask_configure_nginx() {
    msg_step "Настройка Nginx (3 server-блока)"

    local nginx_conf="/etc/nginx/sites-available/site"

    cat > "$nginx_conf" << NGXEOF
# telemt selfmask nginx — сгенерировано telemt VPS Installer
# Домен: ${MASK_DOMAIN}

# Блок 1: default — чужой Host / прямой IP → обрыв
server {
    listen 80 default_server;
    listen 127.0.0.1:${MASK_NGINX_BACKEND_PORT} ssl default_server;
    server_name _;
    ssl_certificate /etc/letsencrypt/live/${MASK_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${MASK_DOMAIN}/privkey.pem;
    return 444;
}

# Блок 2: :80 — ACME + редирект на https
server {
    listen 80;
    server_name ${MASK_DOMAIN};
    location /.well-known/acme-challenge/ {
        root ${MASK_SITE_DIR};
        allow all;
    }
    location / {
        return 301 https://${MASK_DOMAIN}\$request_uri;
    }
}

# Блок 3: :8444 ssl — сам сайт (локальный бэкенд для telemt mask)
server {
    listen 127.0.0.1:${MASK_NGINX_BACKEND_PORT} ssl;
    server_name ${MASK_DOMAIN};
    server_tokens off;

    ssl_certificate /etc/letsencrypt/live/${MASK_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${MASK_DOMAIN}/privkey.pem;

    root ${MASK_SITE_DIR};
    index index.html;

    # Фильтр-ловушка для сканеров
    location ~* "(wget|curl|chmod|/tmp/|eval\(|base64)" {
        return 403;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}
NGXEOF

    # Активация
    ln -sf "$nginx_conf" /etc/nginx/sites-enabled/site
    rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-enabled/acme-temp

    if nginx -t >> "$LOG_FILE" 2>&1; then
        systemctl restart nginx >> "$LOG_FILE" 2>&1
        rollback_push "rm -f '${nginx_conf}' /etc/nginx/sites-enabled/site; systemctl restart nginx 2>/dev/null"
        msg_ok "Nginx настроен (3 блока: default-drop, ACME+redirect, SSL-site)"
    else
        msg_err "Ошибка конфигурации Nginx"
        msg_info "Проверьте: nginx -t"
        return 1
    fi

    # Открыть 80 и 443 в firewall
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow 80/tcp >> "$LOG_FILE" 2>&1
        ufw allow 443/tcp >> "$LOG_FILE" 2>&1
        msg_ok "UFW: порты 80, 443 открыты"
    fi
}

# ══════════════════════════════════════════════════════════════════
#  Шаг 6: Обновление конфига telemt для selfmask
# ══════════════════════════════════════════════════════════════════
sitemask_update_telemt_config() {
    msg_step "Настройка telemt для selfmask"

    local cfg
    cfg=$(_opt_detect_config 2>/dev/null || echo "${TELEMT_CONFIG:-/etc/telemt/telemt.toml}")

    if [[ ! -f "$cfg" ]]; then
        msg_warn "Конфиг telemt не найден (${cfg})"
        msg_info "Убедитесь, что telemt установлен, и добавьте вручную:"
        echo ""
        echo "  [server]"
        echo "  port = 443"
        echo ""
        echo "  [censorship]"
        echo "  tls_domain = \"${MASK_DOMAIN}\""
        echo "  mask = true"
        echo "  mask_port = ${MASK_NGINX_BACKEND_PORT}"
        return 0
    fi

    # Бэкап
    mkdir -p /opt/telemt/backups
    cp "$cfg" "/opt/telemt/backups/$(basename "$cfg").pre-mask.$(date +%s)"

    # Установить порт 443
    sed -i 's/^port[[:space:]]*=.*/port = 443/' "$cfg"

    # tls_domain → наш домен
    if grep -q '^tls_domain' "$cfg"; then
        sed -i "s|^tls_domain[[:space:]]*=.*|tls_domain = \"${MASK_DOMAIN}\"|" "$cfg"
    else
        sed -i "/\[censorship\]/a tls_domain = \"${MASK_DOMAIN}\"" "$cfg" 2>/dev/null || \
            echo -e "\n[censorship]\ntls_domain = \"${MASK_DOMAIN}\"" >> "$cfg"
    fi

    # mask = true
    if grep -q '^mask[[:space:]]*=' "$cfg"; then
        sed -i 's/^mask[[:space:]]*=.*/mask = true/' "$cfg"
    elif grep -q '\[censorship\]' "$cfg"; then
        sed -i '/\[censorship\]/a mask = true' "$cfg"
    fi

    # mask_port
    if grep -q '^mask_port' "$cfg"; then
        sed -i "s/^mask_port[[:space:]]*=.*/mask_port = ${MASK_NGINX_BACKEND_PORT}/" "$cfg"
    elif grep -q '\[censorship\]' "$cfg"; then
        sed -i "/\[censorship\]/a mask_port = ${MASK_NGINX_BACKEND_PORT}" "$cfg"
    fi

    # public_host
    if grep -q '# public_host' "$cfg"; then
        sed -i "s|# public_host.*|public_host = \"${MASK_DOMAIN}\"|" "$cfg"
    elif grep -q 'public_host' "$cfg"; then
        sed -i "s|public_host.*|public_host = \"${MASK_DOMAIN}\"|" "$cfg"
    fi

    # Перезапуск
    if systemctl is-active --quiet telemt 2>/dev/null; then
        run_with_spinner "Перезапуск telemt" systemctl restart telemt
    fi

    msg_ok "telemt настроен: порт 443, mask → nginx:${MASK_NGINX_BACKEND_PORT}"
}

# ══════════════════════════════════════════════════════════════════
#  Шаг 7: Автопродление сертификата
# ══════════════════════════════════════════════════════════════════
sitemask_setup_renewal() {
    msg_step "Автопродление сертификата"

    # certbot обычно ставит свой cron/timer автоматически
    if systemctl is-enabled certbot.timer &>/dev/null 2>&1; then
        msg_ok "certbot.timer уже активен — автопродление работает"
    elif [[ -f /etc/cron.d/certbot ]]; then
        msg_ok "certbot cron уже настроен"
    else
        # Ручной cron
        (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet --deploy-hook 'systemctl reload nginx'") | crontab -
        msg_ok "Cron для автопродления настроен (03:00 ежедневно)"
    fi
}

# ══════════════════════════════════════════════════════════════════
#  Главная точка входа
# ══════════════════════════════════════════════════════════════════
sitemask_setup() {
    sitemask_collect_params       || return 1
    sitemask_install_deps         || return 1
    sitemask_obtain_cert          || return 1
    sitemask_deploy_site          || return 1
    sitemask_configure_nginx      || return 1
    sitemask_update_telemt_config || return 1
    sitemask_setup_renewal        || true

    echo ""
    draw_info_box 62 \
        "${C_BOLD}Selfmask настроен${C_RESET}" \
        "" \
        "Домен:   ${C_WHITE}https://${MASK_DOMAIN}${C_RESET}" \
        "Сайт:    ${C_WHITE}${MASK_SITE_DIR}${C_RESET}" \
        "Серт:    ${C_WHITE}Let's Encrypt (авто)${C_RESET}" \
        "telemt:  ${C_WHITE}:443 → mask → nginx:${MASK_NGINX_BACKEND_PORT}${C_RESET}"

    msg_ok "Selfmask настройка завершена"
}
