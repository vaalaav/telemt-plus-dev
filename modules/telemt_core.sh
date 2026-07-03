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
TELEMT_VERSION=""

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

}

# ══════════════════════════════════════════════════════════════════
#  Шаг 2: Выбор версии и скачивание бинарника
# ══════════════════════════════════════════════════════════════════
_telemt_select_version() {
    msg_step "Выбор версии telemt"

    local api_url="https://api.github.com/repos/${TELEMT_REPO}/releases"
    local releases_json tags=()

    releases_json=$(curl -fsSL --max-time 10 "$api_url" 2>/dev/null) || {
        msg_warn "Не удалось получить список релизов — будет использована последняя"
        TELEMT_VERSION="latest"
        return 0
    }

    # Получить последние 5 тегов (jq → fallback на grep)
    if command -v jq &>/dev/null; then
        mapfile -t tags < <(echo "$releases_json" | jq -r '.[0:5][].tag_name' 2>/dev/null)
    else
        mapfile -t tags < <(echo "$releases_json" | grep -oP '"tag_name":\s*"\K[^"]+' | head -5)
    fi

    if [[ ${#tags[@]} -eq 0 ]]; then
        msg_warn "Список релизов пуст — будет использована последняя"
        TELEMT_VERSION="latest"
        return 0
    fi

    echo ""
    echo -e "  ${C_BOLD}Доступные версии telemt:${C_RESET}"
    echo -e "  ${C_DIM}───────────────────────${C_RESET}"
    local i
    for i in "${!tags[@]}"; do
        local label="${tags[$i]}"
        [[ $i -eq 0 ]] && label="${label} ${C_GREEN}(последняя)${C_RESET}"
        echo -e "    ${C_BOLD}[$((i+1))]${C_RESET} ${C_BOLD}${label}${C_RESET}"
    done

    local max=${#tags[@]}
    local choice=""
    while true; do
        echo -ne "  ${C_BOLD}Версия${C_RESET} [1-${max}, Enter=1]: "
        read -r choice </dev/tty || true
        choice="${choice:-1}"
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= max )); then
            break
        fi
        msg_warn "Неверный ввод. Введите число от ${C_BOLD}1${C_RESET} до ${C_BOLD}${max}${C_RESET}"
    done

    TELEMT_VERSION="${tags[$((choice-1))]}"
    msg_ok "Выбрана версия: ${C_BOLD}${TELEMT_VERSION}${C_RESET}"
}

telemt_download() {
    # Выбор версии
    _telemt_select_version

    msg_step "Скачивание telemt ${TELEMT_VERSION:-latest}"

    local arch libc
    arch=$(_detect_arch) || return 1
    libc=$(_detect_libc)

    # URL: конкретная версия или latest
    local url
    if [[ "${TELEMT_VERSION:-latest}" == "latest" ]]; then
        url="https://github.com/${TELEMT_REPO}/releases/latest/download/telemt-${arch}-linux-${libc}.tar.gz"
    else
        url="https://github.com/${TELEMT_REPO}/releases/download/${TELEMT_VERSION}/telemt-${arch}-linux-${libc}.tar.gz"
    fi

    local tmp_dir
    tmp_dir=$(mktemp -d) || { msg_err "Не удалось создать временную директорию"; return 1; }

    msg_info "Архитектура: ${arch}, libc: ${libc}"
    msg_info "URL: ${url}"

    if ! run_with_spinner "Скачивание бинарника" curl -fSL --max-time 120 -o "${tmp_dir}/telemt.tar.gz" "$url"; then
        if [[ "$arch" == "x86_64" ]]; then
            msg_warn "Основная ссылка недоступна, пробуем альтернативную..."
            if [[ "${TELEMT_VERSION:-latest}" == "latest" ]]; then
                url="https://github.com/${TELEMT_REPO}/releases/latest/download/telemt-x86_64-linux-gnu.tar.gz"
            else
                url="https://github.com/${TELEMT_REPO}/releases/download/${TELEMT_VERSION}/telemt-x86_64-linux-gnu.tar.gz"
            fi
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

    # Установить CLI-утилиту mytelemtinfo
    local info_src="${MODULES_DIR}/mytelemtinfo"
    if [[ -f "$info_src" ]]; then
        install -m 0755 "$info_src" /usr/local/bin/mytelemtinfo
        msg_ok "CLI-утилита: ${C_BOLD}mytelemtinfo${C_RESET} доступна в терминале"
    fi

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

# ── Подтянуть секрет/домен/порт из реального конфига, если переменные
#    сессии пусты (актуально при отдельном запуске "Привязка домена"
#    без предшествующей telemt_collect_params в этом же процессе) ──
_telemt_load_state_from_config() {
    local cfg="${TELEMT_CONFIG:-/etc/telemt/telemt.toml}"
    [[ -f "$cfg" ]] || return 1

    if [[ -z "${TELEMT_SECRET:-}" ]]; then
        TELEMT_SECRET=$(grep -E '^[[:space:]]*hello[[:space:]]*=' "$cfg" | head -1 | sed -E 's/^[^=]+=[[:space:]]*"([^"]*)".*/\1/')
    fi
    if [[ -z "${TELEMT_TLS_DOMAIN:-}" ]]; then
        TELEMT_TLS_DOMAIN=$(grep -E '^[[:space:]]*tls_domain[[:space:]]*=' "$cfg" | head -1 | sed -E 's/^[^=]+=[[:space:]]*"([^"]*)".*/\1/')
    fi
    if [[ -z "${TELEMT_PORT:-}" ]]; then
        TELEMT_PORT=$(grep -E '^[[:space:]]*port[[:space:]]*=' "$cfg" | head -1 | awk -F'=' '{print $2}' | tr -d ' ')
    fi
    if [[ -z "${TELEMT_PUBLIC_HOST:-}" ]]; then
        TELEMT_PUBLIC_HOST=$(grep -E '^[[:space:]]*public_host[[:space:]]*=' "$cfg" | head -1 | sed -E 's/^[^=]+=[[:space:]]*"([^"]*)".*/\1/')
    fi
    return 0
}

# ══════════════════════════════════════════════════════════════════
#  Шаг 6: Генерация и вывод прокси-ссылок
# ══════════════════════════════════════════════════════════════════
telemt_print_links() {
    msg_step "Прокси-ссылки"

    # Восполнить недостающие переменные из конфига (если функция вызвана
    # отдельно от telemt_collect_params — напр. из telemt_bind_domain
    # в новом запуске скрипта)
    _telemt_load_state_from_config

    if [[ -z "${TELEMT_SECRET:-}" ]]; then
        msg_err "Не удалось определить секрет из ${TELEMT_CONFIG:-/etc/telemt/telemt.toml} — ссылка не будет сгенерирована"
        return 1
    fi
    if [[ -z "${TELEMT_TLS_DOMAIN:-}" ]]; then
        msg_warn "tls_domain не найден в конфиге — используется заглушка (проверьте конфиг вручную)"
    fi

    local ip host domain_hex full_secret link
    ip=$(_get_public_ipv4)
    host="${TELEMT_PUBLIC_HOST:-$ip}"
    domain_hex=$(printf '%s' "${TELEMT_TLS_DOMAIN:-unknown}" | od -An -tx1 | tr -d ' \n')
    full_secret="ee${TELEMT_SECRET}${domain_hex}"

    link=""

    # Попробовать через API
    local api_url="http://127.0.0.1:9091/v1/users"
    sleep 3

    local api_response
    api_response=$(curl -s --max-time 5 "$api_url" 2>/dev/null) || true

    if [[ -n "$api_response" ]] && echo "$api_response" | jq -e '.data' &>/dev/null 2>&1; then
        link=$(echo "$api_response" | jq -r '.data[].links.tls[]?' 2>/dev/null | head -1)
        # API может вернуть tg:// или https:// — унифицируем в tg://
        link=$(echo "$link" | sed 's|https://t.me/proxy|tg://proxy|')
        msg_info "Ссылка получена из API telemt"
    fi

    # Если API не вернул или ссылка пустая — строим вручную
    if [[ -z "$link" || "$link" == "null" ]]; then
        link="tg://proxy?server=${host}&port=${TELEMT_PORT:-443}&secret=${full_secret}"
        msg_info "Ссылка сгенерирована вручную"
    fi

    # Подставить реальный IP вместо 0.0.0.0
    link=$(echo "$link" | sed "s/server=0\.0\.0\.0/server=${host}/")

    # Вывод
    echo ""
    draw_info_box 70 \
        "${C_BOLD}Прокси-ссылка:${C_RESET}" \
        "" \
        "${C_CYAN}${link}${C_RESET}"
    echo ""

    # Сохранить в файл
    mkdir -p "${TELEMT_WORK_DIR}" 2>/dev/null || true
    local links_file="${TELEMT_WORK_DIR}/proxy_links.txt"
    {
        echo "# telemt proxy links — $(date)"
        echo "# server: ${host}:${TELEMT_PORT:-443}"
        echo "# secret: ${TELEMT_SECRET}"
        echo "# tls_domain: ${TELEMT_TLS_DOMAIN}"
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

    echo -ne "  ${C_BOLD}Домен для прокси-ссылок (Enter = пропустить):${C_RESET} "
    local domain=""
    read -r domain </dev/tty || true

    if [[ -z "$domain" ]]; then
        msg_info "Пропущено — в ссылках будет IP-адрес"
        return 0
    fi

    TELEMT_PUBLIC_HOST="$domain"

    # Проверка DNS
    msg_info "Проверка DNS для ${TELEMT_PUBLIC_HOST}..."
    local resolved_ip="" server_ip=""
    server_ip=$(_get_public_ipv4)

    if command -v dig &>/dev/null; then
        resolved_ip=$(dig +short "$TELEMT_PUBLIC_HOST" A 2>/dev/null | head -1)
    elif command -v nslookup &>/dev/null; then
        resolved_ip=$(nslookup "$TELEMT_PUBLIC_HOST" 2>/dev/null | awk '/^Address:/{a=$2} END{print a}')
    elif command -v host &>/dev/null; then
        resolved_ip=$(host "$TELEMT_PUBLIC_HOST" 2>/dev/null | awk '/has address/{print $4; exit}')
    fi

    if [[ -n "$resolved_ip" ]]; then
        if [[ "$resolved_ip" == "$server_ip" ]]; then
            msg_ok "DNS: ${TELEMT_PUBLIC_HOST} → ${resolved_ip}"
        else
            # DNS не совпадает — цикл: повторить / отменить / продолжить
            while true; do
                msg_warn "DNS: ${resolved_ip}, ожидался ${server_ip}"
                echo -e "    ${C_BOLD}[1]${C_RESET} Повторить проверку DNS"
                echo -e "    ${C_BOLD}[2]${C_RESET} Отменить привязку домена"
                echo -e "    ${C_BOLD}[3]${C_RESET} Привязать несмотря на несовпадение"
                local dns_choice=""
                while true; do
                    echo -ne "  ${C_BOLD}Выбор${C_RESET} [1/2/3]: "
                    read -r dns_choice </dev/tty || true
                    case "$dns_choice" in 1|2|3) break ;; *) msg_warn "Введите 1, 2 или 3" ;; esac
                done

                if [[ "$dns_choice" == "2" ]]; then
                    msg_info "Привязка отменена — в ссылках будет IP-адрес"
                    return 0
                elif [[ "$dns_choice" == "3" ]]; then
                    msg_info "Привязываем ${TELEMT_PUBLIC_HOST} несмотря на DNS"
                    break
                else
                    # Повторная проверка
                    msg_info "Повторная проверка DNS..."
                    resolved_ip=""
                    if command -v dig &>/dev/null; then
                        resolved_ip=$(dig +short "$TELEMT_PUBLIC_HOST" A 2>/dev/null | head -1)
                    elif command -v nslookup &>/dev/null; then
                        resolved_ip=$(nslookup "$TELEMT_PUBLIC_HOST" 2>/dev/null | awk '/^Address:/{a=$2} END{print a}')
                    elif command -v host &>/dev/null; then
                        resolved_ip=$(host "$TELEMT_PUBLIC_HOST" 2>/dev/null | awk '/has address/{print $4; exit}')
                    fi
                    if [[ "$resolved_ip" == "$server_ip" ]]; then
                        msg_ok "DNS: ${TELEMT_PUBLIC_HOST} → ${resolved_ip}"
                        break
                    fi
                fi
            done
        fi
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
