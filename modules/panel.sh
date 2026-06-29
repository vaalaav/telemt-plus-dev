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
PANEL_PORT="8080"
PANEL_LISTEN=""
PANEL_ADMIN_USER="admin"
PANEL_ADMIN_PASS=""
PANEL_ADMIN_HASH=""
PANEL_JWT_SECRET=""

# ── Определение архитектуры ───────────────────────────────────────
_panel_detect_arch() {
    case "$(uname -m)" in
        x86_64)  echo "x86_64" ;;
        aarch64) echo "arm64" ;;
        armv7l)  echo "armv7" ;;
        *) msg_err "Неподдерживаемая архитектура: $(uname -m)"; return 1 ;;
    esac
}

# ══════════════════════════════════════════════════════════════════
#  Главная точка входа
#  Вызывается из main.sh после confirm_yn на уровне сценария
# ══════════════════════════════════════════════════════════════════
panel_install() {
    msg_header "Установка telemt_panel"

    # ── Сбор данных (прямой ввод, без подтверждений) ──────────────
    prompt_input "Порт панели" PANEL_PORT '^[0-9]+$' "8080"
    PANEL_LISTEN="127.0.0.1:${PANEL_PORT}"

    prompt_input "Имя администратора" PANEL_ADMIN_USER '^[a-zA-Z0-9_-]+$' "admin"

    # Пароль — скрытый ввод, или автогенерация по Enter
    echo -ne "  ${C_BOLD}Пароль администратора (Enter = сгенерировать):${C_RESET} "
    local pass_input=""
    read -rs pass_input </dev/tty || true
    echo
    if [[ -n "$pass_input" ]]; then
        PANEL_ADMIN_PASS="$pass_input"
    else
        PANEL_ADMIN_PASS=$(openssl rand -base64 16 2>/dev/null | tr -d '/+=' | head -c 16)
        msg_info "Сгенерирован пароль: ${C_BOLD}${PANEL_ADMIN_PASS}${C_RESET}"
    fi

    PANEL_JWT_SECRET=$(openssl rand -hex 32 2>/dev/null)

    # ── Скачивание бинарника ──────────────────────────────────────
    msg_step "Скачивание telemt_panel"

    local arch
    arch=$(_panel_detect_arch) || return 1

    local api_url="https://api.github.com/repos/${PANEL_REPO}/releases/latest"
    local release_json
    release_json=$(curl -fsSL "$api_url" 2>/dev/null) || {
        msg_err "Не удалось получить информацию о релизах"
        return 1
    }

    # Найти tar.gz бинарник для нашей архитектуры + libc
    local download_url libc
    libc=$(_detect_libc 2>/dev/null || echo "gnu")

    download_url=$(echo "$release_json" | jq -r \
        ".assets[] | select(.name | test(\"${arch}\") and test(\"${libc}\") and test(\"tar.gz\")) | .browser_download_url" \
        2>/dev/null | head -1)

    if [[ -z "$download_url" || "$download_url" == "null" ]]; then
        # Fallback — любой tar.gz с архитектурой
        download_url=$(echo "$release_json" | jq -r \
            ".assets[] | select(.name | test(\"${arch}\") and test(\"tar.gz\")) | .browser_download_url" \
            2>/dev/null | head -1)
    fi

    if [[ -z "$download_url" || "$download_url" == "null" ]]; then
        msg_err "Бинарник для linux/${arch} не найден"
        echo "$release_json" | jq -r '.assets[].name' 2>/dev/null | head -10
        return 1
    fi

    local version
    version=$(echo "$release_json" | jq -r '.tag_name' 2>/dev/null)
    msg_info "Версия: ${version}, архитектура: ${arch}"

    local tmp_dir
    tmp_dir=$(mktemp -d)

    if ! run_with_spinner "Скачивание панели" curl -fSL --max-time 120 -o "${tmp_dir}/panel_archive" "$download_url"; then
        rm -rf "$tmp_dir"
        return 1
    fi

    # Распаковка
    local file_type
    file_type=$(file -b "${tmp_dir}/panel_archive" 2>/dev/null)

    if echo "$file_type" | grep -qi "gzip\|tar"; then
        tar -xzf "${tmp_dir}/panel_archive" -C "$tmp_dir" 2>>"$LOG_FILE" || {
            msg_err "Ошибка распаковки"; rm -rf "$tmp_dir"; return 1
        }
    elif echo "$file_type" | grep -qi "zip"; then
        unzip -o "${tmp_dir}/panel_archive" -d "$tmp_dir" >> "$LOG_FILE" 2>&1 || {
            msg_err "Ошибка распаковки"; rm -rf "$tmp_dir"; return 1
        }
    elif echo "$file_type" | grep -qi "ELF\|executable"; then
        mv "${tmp_dir}/panel_archive" "${tmp_dir}/telemt-panel"
    fi

    # Найти бинарник — гибкий поиск
    local bin_path

    # 1. Точное имя
    bin_path=$(find "$tmp_dir" -name "telemt-panel" -type f 2>/dev/null | head -1)

    # 2. С подчёркиванием
    [[ -z "$bin_path" ]] && bin_path=$(find "$tmp_dir" -name "telemt_panel" -type f 2>/dev/null | head -1)

    # 3. Любой файл с telemt-panel в имени (не .sha256, не .tar.gz)
    [[ -z "$bin_path" ]] && bin_path=$(find "$tmp_dir" -name "telemt-panel*" -type f \
        ! -name "*.sha256" ! -name "*.tar.gz" ! -name "*.zip" ! -name "*.md" 2>/dev/null | head -1)

    # 4. Любой ELF-бинарник
    if [[ -z "$bin_path" ]]; then
        local f
        for f in $(find "$tmp_dir" -type f 2>/dev/null); do
            if file -b "$f" 2>/dev/null | grep -qi "ELF"; then
                bin_path="$f"
                break
            fi
        done
    fi

    # 5. Любой исполняемый файл
    [[ -z "$bin_path" ]] && bin_path=$(find "$tmp_dir" -type f -executable \
        ! -name "*.tar.gz" ! -name "*.zip" ! -name "*.sha256" 2>/dev/null | head -1)

    # Отладка — что вообще в архиве
    if [[ -z "$bin_path" ]]; then
        msg_err "Бинарник панели не найден в архиве. Содержимое:"
        find "$tmp_dir" -type f 2>/dev/null | head -10 | while read -r f; do
            msg_info "  $(basename "$f") — $(file -b "$f" 2>/dev/null | head -c 60)"
        done
        rm -rf "$tmp_dir"
        return 1
    fi

    msg_info "Найден: $(basename "$bin_path")"

    install -m 0755 "$bin_path" "$PANEL_BIN"
    rm -rf "$tmp_dir"
    rollback_push "rm -f '${PANEL_BIN}'"
    msg_ok "Панель установлена: ${PANEL_BIN}"

    # ── Настройка пользователя и конфига ──────────────────────────
    msg_step "Настройка панели"

    # Системный пользователь
    if ! id -u "$PANEL_USER" &>/dev/null; then
        useradd --system --shell /usr/sbin/nologin --home /nonexistent "$PANEL_USER" 2>/dev/null || \
        adduser --system --shell /usr/sbin/nologin --home /nonexistent --disabled-password "$PANEL_USER" 2>/dev/null || {
            msg_err "Не удалось создать пользователя ${PANEL_USER}"
            return 1
        }
        rollback_push "userdel '${PANEL_USER}' 2>/dev/null || true"
    fi

    # Добавить в группу telemt
    if getent group telemt &>/dev/null; then
        usermod -aG telemt "$PANEL_USER" 2>/dev/null || true
    fi

    # Директории
    mkdir -p "$PANEL_CONFIG_DIR" "$PANEL_DATA_DIR"
    chown "${PANEL_USER}:" "$PANEL_CONFIG_DIR" "$PANEL_DATA_DIR"
    chmod 700 "$PANEL_CONFIG_DIR"

    # Хеш пароля
    PANEL_ADMIN_HASH=$("$PANEL_BIN" hash-password <<< "$PANEL_ADMIN_PASS" 2>/dev/null | tail -1)
    if [[ -z "$PANEL_ADMIN_HASH" ]]; then
        if command -v htpasswd &>/dev/null; then
            PANEL_ADMIN_HASH=$(htpasswd -nbBC 10 "" "$PANEL_ADMIN_PASS" 2>/dev/null | cut -d: -f2)
        elif command -v python3 &>/dev/null; then
            PANEL_ADMIN_HASH=$(python3 -c "import bcrypt; print(bcrypt.hashpw(b'${PANEL_ADMIN_PASS}', bcrypt.gensalt(10)).decode())" 2>/dev/null)
        fi
    fi
    [[ -z "$PANEL_ADMIN_HASH" ]] && PANEL_ADMIN_HASH="REPLACE_WITH_HASH"

    # URL API telemt
    local telemt_api_port="9091"
    local telemt_cfg=""
    for f in /etc/telemt/telemt.toml /etc/telemt/config.toml; do
        [[ -f "$f" ]] && telemt_cfg="$f" && break
    done
    if [[ -n "$telemt_cfg" ]]; then
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

    # ── Systemd-сервис ────────────────────────────────────────────
    msg_step "Запуск сервиса"

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
            msg_ok "Панель запущена"
        else
            msg_warn "Сервис стартовал, статус неопределён"
        fi
    else
        msg_err "Не удалось запустить панель"
        msg_info "Логи: journalctl -u ${PANEL_SERVICE} -n 30 --no-pager"
        return 1
    fi

    # ── Итог ──────────────────────────────────────────────────────
    local access_url="http://127.0.0.1:${PANEL_PORT} (SSH-туннель: ssh -L ${PANEL_PORT}:127.0.0.1:${PANEL_PORT} root@SERVER)"

    draw_info_box 62 \
        "${C_BOLD}telemt_panel установлена${C_RESET}" \
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

    msg_ok "Установка telemt_panel завершена"
}
