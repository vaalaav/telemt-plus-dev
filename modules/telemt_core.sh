#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  modules/telemt_core.sh — Установка telemt, настройка, привязка домена
# ═══════════════════════════════════════════════════════════════════

# ── Константы модуля ──────────────────────────────────────────────
TELEMT_REPO="telemt/telemt"
TELEMT_BIN="/bin/telemt"
TELEMT_CONFIG_DIR="/etc/telemt"
TELEMT_CONFIG="${TELEMT_CONFIG_DIR}/telemt.toml"
TELEMT_WORK_DIR="/opt/telemt"
TELEMT_SERVICE="telemt"
TELEMT_SERVICE_FILE="/etc/systemd/system/${TELEMT_SERVICE}.service"
TELEMT_USER="telemt"
TELEMT_GROUP="telemt"

# Пользовательские параметры (заполняются интерактивно)
TELEMT_PORT=""
TELEMT_TLS_DOMAIN=""
TELEMT_SECRET=""
TELEMT_AD_TAG=""
TELEMT_PUBLIC_HOST=""

# ── Определение архитектуры ───────────────────────────────────────
_detect_arch() {
    local arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64)  echo "x86_64" ;;
        aarch64) echo "aarch64" ;;
        armv7l)  echo "armv7" ;;
        *)
            msg_err "Неподдерживаемая архитектура: ${arch}"
            return 1
            ;;
    esac
}

# Определение libc (gnu vs musl)
_detect_libc() {
    if ldd --version 2>&1 | grep -qi musl; then
        echo "musl"
    else
        echo "gnu"
    fi
}

# ── Получение публичного IP ───────────────────────────────────────
_get_public_ipv4() {
    local ip=""
    local services=("ifconfig.me" "api.ipify.org" "icanhazip.com" "ipecho.net/plain")
    for svc in "${services[@]}"; do
        ip=$(curl -4 -s --max-time 5 "$svc" 2>/dev/null | tr -d '[:space:]')
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    msg_warn "Не удалось определить публичный IPv4"
    echo "0.0.0.0"
}

# ── Генерация секрета ─────────────────────────────────────────────
_generate_secret() {
    local secret=""
    if command -v openssl &>/dev/null; then
        secret=$(openssl rand -hex 16 2>/dev/null)
    elif [[ -r /dev/urandom ]]; then
        secret=$(xxd -l 16 -p /dev/urandom 2>/dev/null)
    fi
    if [[ -z "$secret" ]]; then
        secret=$(python3 -c 'import os; print(os.urandom(16).hex())' 2>/dev/null)
    fi
    if [[ ${#secret} -ne 32 ]]; then
        msg_err "Не удалось сгенерировать секрет"
        return 1
    fi
    echo "$secret"
}

# ── Проверка доступности порта ────────────────────────────────────
_check_port_free() {
    local port="$1"
    if command -v ss &>/dev/null; then
        if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
            # Проверить: если это сам telemt — ок (будет перезапущен)
            if ss -tlnp 2>/dev/null | grep ":${port} " | grep -qi telemt; then
                return 0
            fi
            msg_err "Порт ${port} уже занят другим процессом:"
            ss -tlnp 2>/dev/null | grep ":${port} " | head -3
            return 1
        fi
    elif command -v netstat &>/dev/null; then
        if netstat -tlnp 2>/dev/null | grep -q ":${port} "; then
            if netstat -tlnp 2>/dev/null | grep ":${port} " | grep -qi telemt; then
                return 0
            fi
            msg_err "Порт ${port} уже занят"
            return 1
        fi
    fi
    return 0
}

# ══════════════════════════════════════════════════════════════════
#  Шаг 1: Сбор параметров
# ══════════════════════════════════════════════════════════════════
telemt_collect_params() {
    msg_header "Параметры установки telemt"

    # Порт
    while true; do
        prompt_input "Порт прокси (1-65535)" TELEMT_PORT '^[0-9]+$' "443"
        if (( TELEMT_PORT < 1 || TELEMT_PORT > 65535 )); then
            msg_warn "Порт должен быть от 1 до 65535"
            continue
        fi
        if _check_port_free "$TELEMT_PORT"; then
            break
        fi
        msg_warn "Выберите другой порт или освободите текущий"
    done

    # TLS-домен маскировки
    prompt_input "Домен TLS-маскировки" TELEMT_TLS_DOMAIN '^[a-zA-Z0-9._-]+\.[a-zA-Z]{2,}$' "petrovich.ru"

    # Секрет
    msg_info "Генерация секрета..."
    TELEMT_SECRET=$(_generate_secret) || return 1
    msg_ok "Секрет сгенерирован: ${C_DIM}${TELEMT_SECRET}${C_RESET}"

    # Ad-tag (опционально)
    if confirm_yn "Добавить ad_tag (монетизация через @MTProxybot)?" "n"; then
        prompt_input "Ad-tag (32 hex-символа)" TELEMT_AD_TAG '^[0-9a-fA-F]{32}$'
    fi

    # Итог
    local ip; ip=$(_get_public_ipv4)
    echo ""
    draw_info_box 60 \
        "Порт:       ${C_WHITE}${TELEMT_PORT}${C_RESET}" \
        "TLS-домен:  ${C_WHITE}${TELEMT_TLS_DOMAIN}${C_RESET}" \
        "Секрет:     ${C_WHITE}${TELEMT_SECRET}${C_RESET}" \
        "Сервер IP:  ${C_WHITE}${ip}${C_RESET}" \
        "Ad-tag:     ${C_WHITE}${TELEMT_AD_TAG:-не задан}${C_RESET}"

    confirm_yn "Всё верно? Начать установку?" "y" || return 1
}

# ══════════════════════════════════════════════════════════════════
#  Шаг 2: Скачивание бинарника
# ══════════════════════════════════════════════════════════════════
telemt_download() {
    msg_step "Скачивание telemt"

    local arch libc
    arch=$(_detect_arch) || return 1
    libc=$(_detect_libc)

    local url="https://github.com/${TELEMT_REPO}/releases/latest/download/telemt-${arch}-linux-${libc}.tar.gz"
    local tmp_dir
    tmp_dir=$(mktemp -d) || { msg_err "Не удалось создать временную директорию"; return 1; }

    msg_info "Архитектура: ${arch}, libc: ${libc}"
    msg_info "URL: ${url}"

    if ! run_with_spinner "Скачивание бинарника" curl -fSL --max-time 120 -o "${tmp_dir}/telemt.tar.gz" "$url"; then
        # Попробовать fallback для x86_64 без суффикса v3
        if [[ "$arch" == "x86_64" ]]; then
            msg_warn "Основная ссылка недоступна, пробуем альтернативную..."
            url="https://github.com/${TELEMT_REPO}/releases/latest/download/telemt-x86_64-linux-gnu.tar.gz"
            run_with_spinner "Скачивание (fallback)" curl -fSL --max-time 120 -o "${tmp_dir}/telemt.tar.gz" "$url" || {
                rm -rf "$tmp_dir"
                return 1
            }
        else
            rm -rf "$tmp_dir"
            return 1
        fi
    fi

    # Распаковка
    msg_info "Распаковка..."
    if ! tar -xzf "${tmp_dir}/telemt.tar.gz" -C "$tmp_dir" 2>>"$LOG_FILE"; then
        msg_err "Ошибка распаковки архива"
        rm -rf "$tmp_dir"
        return 1
    fi

    # Поиск бинарника в распакованном архиве
    local bin_path
    bin_path=$(find "$tmp_dir" -name "telemt" -type f ! -name "*.tar.gz" | head -1)
    if [[ -z "$bin_path" ]]; then
        msg_err "Бинарник telemt не найден в архиве"
        rm -rf "$tmp_dir"
        return 1
    fi

    # Установка в /bin
    install -m 0755 "$bin_path" "$TELEMT_BIN" || {
        msg_err "Не удалось установить бинарник в ${TELEMT_BIN}"
        rm -rf "$tmp_dir"
        return 1
    }

    rm -rf "$tmp_dir"
    rollback_push "rm -f '${TELEMT_BIN}'"
    msg_ok "telemt установлен в ${TELEMT_BIN}"

    # Проверка
    if "${TELEMT_BIN}" --version >> "$LOG_FILE" 2>&1; then
        local ver
        ver=$("${TELEMT_BIN}" --version 2>/dev/null | head -1)
        msg_ok "Версия: ${ver}"
    else
        msg_warn "Не удалось получить версию (бинарник может работать без --version)"
    fi
}

# ══════════════════════════════════════════════════════════════════
#  Шаг 3: Создание пользователя и директорий
# ══════════════════════════════════════════════════════════════════
telemt_setup_env() {
    msg_step "Настройка окружения"

    # Создание группы и пользователя
    if ! getent group "$TELEMT_GROUP" &>/dev/null; then
        groupadd -r "$TELEMT_GROUP" || { msg_err "Не удалось создать группу ${TELEMT_GROUP}"; return 1; }
        rollback_push "groupdel '${TELEMT_GROUP}' 2>/dev/null || true"
        msg_ok "Группа ${TELEMT_GROUP} создана"
    else
        msg_info "Группа ${TELEMT_GROUP} уже существует"
    fi

    if ! id -u "$TELEMT_USER" &>/dev/null; then
        useradd -d "$TELEMT_WORK_DIR" -m -r -g "$TELEMT_GROUP" -s /usr/sbin/nologin "$TELEMT_USER" || {
            msg_err "Не удалось создать пользователя ${TELEMT_USER}"
            return 1
        }
        rollback_push "userdel -r '${TELEMT_USER}' 2>/dev/null || true"
        msg_ok "Пользователь ${TELEMT_USER} создан"
    else
        msg_info "Пользователь ${TELEMT_USER} уже существует"
    fi

    # Директории
    mkdir -p "$TELEMT_CONFIG_DIR" "$TELEMT_WORK_DIR"
    chown -R "${TELEMT_USER}:${TELEMT_GROUP}" "$TELEMT_CONFIG_DIR" "$TELEMT_WORK_DIR"
    msg_ok "Директории созданы: ${TELEMT_CONFIG_DIR}, ${TELEMT_WORK_DIR}"
}

# ══════════════════════════════════════════════════════════════════
#  Шаг 4: Генерация конфигурации
# ══════════════════════════════════════════════════════════════════
telemt_generate_config() {
    msg_step "Генерация конфигурации"

    local ad_tag_line=""
    if [[ -n "${TELEMT_AD_TAG:-}" ]]; then
        ad_tag_line="ad_tag = \"${TELEMT_AD_TAG}\""
    else
        ad_tag_line="# ad_tag = \"00000000000000000000000000000000\""
    fi

    local public_host_line=""
    if [[ -n "${TELEMT_PUBLIC_HOST:-}" ]]; then
        public_host_line="public_host = \"${TELEMT_PUBLIC_HOST}\""
    else
        public_host_line="# public_host = \"proxy.example.com\""
    fi

    # Бэкап существующего конфига
    if [[ -f "$TELEMT_CONFIG" ]]; then
        cp "$TELEMT_CONFIG" "${TELEMT_CONFIG}.bak.$(date +%s)"
        msg_info "Существующий конфиг сохранён в .bak"
    fi

    cat > "$TELEMT_CONFIG" << TOMLEOF
### telemt config — сгенерировано telemt VPS Installer v${INSTALLER_VERSION}
### $(date '+%Y-%m-%d %H:%M:%S')

# === Общие настройки ===
[general]
use_middle_proxy = true
${ad_tag_line}
log_level = "normal"

[general.modes]
classic = false
secure = false
tls = true

[general.links]
show = "*"
${public_host_line}
# public_port = ${TELEMT_PORT}

# === Сервер ===
[server]
port = ${TELEMT_PORT}

[server.api]
enabled = true
listen = "127.0.0.1:9091"
# whitelist = ["127.0.0.1/32"]

# === Маскировка / Анти-цензура ===
[censorship]
tls_domain = "${TELEMT_TLS_DOMAIN}"
# mask = true

# === Пользователи ===
[access.users]
hello = "${TELEMT_SECRET}"
TOMLEOF

    chown "${TELEMT_USER}:${TELEMT_GROUP}" "$TELEMT_CONFIG"
    chmod 640 "$TELEMT_CONFIG"

    rollback_push "rm -f '${TELEMT_CONFIG}'"
    msg_ok "Конфигурация записана в ${TELEMT_CONFIG}"
}

# ══════════════════════════════════════════════════════════════════
#  Шаг 5: Создание systemd-сервиса
# ══════════════════════════════════════════════════════════════════
telemt_create_service() {
    msg_step "Создание systemd-сервиса"

    cat > "$TELEMT_SERVICE_FILE" << SVCEOF
[Unit]
Description=Telemt MTProxy
After=network-online.target nginx.service
Wants=network-online.target
# В selfmask-режиме nginx ДОЛЖЕН быть запущен до telemt
# (TLS bootstrap скачивает сертификат с mask_port при старте)

[Service]
Type=simple
User=${TELEMT_USER}
Group=${TELEMT_GROUP}
WorkingDirectory=${TELEMT_WORK_DIR}
ExecStartPre=/bin/sleep 2
ExecStart=${TELEMT_BIN} ${TELEMT_CONFIG}
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true

# Защита (hardening)
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${TELEMT_WORK_DIR}
PrivateTmp=true
ProtectKernelTunables=true
ProtectControlGroups=true

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    rollback_push "systemctl stop ${TELEMT_SERVICE} 2>/dev/null; systemctl disable ${TELEMT_SERVICE} 2>/dev/null; rm -f '${TELEMT_SERVICE_FILE}'; systemctl daemon-reload"

    # Включение и запуск
    systemctl enable "$TELEMT_SERVICE" >> "$LOG_FILE" 2>&1
    msg_ok "Сервис включён (enable)"

    if systemctl start "$TELEMT_SERVICE" >> "$LOG_FILE" 2>&1; then
        sleep 2
        if systemctl is-active --quiet "$TELEMT_SERVICE"; then
            msg_ok "telemt запущен и работает"
        else
            msg_warn "Сервис стартовал, но статус неопределён"
            msg_info "Проверьте: journalctl -u ${TELEMT_SERVICE} -n 20"
        fi
    else
        msg_err "Не удалось запустить telemt"
        msg_info "Логи: journalctl -u ${TELEMT_SERVICE} -n 30 --no-pager"
        return 1
    fi
}

# ══════════════════════════════════════════════════════════════════
#  Шаг 6: Генерация и вывод прокси-ссылок
# ══════════════════════════════════════════════════════════════════
telemt_print_links() {
    msg_step "Прокси-ссылки"

    local ip host domain_hex full_secret link link_https
    ip=$(_get_public_ipv4)
    host="${TELEMT_PUBLIC_HOST:-$ip}"
    domain_hex=$(printf '%s' "${TELEMT_TLS_DOMAIN:-unknown}" | od -An -tx1 | tr -d ' \n')
    full_secret="ee${TELEMT_SECRET}${domain_hex}"

    link="tg://proxy?server=${host}&port=${TELEMT_PORT:-443}&secret=${full_secret}"
    link_https="https://t.me/proxy?server=${host}&port=${TELEMT_PORT:-443}&secret=${full_secret}"

    # Попробовать через API (самый надёжный способ)
    local api_url="http://127.0.0.1:9091/v1/users"
    local api_ok=false

    sleep 3  # подождать API

    local api_response
    api_response=$(curl -s --max-time 5 "$api_url" 2>/dev/null) || true

    if [[ -n "$api_response" ]] && echo "$api_response" | jq -e '.data' &>/dev/null 2>&1; then
        api_ok=true
        local api_link
        api_link=$(echo "$api_response" | jq -r '.data[].links.tls[]?' 2>/dev/null | head -1)
        if [[ -n "$api_link" ]]; then
            link_https="$api_link"
            link="$(echo "$api_link" | sed 's|https://t.me/proxy|tg://proxy|')"
        fi
        msg_info "Ссылки получены из API telemt"
    else
        msg_warn "API недоступен — ссылка сгенерирована вручную"
    fi

    # Вывод ссылок
    echo ""
    draw_info_box 70 \
        "${C_BOLD}Прокси-ссылки:${C_RESET}" \
        "" \
        "${C_CYAN}${link_https}${C_RESET}" \
        "" \
        "${C_DIM}${link}${C_RESET}"
    echo ""

    # Сохранить в файл
    mkdir -p "${TELEMT_WORK_DIR}" 2>/dev/null || true
    local links_file="${TELEMT_WORK_DIR}/proxy_links.txt"
    {
        echo "# telemt proxy links — $(date)"
        echo "# server: ${host}:${TELEMT_PORT:-443}"
        echo "# secret: ${TELEMT_SECRET}"
        echo "# tls_domain: ${TELEMT_TLS_DOMAIN}"
        echo "${link_https}"
        echo "${link}"
    } > "$links_file" 2>/dev/null || true
    chown "${TELEMT_USER}:${TELEMT_GROUP}" "$links_file" 2>/dev/null || true
    msg_ok "Ссылки сохранены в ${links_file}"
}

# ══════════════════════════════════════════════════════════════════
#  Привязка домена (вызывается отдельным шагом из main)
# ══════════════════════════════════════════════════════════════════
telemt_bind_domain() {
    msg_header "Привязка домена"

    msg_info "Если у вас есть домен, укажите его — он будет подставлен в прокси-ссылки"
    msg_info "вместо IP-адреса. DNS A-запись должна указывать на этот сервер."
    echo ""

    if ! confirm_yn "Привязать домен к прокси?" "n"; then
        msg_info "Пропущено — в ссылках будет использоваться IP"
        return 0
    fi

    prompt_input "Доменное имя (A-запись → этот сервер)" TELEMT_PUBLIC_HOST '^[a-zA-Z0-9._-]+\.[a-zA-Z]{2,}$'

    # Проверка DNS
    msg_info "Проверка DNS для ${TELEMT_PUBLIC_HOST}..."
    local resolved_ip server_ip
    server_ip=$(_get_public_ipv4)

    if command -v dig &>/dev/null; then
        resolved_ip=$(dig +short "$TELEMT_PUBLIC_HOST" A 2>/dev/null | head -1)
    elif command -v nslookup &>/dev/null; then
        resolved_ip=$(nslookup "$TELEMT_PUBLIC_HOST" 2>/dev/null | awk '/^Address:/{a=$2} END{print a}')
    elif command -v host &>/dev/null; then
        resolved_ip=$(host "$TELEMT_PUBLIC_HOST" 2>/dev/null | awk '/has address/{print $4; exit}')
    else
        msg_warn "Нет утилит DNS (dig/nslookup/host) — проверка пропущена"
        resolved_ip=""
    fi

    if [[ -n "$resolved_ip" ]]; then
        if [[ "$resolved_ip" == "$server_ip" ]]; then
            msg_ok "DNS подтверждён: ${TELEMT_PUBLIC_HOST} → ${resolved_ip}"
        else
            msg_warn "DNS указывает на ${resolved_ip}, а IP сервера: ${server_ip}"
            if ! confirm_yn "Продолжить несмотря на несоответствие?" "n"; then
                return 0
            fi
        fi
    else
        msg_warn "Не удалось проверить DNS — убедитесь, что A-запись настроена"
    fi

    # Обновить конфиг: вписать public_host
    if [[ -f "$TELEMT_CONFIG" ]]; then
        # Заменить строку public_host
        if grep -q '# public_host' "$TELEMT_CONFIG"; then
            sed -i "s|# public_host = .*|public_host = \"${TELEMT_PUBLIC_HOST}\"|" "$TELEMT_CONFIG"
        elif grep -q 'public_host' "$TELEMT_CONFIG"; then
            sed -i "s|public_host = .*|public_host = \"${TELEMT_PUBLIC_HOST}\"|" "$TELEMT_CONFIG"
        else
            # Добавить после [general.links]
            sed -i "/\[general\.links\]/a public_host = \"${TELEMT_PUBLIC_HOST}\"" "$TELEMT_CONFIG"
        fi
        msg_ok "public_host = ${TELEMT_PUBLIC_HOST} записан в конфиг"

        # Перезапуск
        if systemctl is-active --quiet "$TELEMT_SERVICE" 2>/dev/null; then
            run_with_spinner "Перезапуск telemt" systemctl restart "$TELEMT_SERVICE"
        fi
    fi

    # Обновить ссылки
    telemt_print_links
}

# ══════════════════════════════════════════════════════════════════
#  Главная точка входа: полная установка
# ══════════════════════════════════════════════════════════════════
telemt_install() {
    telemt_collect_params  || return 1
    telemt_download        || return 1
    telemt_setup_env       || return 1
    telemt_generate_config || return 1
    telemt_create_service  || return 1
    telemt_print_links
    msg_ok "Установка telemt завершена"
}
