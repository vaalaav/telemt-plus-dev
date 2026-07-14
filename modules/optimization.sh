#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  modules/optimization.sh — Оптимизация и фиксы DPI для telemt
#  База: MTPROTO_FIX_By_MEKO (v0.74) + MTproxy-reanimation
#  Обновлено под telemt 3.4.23: нативный synlimit ([[server.listeners]]),
#  client_mss_bulk (фрагментация только handshake), rst_on_close,
#  server.conntrack_control (опционально)
# ═══════════════════════════════════════════════════════════════════

# ── Константы ─────────────────────────────────────────────────────
OPT_SYNFIX_CHAIN="MTPR_SYNFIX"
OPT_SYSCTL_FILE="/etc/sysctl.d/99-telemt-tuning.conf"
OPT_BACKUP_DIR="/opt/telemt/backups"
OPT_PORT_FILE="/opt/mtpr-simple/port"
OPT_STATE_DIR="/opt/mtpr-simple"

# ── Определение порта telemt ──────────────────────────────────────
_opt_detect_port() {
    if [[ -n "${TELEMT_PORT:-}" ]]; then echo "$TELEMT_PORT"; return 0; fi
    local cfg; cfg=$(_opt_detect_config)
    if [[ -n "$cfg" ]]; then
        local p; p=$(grep -E '^port[[:space:]]*=' "$cfg" 2>/dev/null | head -1 | awk -F'=' '{print $2}' | tr -d ' "')
        [[ "$p" =~ ^[0-9]+$ ]] && echo "$p" && return 0
    fi
    echo "443"
}

_opt_detect_config() {
    if [[ -n "${TELEMT_CONFIG:-}" && -f "${TELEMT_CONFIG:-}" ]]; then
        echo "$TELEMT_CONFIG"; return
    fi
    for f in /etc/telemt/telemt.toml /etc/telemt/config.toml /opt/telemt/telemt.toml; do
        [[ -f "$f" ]] && echo "$f" && return
    done
}

# ── Определение порта SSH ─────────────────────────────────────────
_get_ssh_port() {
    local port=""
    if command -v sshd &>/dev/null && sshd -T 2>/dev/null | grep -q 'port '; then
        port=$(sshd -T 2>/dev/null | grep 'port ' | awk '{print $2}' | head -1)
        [[ "$port" =~ ^[0-9]+$ ]] && echo "$port" && return 0
    fi
    if [[ -f /etc/ssh/sshd_config ]]; then
        port=$(grep -E '^Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config | head -1 | awk '{print $2}')
        [[ "$port" =~ ^[0-9]+$ ]] && echo "$port" && return 0
    fi
    for cfg in /etc/ssh/sshd_config.d/*.conf; do
        [[ -f "$cfg" ]] || continue
        port=$(grep -E '^Port[[:space:]]+[0-9]+' "$cfg" | head -1 | awk '{print $2}')
        [[ "$port" =~ ^[0-9]+$ ]] && echo "$port" && return 0
    done
    echo "22"
}

# ── TOML-утилиты ─────────────────────────────────────────────────
_toml_set() {
    local key="$1" value="$2" section="$3" file="$4"
    [[ -f "$file" ]] || return 1
    if grep -qE "^${key}[[:space:]]*=" "$file" 2>/dev/null; then
        sed -i "s/^${key}[[:space:]]*=.*/${key} = ${value}/" "$file"
        return 0
    fi
    if grep -qE "^\\[${section}\\]" "$file" 2>/dev/null; then
        sed -i "/^\\[${section}\\]/a ${key} = ${value}" "$file"
        return 0
    fi
    echo -e "\n[${section}]\n${key} = ${value}" >> "$file"
}

# ══════════════════════════════════════════════════════════════════
#  Фикс 1: SYN FIX (MEKO — приоритет)
#  iptables + кастомная цепочка MTPR_SYNFIX
#  Двухуровневая фильтрация:
#    1. iOS SYN (length=64, ttl<65): 15/sec burst 30 → ACCEPT, иначе REJECT
#    2. Общий SYN: 54/min burst 1 → ACCEPT, иначе REJECT
# ══════════════════════════════════════════════════════════════════
_is_syn_fix_installed() {
    iptables -L "$OPT_SYNFIX_CHAIN" -n &>/dev/null
}

opt_syn_fix() {
    msg_step "SYN FIX (MTPROTO_FIX_By_MEKO)"

    local port ssh_port
    port=$(_opt_detect_port)
    ssh_port=$(_get_ssh_port)

    if _is_syn_fix_installed; then
        msg_warn "SYN FIX уже установлен — пропуск"
        return 0
    fi

    draw_info_box 62 \
        "${C_BOLD}SYN FIX — двухуровневая фильтрация (MEKO)${C_RESET}" \
        "" \
        "Уровень 1 (iOS): SYN length=64 + ttl<65" \
        "  → hashlimit 15/sec burst 30 → ACCEPT" \
        "  → сверх лимита → REJECT tcp-reset" \
        "" \
        "Уровень 2 (общий): все остальные SYN" \
        "  → hashlimit 54/min burst 1 → ACCEPT" \
        "  → сверх лимита → REJECT tcp-reset" \
        "" \
        "Порт прокси:  ${C_WHITE}${port}${C_RESET}" \
        "Порт SSH:     ${C_WHITE}${ssh_port}${C_RESET}"

    # Предупреждение
    msg_warn "Будут изменены правила iptables!"
    msg_info "SSH порт ${ssh_port} будет защищён перед применением"
    echo ""

    # Установка iptables-persistent
    if ! dpkg -s iptables-persistent &>/dev/null 2>&1; then
        msg_info "Установка iptables-persistent..."
        DEBIAN_FRONTEND=noninteractive apt-get update -qq >> "$LOG_FILE" 2>&1
        DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent >> "$LOG_FILE" 2>&1 || {
            msg_err "Не удалось установить iptables-persistent"
            return 1
        }
        msg_ok "iptables-persistent установлен"
    fi

    # Защита SSH
    if ! iptables -C INPUT -p tcp --dport "$ssh_port" -j ACCEPT 2>/dev/null; then
        iptables -I INPUT 1 -p tcp --dport "$ssh_port" -j ACCEPT
        msg_ok "SSH порт ${ssh_port} защищён"
    fi

    # Создание / очистка цепочки
    iptables -N "$OPT_SYNFIX_CHAIN" 2>/dev/null || true
    iptables -F "$OPT_SYNFIX_CHAIN"

    # Подключение к INPUT
    if ! iptables -C INPUT -j "$OPT_SYNFIX_CHAIN" 2>/dev/null; then
        iptables -I INPUT 2 -j "$OPT_SYNFIX_CHAIN"
    fi

    # ── Правило 1: iOS SYN (length=64, ttl<65) — лимит 15/sec ──
    iptables -A "$OPT_SYNFIX_CHAIN" \
        -p tcp --dport "$port" --syn \
        -m tcp --tcp-flags SYN SYN \
        -m length --length 64 \
        -m ttl --ttl-lt 65 \
        -m hashlimit \
            --hashlimit-name "ios_${port}" \
            --hashlimit-mode srcip \
            --hashlimit-upto 15/second \
            --hashlimit-burst 30 \
            --hashlimit-htable-expire 60000 \
            --hashlimit-htable-size 32768 \
        -j ACCEPT
    msg_ok "Правило 1: iOS SYN accept (15/sec burst 30)"

    # ── Правило 2: iOS SYN сверх лимита → REJECT ───────────────
    iptables -A "$OPT_SYNFIX_CHAIN" \
        -p tcp --dport "$port" --syn \
        -m tcp --tcp-flags SYN SYN \
        -m length --length 64 \
        -m ttl --ttl-lt 65 \
        -j REJECT --reject-with tcp-reset
    msg_ok "Правило 2: iOS SYN reject (сверх лимита)"

    # ── Правило 3: Общий SYN — лимит 54/min ────────────────────
    iptables -A "$OPT_SYNFIX_CHAIN" \
        -p tcp --dport "$port" --syn \
        -m hashlimit \
            --hashlimit-name "mtproto_${port}" \
            --hashlimit-mode srcip \
            --hashlimit-upto 54/minute \
            --hashlimit-burst 1 \
            --hashlimit-htable-expire 60000 \
            --hashlimit-htable-size 32768 \
        -j ACCEPT
    msg_ok "Правило 3: Общий SYN accept (54/min burst 1)"

    # ── Правило 4: Всё остальное → REJECT ──────────────────────
    iptables -A "$OPT_SYNFIX_CHAIN" \
        -p tcp --dport "$port" --syn \
        -j REJECT --reject-with tcp-reset
    msg_ok "Правило 4: SYN reject (всё сверх лимитов)"

    # Сохранение
    mkdir -p "$OPT_STATE_DIR"
    echo "$port" > "$OPT_PORT_FILE"

    mkdir -p /etc/iptables
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save >> "$LOG_FILE" 2>&1
    elif command -v iptables-save &>/dev/null; then
        iptables-save > /etc/iptables/rules.v4
    fi

    rollback_push "_opt_remove_syn_fix"
    msg_ok "SYN FIX установлен на порт ${port}"
}

# Удаление SYN FIX (для rollback)
_opt_remove_syn_fix() {
    if iptables -C INPUT -j "$OPT_SYNFIX_CHAIN" 2>/dev/null; then
        iptables -D INPUT -j "$OPT_SYNFIX_CHAIN"
    fi
    if iptables -L "$OPT_SYNFIX_CHAIN" -n &>/dev/null; then
        iptables -F "$OPT_SYNFIX_CHAIN"
        iptables -X "$OPT_SYNFIX_CHAIN"
    fi
    mkdir -p /etc/iptables
    command -v netfilter-persistent &>/dev/null && netfilter-persistent save &>/dev/null || \
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    rm -f "$OPT_PORT_FILE"
}

# ══════════════════════════════════════════════════════════════════
#  Фикс 1b: SYN FIX — нативный synlimit telemt (>= 3.4.18, доработан
#  в 3.4.20 "Synlimit V2" и 3.4.23 "per-target netfilter rules")
#  Правила ставит и снимает сам telemt через [[server.listeners]] —
#  не требует iptables-persistent, hot-reloadable, CAP_NET_ADMIN уже
#  выдан сервису telemt.service (telemt_core.sh).
# ══════════════════════════════════════════════════════════════════
# Формат блока идентичен _apply_synfix()/_disable_synfix() в modules/mytelemtinfo —
# один и тот же маркированный блок можно ставить/снимать что установщиком,
# что day-2 CLI, без конфликтов и дублей.

# Проверка: настроен ли нативный synlimit
_is_native_synlimit_installed() {
    local cfg
    cfg=$(_opt_detect_config)
    [[ -z "$cfg" || ! -f "$cfg" ]] && return 1
    grep -q 'synlimit' "$cfg" 2>/dev/null
}

# Любой SYN FIX (внешний или нативный) сейчас активен?
_is_any_syn_fix_active() {
    _is_syn_fix_installed && return 0
    _is_native_synlimit_installed && return 0
    return 1
}

opt_syn_fix_native() {
    msg_step "SYN FIX — нативный synlimit telemt (>=3.4.18)"

    local cfg
    cfg=$(_opt_detect_config)
    if [[ -z "$cfg" || ! -f "$cfg" ]]; then
        msg_err "Конфиг telemt не найден — нативный SYN FIX недоступен"
        return 1
    fi

    # Снять внешнюю цепочку, если была установлена ранее — иначе двойной лимит
    if _is_syn_fix_installed; then
        msg_warn "Обнаружена внешняя цепочка ${OPT_SYNFIX_CHAIN} — снимаю её"
        _opt_remove_syn_fix
    fi

    if _is_native_synlimit_installed; then
        msg_warn "Нативный synlimit уже настроен — пропуск"
        return 0
    fi

    draw_info_box 62 \
        "${C_BOLD}SYN FIX — встроенный synlimit telemt${C_RESET}" \
        "" \
        "iOS-бакет:   1s / 15 hits / burst 30" \
        "Общий бакет: 60s / 54 hits / burst 1" \
        "" \
        "Правила ставит и снимает сам telemt (CAP_NET_ADMIN уже выдан)." \
        "Тот же блок доступен для переключения в mytelemtinfo → [2] SYN-fix"

    mkdir -p "$OPT_BACKUP_DIR"
    cp "$cfg" "${OPT_BACKUP_DIR}/$(basename "$cfg").pre-synlimit.$(date +%s)"
    rollback_push "cp '${OPT_BACKUP_DIR}/$(basename "$cfg").pre-synlimit.'* '${cfg}' 2>/dev/null || true; systemctl restart telemt 2>/dev/null || true"

    cat >> "$cfg" << 'SYNEOF'

# >>> SYN-fix (mytelemtinfo) — не редактировать вручную, блок управляется автоматически
[[server.listeners]]
ip = "0.0.0.0"
synlimit = "iptables"
synlimit_ios_hitcount = 15
synlimit_ios_seconds  = 1
synlimit_ios_burst    = 30
synlimit_hitcount = 54
synlimit_seconds  = 60
synlimit_burst    = 1
# <<< SYN-fix (mytelemtinfo)
SYNEOF

    if systemctl is-active --quiet telemt 2>/dev/null; then
        run_with_spinner "Перезапуск telemt (применить synlimit)" systemctl restart telemt
    fi

    msg_ok "Нативный SYN FIX включён (управляется также через mytelemtinfo)"
}

# Выбор способа SYN FIX: нативный (по умолчанию) или внешний iptables-модуль (MEKO)
opt_choose_syn_fix() {
    echo ""
    msg_step "Выбор способа SYN FIX"
    echo -e "    ${C_GREEN}[1]${C_RESET} Нативный synlimit telemt ${C_DIM}(рекомендуется, telemt >=3.4.18)${C_RESET}"
    echo -e "    ${C_CYAN}[2]${C_RESET} Внешний iptables-модуль ${C_DIM}(MEKO, оригинальный)${C_RESET}"
    echo -ne "  ${C_BOLD}Выбор${C_RESET} [1/2, Enter = 1]: "
    local choice
    read -r choice
    case "$choice" in
        2)
            opt_syn_fix || msg_warn "SYN FIX (внешний) — ошибка (пропущен)"
            ;;
        *)
            opt_syn_fix_native || {
                msg_warn "Нативный SYN FIX не удался — пробую внешний iptables-модуль"
                opt_syn_fix || msg_warn "SYN FIX (внешний) — ошибка (пропущен)"
            }
            ;;
    esac
}

# ══════════════════════════════════════════════════════════════════
#  Фикс 2: Умная фрагментация MSS (telemt >= 3.4.19: client_mss_bulk)
#  Низкий MSS применяется ТОЛЬКО на TLS-handshake (обход DPI по паттерну
#  ClientHello); для bulk-данных MSS поднимается обратно — это убирает
#  многократный рост packets-per-second, который раньше давал полный
#  disable MSS (MEKO-подход, комментирование строк).
# ══════════════════════════════════════════════════════════════════
OPT_CLIENT_MSS="tspu"        # extreme-low=88 | tspu=92 | 2in8=256 | своё число 88..4096
OPT_CLIENT_MSS_BULK="1400"   # MSS для данных после хендшейка

opt_smart_mss() {
    msg_step "MSS: client_mss + client_mss_bulk (умная фрагментация)"

    local cfg
    cfg=$(_opt_detect_config)
    if [[ -z "$cfg" || ! -f "$cfg" ]]; then
        msg_info "Конфиг не найден — пропуск"
        return 0
    fi

    local cur_mss cur_bulk
    cur_mss=$(grep -E '^client_mss[[:space:]]*=' "$cfg" 2>/dev/null | head -1 | awk -F'=' '{print $2}' | tr -d ' "')
    cur_bulk=$(grep -E '^client_mss_bulk[[:space:]]*=' "$cfg" 2>/dev/null | head -1 | awk -F'=' '{print $2}' | tr -d ' "')

    if [[ "$cur_mss" == "$OPT_CLIENT_MSS" && "$cur_bulk" == "$OPT_CLIENT_MSS_BULK" ]]; then
        msg_info "client_mss/client_mss_bulk уже настроены (${cur_mss} / ${cur_bulk})"
        return 0
    fi

    # Бэкап
    mkdir -p "$OPT_BACKUP_DIR"
    cp "$cfg" "${OPT_BACKUP_DIR}/$(basename "$cfg").pre-mss.$(date +%s)"
    rollback_push "cp '${OPT_BACKUP_DIR}/$(basename "$cfg").pre-mss.'* '${cfg}' 2>/dev/null || true"

    # Снять устаревшие закомментированные MEKO-строки вида "#mss = ..." (если остались от прошлых версий скрипта)
    sed -i '/^#.*\bmss\b/Id' "$cfg" 2>/dev/null || true

    _toml_set "client_mss" "\"${OPT_CLIENT_MSS}\"" "server" "$cfg"
    _toml_set "client_mss_bulk" "\"${OPT_CLIENT_MSS_BULK}\"" "server" "$cfg"

    if systemctl is-active --quiet telemt 2>/dev/null; then
        run_with_spinner "Перезапуск telemt" systemctl restart telemt
    fi

    msg_ok "client_mss=\"${OPT_CLIENT_MSS}\" (только handshake), client_mss_bulk=\"${OPT_CLIENT_MSS_BULK}\" (данные)"
}

# ══════════════════════════════════════════════════════════════════
#  Фикс 3: Базовая оптимизация (MEKO — приоритет + дополнения)
#  sysctl: BBR, tcp_fastopen, агрессивные буферы
#  telemt: max_connections, client_handshake, LimitNOFILE
#  Дополнено из reanimation: tg_connect, client_keepalive
# ══════════════════════════════════════════════════════════════════
opt_basic_optimization() {
    msg_step "Базовая оптимизация системы и Telemt"

    local cfg
    cfg=$(_opt_detect_config)

    # ── 3a. sysctl (MEKO values — приоритет) ──────────────────────
    msg_info "Применение sysctl (BBR + TCP оптимизация)..."

    cat > "$OPT_SYSCTL_FILE" << SYSCTLEOF
# telemt TCP tuning — MTPROTO_FIX_By_MEKO + дополнения
# Сгенерировано telemt VPS Installer

# ── BBR congestion control (MEKO) ────────────────────────
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# ── TCP Fast Open (MEKO) ─────────────────────────────────
net.ipv4.tcp_fastopen = 3

# ── Буферы и backlog (MEKO: агрессивные значения) ────────
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.core.netdev_max_backlog = 65535
fs.file-max = 2097152

# ── TCP keepalive (MEKO values) ──────────────────────────
net.ipv4.tcp_keepalive_time = 45
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 3

# ── Дополнительная оптимизация TCP-стека ─────────────────
net.ipv4.tcp_window_scaling = 1
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# Быстрая утилизация TIME_WAIT
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15

# Отключить slow start после idle (важно для прокси)
net.ipv4.tcp_slow_start_after_idle = 0

# MTU probing (обход PMTUD-блокировки DPI)
net.ipv4.tcp_mtu_probing = 1

# SYN cookies (защита на уровне ядра)
net.ipv4.tcp_syncookies = 1
SYSCTLEOF

    rollback_push "rm -f '${OPT_SYSCTL_FILE}'; sysctl --system >> '${LOG_FILE}' 2>&1"

    if run_with_spinner "Применение sysctl" sysctl -p "$OPT_SYSCTL_FILE"; then
        msg_ok "sysctl применён (BBR, tcp_fastopen, keepalive, буферы)"
    else
        msg_warn "Некоторые параметры могут не поддерживаться ядром"
    fi

    # ── 3b. LimitNOFILE для telemt (MEKO) ─────────────────────────
    msg_info "Настройка LimitNOFILE для telemt..."
    local override_dir="/etc/systemd/system/telemt.service.d"
    mkdir -p "$override_dir"

    if ! grep -q "LimitNOFILE=65535" "${override_dir}/limits.conf" 2>/dev/null; then
        cat > "${override_dir}/limits.conf" << LIMEOF
[Service]
LimitNOFILE=65535
LIMEOF
        systemctl daemon-reload
        rollback_push "rm -f '${override_dir}/limits.conf'; systemctl daemon-reload"
        msg_ok "LimitNOFILE=65535 установлен"
    else
        msg_info "LimitNOFILE уже настроен"
    fi

    # ── 3c. Тюнинг конфига telemt ─────────────────────────────────
    if [[ -n "$cfg" && -f "$cfg" ]]; then
        msg_info "Тюнинг конфига telemt..."

        # Бэкап
        mkdir -p "$OPT_BACKUP_DIR"
        cp "$cfg" "${OPT_BACKUP_DIR}/$(basename "$cfg").pre-opt.$(date +%s)"
        rollback_push "cp '${OPT_BACKUP_DIR}/$(basename "$cfg").pre-opt.'* '${cfg}' 2>/dev/null || true"

        local changed=false

        # max_connections = 16384 (MEKO)
        if grep -q '^max_connections *=.*' "$cfg"; then
            if ! grep -q '^max_connections *= *16384' "$cfg"; then
                sed -i 's/^max_connections *= *.*/max_connections = 16384/' "$cfg"
                changed=true; msg_ok "max_connections = 16384"
            else
                msg_info "max_connections уже 16384"
            fi
        else
            if grep -q '\[server\]' "$cfg"; then
                sed -i '/\[server\]/a max_connections = 16384' "$cfg"
                changed=true; msg_ok "max_connections = 16384 (добавлен)"
            fi
        fi

        # client_handshake = 15 (MEKO — приоритет над reanimation's 90)
        if grep -q '^client_handshake *=.*' "$cfg"; then
            if ! grep -q '^client_handshake *= *15' "$cfg"; then
                sed -i 's/^client_handshake *= *.*/client_handshake = 15/' "$cfg"
                changed=true; msg_ok "client_handshake = 15 (MEKO)"
            else
                msg_info "client_handshake уже 15"
            fi
        else
            _toml_set "client_handshake" "15" "timeouts" "$cfg"
            changed=true; msg_ok "client_handshake = 15 (добавлен)"
        fi

        # tg_connect = 30 (из reanimation — дополнение)
        local cur_tg; cur_tg=$(grep -E '^tg_connect[[:space:]]*=' "$cfg" 2>/dev/null | head -1 | awk -F'=' '{print $2}' | tr -d ' ')
        if [[ "$cur_tg" != "30" ]]; then
            _toml_set "tg_connect" "30" "general" "$cfg"
            changed=true; msg_ok "tg_connect = 30 (reanimation)"
        else
            msg_info "tg_connect уже 30"
        fi

        # client_keepalive = 120 (из reanimation — дополнение)
        local cur_ka; cur_ka=$(grep -E '^client_keepalive[[:space:]]*=' "$cfg" 2>/dev/null | head -1 | awk -F'=' '{print $2}' | tr -d ' ')
        if [[ "$cur_ka" != "120" ]]; then
            _toml_set "client_keepalive" "120" "timeouts" "$cfg"
            changed=true; msg_ok "client_keepalive = 120 (reanimation)"
        else
            msg_info "client_keepalive уже 120"
        fi

        # rst_on_close = "errors" (telemt >= 3.4.x) — мгновенный RST вместо
        # честного FIN для соединений, не прошедших MTProto-хендшейк
        # (сканеры/DPI-пробы/боты) — освобождает orphan-сокеты быстрее
        local cur_rst; cur_rst=$(grep -E '^rst_on_close[[:space:]]*=' "$cfg" 2>/dev/null | head -1 | awk -F'=' '{print $2}' | tr -d ' "')
        if [[ "$cur_rst" != "errors" && "$cur_rst" != "always" ]]; then
            _toml_set "rst_on_close" "\"errors\"" "general" "$cfg"
            changed=true; msg_ok 'rst_on_close = "errors" (мгновенный RST для сканеров/DPI-проб)'
        else
            msg_info "rst_on_close уже настроен (${cur_rst})"
        fi

        # Перезапуск при изменениях
        if [[ "$changed" == "true" ]]; then
            if systemctl is-active --quiet telemt 2>/dev/null; then
                run_with_spinner "Перезапуск telemt" systemctl restart telemt
            fi
        fi
    else
        msg_warn "Конфиг telemt не найден — тюнинг параметров пропущен"
        msg_info "Добавьте вручную в config.toml:"
        echo "  [server]"
        echo "  max_connections = 16384"
        echo ""
        echo "  [general]"
        echo "  tg_connect = 30"
        echo ""
        echo "  [timeouts]"
        echo "  client_handshake = 15"
        echo "  client_keepalive = 120"
    fi
}

# ══════════════════════════════════════════════════════════════════
#  Фикс 3b: Нативный conntrack control telemt (>= 3.4.20)
#  Снижает нагрузку на conntrack-таблицу ядра под высоким RPS ценой
#  того, что соединения на прокси-порту перестают отслеживаться ядром
#  (notrack). Меняет поведение файрвола — решение спрашиваем явно.
# ══════════════════════════════════════════════════════════════════
opt_conntrack_control() {
    local cfg
    cfg=$(_opt_detect_config)
    [[ -z "$cfg" || ! -f "$cfg" ]] && return 0

    if grep -q '^\[server\.conntrack_control\]' "$cfg" 2>/dev/null; then
        msg_info "server.conntrack_control уже настроен — пропуск"
        return 0
    fi

    echo ""
    msg_info "telemt может сам управлять conntrack (снижает нагрузку под высоким RPS,"
    msg_info "но соединения на прокси-порту перестают отслеживаться ядром — notrack)."
    if ! confirm_yn "Включить server.conntrack_control (mode=notrack)?" "n"; then
        msg_info "conntrack_control пропущен"
        return 0
    fi

    mkdir -p "$OPT_BACKUP_DIR"
    cp "$cfg" "${OPT_BACKUP_DIR}/$(basename "$cfg").pre-conntrack.$(date +%s)"
    rollback_push "cp '${OPT_BACKUP_DIR}/$(basename "$cfg").pre-conntrack.'* '${cfg}' 2>/dev/null || true; systemctl restart telemt 2>/dev/null || true"

    cat >> "$cfg" << CTEOF

[server.conntrack_control]
inline_conntrack_control = true
mode = "notrack"
backend = "auto"
profile = "balanced"
CTEOF

    if systemctl is-active --quiet telemt 2>/dev/null; then
        run_with_spinner "Перезапуск telemt" systemctl restart telemt
    fi
    msg_ok "server.conntrack_control включён (mode=notrack, backend=auto, profile=balanced)"
}

# ══════════════════════════════════════════════════════════════════
#  Фикс 4: Firewall — открытие портов
# ══════════════════════════════════════════════════════════════════
opt_firewall() {
    msg_step "Настройка firewall"

    local port
    port=$(_opt_detect_port)

    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        msg_info "UFW активен — открываем порт ${port}/tcp"
        ufw allow "${port}/tcp" >> "$LOG_FILE" 2>&1
        rollback_push "ufw delete allow ${port}/tcp 2>/dev/null || true"
        msg_ok "UFW: порт ${port}/tcp открыт"
    elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
        msg_info "firewalld активен — открываем порт ${port}/tcp"
        firewall-cmd --permanent --add-port="${port}/tcp" >> "$LOG_FILE" 2>&1
        firewall-cmd --reload >> "$LOG_FILE" 2>&1
        rollback_push "firewall-cmd --permanent --remove-port=${port}/tcp 2>/dev/null; firewall-cmd --reload 2>/dev/null"
        msg_ok "firewalld: порт ${port}/tcp открыт"
    else
        # Raw iptables — если INPUT policy DROP, нужно явно разрешить
        local policy
        policy=$(iptables -L INPUT -n 2>/dev/null | head -1 | awk -F'[()]' '{print $2}') || true
        if [[ "$policy" == "DROP" ]] || ! iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
            iptables -I INPUT 1 -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
            if command -v netfilter-persistent &>/dev/null; then
                netfilter-persistent save >> "$LOG_FILE" 2>&1
            elif command -v iptables-save &>/dev/null; then
                mkdir -p /etc/iptables
                iptables-save > /etc/iptables/rules.v4 2>/dev/null
            fi
            rollback_push "iptables -D INPUT -p tcp --dport ${port} -j ACCEPT 2>/dev/null || true"
            msg_ok "iptables: порт ${port}/tcp открыт"
        else
            msg_info "Порт ${port}/tcp уже открыт или firewall не активен"
        fi
    fi
}

# ══════════════════════════════════════════════════════════════════
#  Вариант для selfmask
# ══════════════════════════════════════════════════════════════════
apply_mtproto_fixes_selfmask() {
    msg_header "Оптимизация DPI (режим selfmask)"

    msg_info "В режиме selfmask прокси и сайт делят порт 443."
    echo ""

    # MSS: умная фрагментация только handshake (telemt >= 3.4.19)
    opt_smart_mss || true

    # Базовая оптимизация (sysctl + telemt tuning + rst_on_close)
    opt_basic_optimization || true

    # SYN FIX на порт 443 — выбор: нативный synlimit или внешний MEKO
    local save_port="${TELEMT_PORT:-}"
    TELEMT_PORT="443"
    opt_choose_syn_fix
    TELEMT_PORT="$save_port"

    # Опционально: нативный conntrack control (telemt >= 3.4.20)
    opt_conntrack_control || true

    # КРИТИЧНО: убрать все standalone ACCEPT 443, которые обходят SYN FIX
    # (добавлены sitemask_configure_nginx ранее для telemt bootstrap)
    while iptables -D INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null; do :; done
    msg_ok "Standalone ACCEPT 443 удалены (трафик идёт через SYN FIX)"

    # Убедиться что conntrack ESTABLISHED,RELATED есть
    if ! iptables -C INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; then
        iptables -I INPUT 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        msg_ok "Добавлен conntrack ESTABLISHED,RELATED"
    fi

    # НЕ вызываем opt_firewall — порты уже открыты из sitemask_configure_nginx
    # opt_firewall добавит ACCEPT 443 на позицию 1 и обойдёт SYN FIX
    # Порт 80 уже открыт, порт 443 обслуживается через MTPR_SYNFIX

    # Открыть порт 80 если ещё не открыт (для ACME)
    if ! iptables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null; then
        iptables -I INPUT 1 -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
    fi

    # Сохранить финальное состояние iptables
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save >> "$LOG_FILE" 2>&1
    elif command -v iptables-save &>/dev/null; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4 2>/dev/null
    fi

    msg_ok "Оптимизация selfmask завершена"

    draw_info_box 62 \
        "${C_BOLD}Selfmask оптимизации:${C_RESET}" \
        "" \
        " ${CHECK} MSS: client_mss/client_mss_bulk (только handshake)" \
        " ${CHECK} BBR + TCP Fast Open + somaxconn=65535" \
        " ${CHECK} TCP keepalive: time=45, intvl=15, probes=3" \
        " ${CHECK} telemt: max_connections=16384, handshake=15" \
        " ${CHECK} rst_on_close=errors" \
        " ${CHECK} LimitNOFILE=65535 (systemd override)" \
        " ${CHECK} SYN FIX (нативный synlimit или MEKO) — standalone ACCEPT убран" \
        " ${CHECK} Порт 80 открыт (ACME), 443 через SYN FIX"
}

# ══════════════════════════════════════════════════════════════════
#  Главная точка входа: стандартные фиксы
# ══════════════════════════════════════════════════════════════════
apply_mtproto_fixes() {
    msg_header "Оптимизация и фиксы DPI"

    local proxy_port
    proxy_port=$(_opt_detect_port)

    # Выбор способа SYN FIX (нативный synlimit telemt / внешний MEKO)
    opt_choose_syn_fix
    opt_smart_mss           || true
    opt_basic_optimization  || true

    # Опционально: нативный conntrack control (telemt >= 3.4.20)
    opt_conntrack_control   || true

    # Firewall — открыть порт, но ПОТОМ убрать standalone ACCEPT
    # чтобы трафик шёл через SYN FIX
    opt_firewall           || true

    # Если SYN FIX установлен (нативный или внешний) — убрать standalone
    # ACCEPT для прокси-порта (opt_firewall добавляет ACCEPT на позицию 1,
    # обходя SYN FIX)
    if _is_any_syn_fix_active; then
        while iptables -D INPUT -p tcp --dport "$proxy_port" -j ACCEPT 2>/dev/null; do :; done
        msg_ok "Standalone ACCEPT ${proxy_port} удалён (трафик идёт через SYN FIX)"

        # Убедиться что conntrack ESTABLISHED,RELATED есть (для ответных пакетов)
        if ! iptables -C INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; then
            iptables -I INPUT 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
            msg_ok "Добавлен conntrack ESTABLISHED,RELATED"
        fi

        # Сохранить
        if command -v netfilter-persistent &>/dev/null; then
            netfilter-persistent save >> "$LOG_FILE" 2>&1
        elif command -v iptables-save &>/dev/null; then
            mkdir -p /etc/iptables
            iptables-save > /etc/iptables/rules.v4 2>/dev/null
        fi
    fi

    echo ""
    msg_ok "Все фиксы DPI применены"

    draw_info_box 62 \
        "${C_BOLD}Применённые оптимизации:${C_RESET}" \
        "" \
        " ${CHECK} SYN FIX: нативный synlimit telemt или MEKO iptables" \
        " ${CHECK} MSS: client_mss/client_mss_bulk (только handshake)" \
        " ${CHECK} BBR congestion control + TCP Fast Open" \
        " ${CHECK} sysctl: somaxconn=65535, backlog=65535, file-max=2M" \
        " ${CHECK} TCP keepalive: time=45, intvl=15, probes=3" \
        " ${CHECK} telemt: max_connections=16384, handshake=15" \
        " ${CHECK} telemt: tg_connect=30, keepalive=120 (reanimation)" \
        " ${CHECK} rst_on_close=errors" \
        " ${CHECK} LimitNOFILE=65535 (systemd override)" \
        " ${CHECK} Firewall — порты открыты"
}
