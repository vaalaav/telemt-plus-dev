#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  modules/panel.sh — Установка и настройка telemt_panel
#  https://github.com/amirotin/telemt_panel
# ═══════════════════════════════════════════════════════════════════

# ── Константы ─────────────────────────────────────────────────────
PANEL_REPO="amirotin/telemt_panel"
PANEL_BIN="/usr/local/bin/telemt-panel"
PANEL_CONFIG_DIR="/etc/telemt-panel"
PANEL_CONFIG="${PANEL_CONFIG_DIR}/config.toml"
PANEL_DATA_DIR="/var/lib/telemt-panel"
PANEL_SERVICE="telemt-panel"
PANEL_SERVICE_FILE="/etc/systemd/system/${PANEL_SERVICE}.service"
PANEL_USER="telemt-panel"
PANEL_DEFAULT_PORT="8080"
PANEL_LISTEN=""
PANEL_ADMIN_USER="admin"
PANEL_ADMIN_PASS=""
PANEL_ADMIN_HASH=""
PANEL_JWT_SECRET=""
PANEL_NGINX_ENABLED=false
PANEL_NGINX_DOMAIN=""

# ── Определение архитектуры ───────────────────────────────────────
_panel_detect_arch() {
    case "$(uname -m)" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        armv7l)  echo "armv7" ;;
        *) msg_err "Неподдерживаемая архитектура: $(uname -m)"; return 1 ;;
    esac
}

# ── Генерация пароля ──────────────────────────────────────────────
_panel_generate_password() {
    openssl rand -base64 16 2>/dev/null | tr -d '/+=' | head -c 16
}

# ══════════════════════════════════════════════════════════════════
#  Шаг 1: Сбор параметров панели
# ══════════════════════════════════════════════════════════════════
panel_collect_params() {
    msg_header "Параметры telemt_panel"

    # Порт
    prompt_input "Порт панели (внутренний)" PANEL_DEFAULT_PORT '^[0-9]+$' "8080"
    PANEL_LISTEN="127.0.0.1:${PANEL_DEFAULT_PORT}"

    # Логин
    prompt_input "Имя администратора" PANEL_ADMIN_USER '^[a-zA-Z0-9_-]+$' "admin"

    # Пароль
    PANEL_ADMIN_PASS=$(_panel_generate_password)
    msg_info "Сгенерирован пароль: ${C_BOLD}${PANEL_ADMIN_PASS}${C_RESET}"
    if confirm_yn "Задать свой пароль вместо сгенерированного?" "n"; then
        prompt_secret "Пароль администратора" PANEL_ADMIN_PASS || return 1
    fi

    # JWT secret
    PANEL_JWT_SECRET=$(openssl rand -hex 32 2>/dev/null)

    # Nginx reverse proxy
    if confirm_yn "Настроить Nginx reverse proxy для панели?" "n"; then
        PANEL_NGINX_ENABLED=true
        prompt_input "Домен для панели (или оставить IP)" PANEL_NGINX_DOMAIN '^[a-zA-Z0-9._-]+$' ""
    fi

    # Итог
    echo ""
    draw_info_box 60 \
        "Панель:   ${C_WHITE}telemt_panel${C_RESET}" \
        "Listen:   ${C_WHITE}${PANEL_LISTEN}${C_RESET}" \
        "Логин:    ${C_WHITE}${PANEL_ADMIN_USER}${C_RESET}" \
        "Пароль:   ${C_WHITE}${PANEL_ADMIN_PASS}${C_RESET}" \
        "Nginx:    ${C_WHITE}${PANEL_NGINX_ENABLED}${C_RESET}"

    msg_warn "Запомните пароль — он понадобится для входа!"
}

# ══════════════════════════════════════════════════════════════════
#  Шаг 2: Скачивание бинарника панели
# ══════════════════════════════════════════════════════════════════
panel_download() {
    msg_step "Скачивание telemt_panel"

    local arch
    arch=$(_panel_detect_arch) || return 1
    local os="linux"

    # Получить URL последнего релиза
    local api_url="https://api.github.com/repos/${PANEL_REPO}/releases/latest"
    local release_json
    release_json=$(curl -fsSL "$api_url" 2>/dev/null) || {
        msg_err "Не удалось получить информацию о релизах"
        return 1
    }

    # Найти URL бинарника для нашей архитектуры
    local download_url
    download_url=$(echo "$release_json" | jq -r \
        ".assets[] | select(.name | test(\"${os}.*${arch}\")) | .browser_download_url" \
        2>/dev/null | head -1)

    if [[ -z "$download_url" || "$download_url" == "null" ]]; then
        # Попробовать альтернативный паттерн
        download_url=$(echo "$release_json" | jq -r \
            ".assets[] | select(.name | test(\"${arch}\") and test(\"${os}\")) | .browser_download_url" \
            2>/dev/null | head -1)
    fi

    if [[ -z "$download_url" || "$download_url" == "null" ]]; then
        msg_err "Не найден бинарник для ${os}/${arch}"
        msg_info "Доступные assets:"
        echo "$release_json" | jq -r '.assets[].name' 2>/dev/null | head -10
        return 1
    fi

    local version
    version=$(echo "$release_json" | jq -r '.tag_name' 2>/dev/null)
    msg_info "Версия: ${version}, архитектура: ${arch}"
    msg_info "URL: ${download_url}"

    local tmp_dir
    tmp_dir=$(mktemp -d)

    if ! run_with_spinner "Скачивание панели" curl -fSL --max-time 120 -o "${tmp_dir}/panel_archive" "$download_url"; then
        rm -rf "$tmp_dir"
        return 1
    fi

    # Определить тип файла и распаковать
    local file_type
    file_type=$(file -b "${tmp_dir}/panel_archive" 2>/dev/null)

    if echo "$file_type" | grep -qi "gzip\|tar"; then
        tar -xzf "${tmp_dir}/panel_archive" -C "$tmp_dir" 2>>"$LOG_FILE" || {
            msg_err "Ошибка распаковки"; rm -rf "$tmp_dir"; return 1
        }
    elif echo "$file_type" | grep -qi "zip"; then
        unzip -o "${tmp_dir}/panel_archive" -d "$tmp_dir" >> "$LOG_FILE" 2>&1 || {
            msg_err "Ошибка распаковки zip"; rm -rf "$tmp_dir"; return 1
        }
    elif echo "$file_type" | grep -qi "ELF\|executable"; then
        # Уже бинарник
        mv "${tmp_dir}/panel_archive" "${tmp_dir}/telemt-panel"
    fi

    # Найти бинарник
    local bin_path
    bin_path=$(find "$tmp_dir" -name "telemt-panel" -o -name "telemt_panel" | head -1)
    if [[ -z "$bin_path" ]]; then
        bin_path=$(find "$tmp_dir" -type f -executable ! -name "*.tar.gz" ! -name "*.zip" | head -1)
    fi

    if [[ -z "$bin_path" ]]; then
        msg_err "Бинарник панели не найден в архиве"
        rm -rf "$tmp_dir"
        return 1
    fi

    install -m 0755 "$bin_path" "$PANEL_BIN"
    rm -rf "$tmp_dir"
    rollback_push "rm -f '${PANEL_BIN}'"
    msg_ok "Панель установлена в ${PANEL_BIN}"
}

# ══════════════════════════════════════════════════════════════════
#  Шаг 3: Настройка пользователя и конфига
# ══════════════════════════════════════════════════════════════════
panel_setup() {
    msg_step "Настройка панели"

    # Системный пользователь
    if ! id -u "$PANEL_USER" &>/dev/null; then
        useradd --system --shell /usr/sbin/nologin --home /nonexistent "$PANEL_USER" 2>/dev/null || \
        adduser --system --shell /usr/sbin/nologin --home /nonexistent --disabled-password "$PANEL_USER" 2>/dev/null || {
            msg_err "Не удалось создать пользователя ${PANEL_USER}"
            return 1
        }
        rollback_push "userdel '${PANEL_USER}' 2>/dev/null || true"
        msg_ok "Пользователь ${PANEL_USER} создан"
    fi

    # Добавить в группу telemt для доступа к конфигу
    if getent group telemt &>/dev/null; then
        usermod -aG telemt "$PANEL_USER" 2>/dev/null || true
        msg_ok "${PANEL_USER} добавлен в группу telemt"
    fi

    # Директории
    mkdir -p "$PANEL_CONFIG_DIR" "$PANEL_DATA_DIR"
    chown "${PANEL_USER}:" "$PANEL_CONFIG_DIR" "$PANEL_DATA_DIR"
    chmod 700 "$PANEL_CONFIG_DIR"

    # Хеш пароля
    msg_info "Генерация хеша пароля..."
    PANEL_ADMIN_HASH=$("$PANEL_BIN" hash-password <<< "$PANEL_ADMIN_PASS" 2>/dev/null | tail -1)
    if [[ -z "$PANEL_ADMIN_HASH" ]]; then
        # Fallback: htpasswd / python
        if command -v htpasswd &>/dev/null; then
            PANEL_ADMIN_HASH=$(htpasswd -nbBC 10 "" "$PANEL_ADMIN_PASS" 2>/dev/null | cut -d: -f2)
        elif command -v python3 &>/dev/null; then
            PANEL_ADMIN_HASH=$(python3 -c "import bcrypt; print(bcrypt.hashpw(b'${PANEL_ADMIN_PASS}', bcrypt.gensalt(10)).decode())" 2>/dev/null)
        fi
    fi

    if [[ -z "$PANEL_ADMIN_HASH" ]]; then
        msg_warn "Не удалось сгенерировать хеш — используем plaintext (замените позже)"
        PANEL_ADMIN_HASH="REPLACE_WITH_HASH"
    fi

    # Определить URL API telemt
    local telemt_api_port="9091"
    local telemt_cfg
    telemt_cfg=$(_opt_detect_config 2>/dev/null || echo "")
    if [[ -n "$telemt_cfg" && -f "$telemt_cfg" ]]; then
        local api_listen
        api_listen=$(grep -E '^listen[[:space:]]*=' "$telemt_cfg" 2>/dev/null | tail -1 | awk -F'=' '{print $2}' | tr -d ' "')
        [[ -n "$api_listen" ]] && telemt_api_port=$(echo "$api_listen" | awk -F: '{print $NF}')
    fi

    # Генерация конфига
    cat > "$PANEL_CONFIG" << CFGEOF
# telemt_panel config — сгенерировано telemt VPS Installer
# $(date '+%Y-%m-%d %H:%M:%S')

listen = "${PANEL_LISTEN}"

[telemt]
url = "http://127.0.0.1:${telemt_api_port}"
# auth_header = ""

[auth]
username = "${PANEL_ADMIN_USER}"
password_hash = "${PANEL_ADMIN_HASH}"
jwt_secret = "${PANEL_JWT_SECRET}"
session_ttl = "24h"
CFGEOF

    chown "${PANEL_USER}:" "$PANEL_CONFIG"
    chmod 600 "$PANEL_CONFIG"
    rollback_push "rm -f '${PANEL_CONFIG}'"
    msg_ok "Конфиг панели создан"
}

# ══════════════════════════════════════════════════════════════════
#  Шаг 4: Systemd-сервис
# ══════════════════════════════════════════════════════════════════
panel_create_service() {
    msg_step "Создание systemd-сервиса панели"

    cat > "$PANEL_SERVICE_FILE" << SVCEOF
[Unit]
Description=Telemt Panel
After=network-online.target telemt.service
Wants=network-online.target

[Service]
Type=simple
User=${PANEL_USER}
ExecStart=${PANEL_BIN} -config ${PANEL_CONFIG}
Restart=on-failure
RestartSec=5

ProtectHome=true
PrivateTmp=true
ReadWritePaths=${PANEL_CONFIG_DIR} ${PANEL_DATA_DIR}

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    systemctl enable "$PANEL_SERVICE" >> "$LOG_FILE" 2>&1
    rollback_push "systemctl stop ${PANEL_SERVICE} 2>/dev/null; systemctl disable ${PANEL_SERVICE} 2>/dev/null; rm -f '${PANEL_SERVICE_FILE}'; systemctl daemon-reload"

    if systemctl start "$PANEL_SERVICE" >> "$LOG_FILE" 2>&1; then
        sleep 2
        if systemctl is-active --quiet "$PANEL_SERVICE"; then
            msg_ok "Панель запущена и работает"
        else
            msg_warn "Сервис стартовал, но статус неопределён"
        fi
    else
        msg_err "Не удалось запустить панель"
        msg_info "Логи: journalctl -u ${PANEL_SERVICE} -n 30 --no-pager"
        return 1
    fi
}

# ══════════════════════════════════════════════════════════════════
#  Шаг 5: Nginx reverse proxy (опционально)
# ══════════════════════════════════════════════════════════════════
panel_setup_nginx() {
    if [[ "$PANEL_NGINX_ENABLED" != "true" ]]; then
        msg_info "Nginx не настраивается — панель доступна на ${PANEL_LISTEN}"
        return 0
    fi

    msg_step "Настройка Nginx reverse proxy для панели"

    # Установка nginx
    if ! command -v nginx &>/dev/null; then
        run_with_spinner "Установка Nginx" apt-get install -y -qq nginx || {
            msg_err "Не удалось установить nginx"
            return 1
        }
        rollback_push "apt-get remove -y nginx >> '${LOG_FILE}' 2>&1 || true"
    fi

    local server_name="${PANEL_NGINX_DOMAIN:-_}"
    local nginx_conf="/etc/nginx/sites-available/telemt-panel"

    # Генерация рандомного пути для дополнительной безопасности
    local secret_path
    secret_path=$(openssl rand -hex 8 2>/dev/null)

    cat > "$nginx_conf" << NGXEOF
# Nginx reverse proxy для telemt_panel
# Сгенерировано telemt VPS Installer

server {
    listen 8443;
    server_name ${server_name};

    # Безопасность
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options DENY always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy no-referrer always;

    location / {
        proxy_pass http://${PANEL_LISTEN};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_connect_timeout 10s;
        proxy_read_timeout 300s;
    }

    # Запрет доступа к скрытым файлам
    location ~ /\. {
        deny all;
    }
}
NGXEOF

    # Активация
    ln -sf "$nginx_conf" /etc/nginx/sites-enabled/telemt-panel 2>/dev/null || true

    # Проверка конфига
    if nginx -t >> "$LOG_FILE" 2>&1; then
        systemctl reload nginx >> "$LOG_FILE" 2>&1
        rollback_push "rm -f '${nginx_conf}' /etc/nginx/sites-enabled/telemt-panel; nginx -t && systemctl reload nginx 2>/dev/null || true"
        msg_ok "Nginx настроен — панель доступна на порту 8443"

        # Открыть порт
        if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
            ufw allow 8443/tcp >> "$LOG_FILE" 2>&1
            rollback_push "ufw delete allow 8443/tcp 2>/dev/null || true"
        fi
    else
        msg_err "Ошибка конфигурации Nginx — проверьте вручную"
        rm -f "$nginx_conf" /etc/nginx/sites-enabled/telemt-panel
        return 1
    fi
}

# ══════════════════════════════════════════════════════════════════
#  Итоговый вывод
# ══════════════════════════════════════════════════════════════════
panel_print_summary() {
    msg_step "Данные для входа в панель"

    local access_url
    if [[ "$PANEL_NGINX_ENABLED" == "true" ]]; then
        local ip; ip=$(_get_public_ipv4 2>/dev/null || curl -4s ifconfig.me 2>/dev/null || echo "YOUR_IP")
        access_url="http://${PANEL_NGINX_DOMAIN:-${ip}}:8443"
    else
        access_url="http://127.0.0.1:${PANEL_DEFAULT_PORT} (только локально / через SSH-туннель)"
    fi

    echo ""
    draw_info_box 62 \
        "${C_BOLD}telemt_panel — данные доступа${C_RESET}" \
        "" \
        "URL:      ${C_WHITE}${access_url}${C_RESET}" \
        "Логин:    ${C_WHITE}${PANEL_ADMIN_USER}${C_RESET}" \
        "Пароль:   ${C_WHITE}${PANEL_ADMIN_PASS}${C_RESET}" \
        "" \
        "${C_YELLOW}Сохраните эти данные!${C_RESET}"

    # Сохранить в файл
    local creds_file="${PANEL_DATA_DIR}/credentials.txt"
    {
        echo "# telemt_panel credentials — $(date)"
        echo "URL: ${access_url}"
        echo "Username: ${PANEL_ADMIN_USER}"
        echo "Password: ${PANEL_ADMIN_PASS}"
    } > "$creds_file"
    chmod 600 "$creds_file"
    chown "${PANEL_USER}:" "$creds_file" 2>/dev/null || true
    msg_info "Данные сохранены в ${creds_file}"
}

# ══════════════════════════════════════════════════════════════════
#  Главная точка входа
# ══════════════════════════════════════════════════════════════════
panel_install() {
    panel_collect_params  || return 1
    panel_download        || return 1
    panel_setup           || return 1
    panel_create_service  || return 1
    panel_setup_nginx     || true  # не критично
    panel_print_summary
    msg_ok "Установка telemt_panel завершена"
}
