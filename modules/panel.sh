#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  modules/panel.sh — Установка telemt_panel (прямой доступ)
#  https://github.com/amirotin/telemt_panel
# ═══════════════════════════════════════════════════════════════════

PANEL_REPO="amirotin/telemt_panel"
PANEL_BIN="/usr/local/bin/telemt-panel"
PANEL_CONFIG_DIR="/etc/telemt-panel"
PANEL_CONFIG="${PANEL_CONFIG_DIR}/config.toml"
PANEL_DATA_DIR="/var/lib/telemt-panel"
PANEL_SERVICE="telemt-panel"
PANEL_SERVICE_FILE="/etc/systemd/system/${PANEL_SERVICE}.service"
PANEL_USER="telemt-panel"
PANEL_PORT="8888"
PANEL_LISTEN=""
PANEL_ADMIN_USER="admin"
PANEL_ADMIN_PASS=""
PANEL_ADMIN_HASH=""
PANEL_JWT_SECRET=""

_panel_detect_arch() {
    case "$(uname -m)" in
        x86_64)  echo "x86_64" ;;
        aarch64) echo "arm64" ;;
        armv7l)  echo "armv7" ;;
        *) msg_err "Неподдерживаемая архитектура: $(uname -m)"; return 1 ;;
    esac
}

panel_install() {
    msg_header "Установка telemt_panel"

    # ── Сбор данных ───────────────────────────────────────────────
    prompt_input "Порт панели (внешний)" PANEL_PORT '^[0-9]+$' "8888"
    PANEL_LISTEN="0.0.0.0:${PANEL_PORT}"

    prompt_input "Имя администратора" PANEL_ADMIN_USER '^[a-zA-Z0-9_-]+$' "admin"

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

    # ── Скачивание ────────────────────────────────────────────────
    msg_step "Скачивание telemt_panel"

    local arch
    arch=$(_panel_detect_arch) || return 1
    local libc
    libc=$(_detect_libc 2>/dev/null || echo "gnu")

    local release_json
    release_json=$(curl -fsSL "https://api.github.com/repos/${PANEL_REPO}/releases/latest" 2>/dev/null) || {
        msg_err "Не удалось получить релизы"; return 1
    }

    local download_url
    download_url=$(echo "$release_json" | jq -r \
        ".assets[] | select(.name | test(\"${arch}\") and test(\"${libc}\") and test(\"tar.gz\")) | .browser_download_url" \
        2>/dev/null | head -1)
    [[ -z "$download_url" || "$download_url" == "null" ]] && \
        download_url=$(echo "$release_json" | jq -r \
            ".assets[] | select(.name | test(\"${arch}\") and test(\"tar.gz\")) | .browser_download_url" \
            2>/dev/null | head -1)

    if [[ -z "$download_url" || "$download_url" == "null" ]]; then
        msg_err "Бинарник для ${arch} не найден"; return 1
    fi

    local version; version=$(echo "$release_json" | jq -r '.tag_name' 2>/dev/null)
    msg_info "Версия: ${version}"

    local tmp_dir; tmp_dir=$(mktemp -d)
    run_with_spinner "Скачивание" curl -fSL --max-time 120 -o "${tmp_dir}/panel.tar.gz" "$download_url" || {
        rm -rf "$tmp_dir"; return 1
    }

    tar -xzf "${tmp_dir}/panel.tar.gz" -C "$tmp_dir" 2>>"$LOG_FILE" || {
        msg_err "Ошибка распаковки"; rm -rf "$tmp_dir"; return 1
    }

    local bin_path=""
    bin_path=$(find "$tmp_dir" -name "telemt-panel" -type f 2>/dev/null | head -1)
    [[ -z "$bin_path" ]] && bin_path=$(find "$tmp_dir" -name "telemt_panel" -type f 2>/dev/null | head -1)
    [[ -z "$bin_path" ]] && bin_path=$(find "$tmp_dir" -name "telemt-panel*" -type f ! -name "*.sha256" ! -name "*.tar.gz" 2>/dev/null | head -1)
    if [[ -z "$bin_path" ]]; then
        for f in $(find "$tmp_dir" -type f 2>/dev/null); do
            file -b "$f" 2>/dev/null | grep -qi "ELF" && bin_path="$f" && break
        done
    fi
    if [[ -z "$bin_path" ]]; then
        msg_err "Бинарник не найден в архиве"; rm -rf "$tmp_dir"; return 1
    fi

    install -m 0755 "$bin_path" "$PANEL_BIN"
    rm -rf "$tmp_dir"
    rollback_push "rm -f '${PANEL_BIN}'"
    msg_ok "Установлен: ${PANEL_BIN}"

    # ── Пользователь + конфиг ─────────────────────────────────────
    msg_step "Настройка"

    id -u "$PANEL_USER" &>/dev/null || {
        useradd --system --shell /usr/sbin/nologin --home /nonexistent "$PANEL_USER" 2>/dev/null || true
        rollback_push "userdel '${PANEL_USER}' 2>/dev/null || true"
    }
    getent group telemt &>/dev/null && usermod -aG telemt "$PANEL_USER" 2>/dev/null || true

    mkdir -p "$PANEL_CONFIG_DIR" "$PANEL_DATA_DIR"
    chown "${PANEL_USER}:" "$PANEL_CONFIG_DIR" "$PANEL_DATA_DIR"
    chmod 700 "$PANEL_CONFIG_DIR"

    PANEL_ADMIN_HASH=$("$PANEL_BIN" hash-password <<< "$PANEL_ADMIN_PASS" 2>/dev/null | tail -1)
    [[ -z "$PANEL_ADMIN_HASH" ]] && PANEL_ADMIN_HASH="REPLACE_WITH_HASH"

    local telemt_api_port="9091"
    for f in /etc/telemt/telemt.toml /etc/telemt/config.toml; do
        if [[ -f "$f" ]]; then
            local ap; ap=$(grep -E '^listen[[:space:]]*=' "$f" 2>/dev/null | tail -1 | awk -F'=' '{print $2}' | tr -d ' "')
            [[ -n "$ap" ]] && telemt_api_port=$(echo "$ap" | awk -F: '{print $NF}')
            break
        fi
    done

    cat > "$PANEL_CONFIG" << CFGEOF
listen = "${PANEL_LISTEN}"

[telemt]
url = "http://127.0.0.1:${telemt_api_port}"

[auth]
username = "${PANEL_ADMIN_USER}"
password_hash = "${PANEL_ADMIN_HASH}"
jwt_secret = "${PANEL_JWT_SECRET}"
session_ttl = "24h"
CFGEOF
    chown "${PANEL_USER}:" "$PANEL_CONFIG"; chmod 600 "$PANEL_CONFIG"
    rollback_push "rm -f '${PANEL_CONFIG}'"
    msg_ok "Конфиг создан"

    # ── Systemd ───────────────────────────────────────────────────
    cat > "$PANEL_SERVICE_FILE" << SVCEOF
[Unit]
Description=Telemt Panel
After=network-online.target telemt.service

[Service]
Type=simple
User=${PANEL_USER}
ExecStart=${PANEL_BIN} -config ${PANEL_CONFIG}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF
    systemctl daemon-reload
    systemctl enable "$PANEL_SERVICE" >> "$LOG_FILE" 2>&1
    rollback_push "systemctl stop ${PANEL_SERVICE} 2>/dev/null; systemctl disable ${PANEL_SERVICE} 2>/dev/null; rm -f '${PANEL_SERVICE_FILE}'; systemctl daemon-reload"

    # ── Firewall ──────────────────────────────────────────────────
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow "${PANEL_PORT}/tcp" >> "$LOG_FILE" 2>&1 || true
    fi
    if ! iptables -C INPUT -p tcp --dport "$PANEL_PORT" -j ACCEPT 2>/dev/null; then
        iptables -I INPUT 1 -p tcp --dport "$PANEL_PORT" -j ACCEPT 2>/dev/null || true
        command -v netfilter-persistent &>/dev/null && netfilter-persistent save >> "$LOG_FILE" 2>&1 || \
            { mkdir -p /etc/iptables; iptables-save > /etc/iptables/rules.v4 2>/dev/null; } || true
    fi
    msg_ok "Порт ${PANEL_PORT}/tcp открыт"

    # ── Запуск ────────────────────────────────────────────────────
    systemctl start "$PANEL_SERVICE" >> "$LOG_FILE" 2>&1
    sleep 2
    if systemctl is-active --quiet "$PANEL_SERVICE"; then
        msg_ok "Панель запущена"
    else
        msg_err "Не удалось запустить панель"
        msg_info "journalctl -u ${PANEL_SERVICE} -n 20 --no-pager"
        return 1
    fi

    # ── Определение URL ───────────────────────────────────────────
    local panel_host=""
    for f in /etc/telemt/telemt.toml /etc/telemt/config.toml; do
        [[ -f "$f" ]] && panel_host=$(grep -E '^public_host' "$f" 2>/dev/null | head -1 | awk -F'"' '{print $2}')
        [[ -n "$panel_host" ]] && break
    done
    [[ -z "$panel_host" ]] && panel_host=$(curl -4s --max-time 3 ifconfig.me 2>/dev/null || echo "ВАШ_IP")

    local access_url="http://${panel_host}:${PANEL_PORT}"

    # Сохранить URL для статус-панели
    {
        echo "# telemt_panel credentials — $(date)"
        echo "URL: ${access_url}"
        echo "Username: ${PANEL_ADMIN_USER}"
        echo "Password: ${PANEL_ADMIN_PASS}"
    } > "${PANEL_DATA_DIR}/credentials.txt"
    chmod 600 "${PANEL_DATA_DIR}/credentials.txt"
    chown "${PANEL_USER}:" "${PANEL_DATA_DIR}/credentials.txt" 2>/dev/null || true

    draw_info_box 62 \
        "${C_BOLD}${C_GREEN}telemt_panel установлена${C_RESET}" \
        "" \
        "URL:      ${C_CYAN}${access_url}${C_RESET}" \
        "Логин:    ${C_WHITE}${PANEL_ADMIN_USER}${C_RESET}" \
        "Пароль:   ${C_WHITE}${PANEL_ADMIN_PASS}${C_RESET}" \
        "" \
        "${C_YELLOW}Сохраните эти данные!${C_RESET}"

    msg_ok "Установка telemt_panel завершена"
}
