#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  modules/optimization.sh — Оптимизация и фиксы DPI для telemt
#  Приоритет: MTPROTO_FIX_By_MEKO (v0.74), дополнено MTproxy-reanimation
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
#  Фикс 2: Отключение MSS в конфиге Telemt (MEKO)
#  MEKO считает MSS вредным для обхода DPI — закомментирует строки
# ══════════════════════════════════════════════════════════════════
opt_disable_mss() {
    msg_step "Отключение MSS в конфиге Telemt (MEKO)"

    local cfg
    cfg=$(_opt_detect_config)
    if [[ -z "$cfg" ]]; then
        msg_info "Конфиг не найден — пропуск"
        return 0
    fi

    # Проверка: есть ли активные строки с mss
    if grep -qi 'mss' "$cfg" 2>/dev/null | grep -v '^#' | grep -q . 2>/dev/null; then
        msg_info "Обнаружены активные строки с MSS в ${cfg}"

        # Бэкап
        mkdir -p "$OPT_BACKUP_DIR"
        cp "$cfg" "${OPT_BACKUP_DIR}/$(basename "$cfg").pre-mss.$(date +%s)"
        rollback_push "cp '${OPT_BACKUP_DIR}/$(basename "$cfg").pre-mss.'* '${cfg}' 2>/dev/null || true"

        sed -i 's/^[[:space:]]*\(.*mss.*\)/#\1/i' "$cfg"
        msg_ok "MSS отключен (строки закомментированы)"
    else
        msg_info "MSS уже отключен или отсутствует"
    fi
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

    # MSS disable (MEKO)
    opt_disable_mss || true

    # Базовая оптимизация (MEKO sysctl + telemt tuning)
    opt_basic_optimization || true

    # SYN FIX — MEKO оригинал на порт 443 (выполняется молча)
    local save_port="${TELEMT_PORT:-}"
    TELEMT_PORT="443"
    opt_syn_fix || msg_warn "SYN FIX — ошибка (пропущен)"
    TELEMT_PORT="$save_port"

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
        " ${CHECK} MSS отключен в конфиге telemt" \
        " ${CHECK} BBR + TCP Fast Open + somaxconn=65535" \
        " ${CHECK} TCP keepalive: time=45, intvl=15, probes=3" \
        " ${CHECK} telemt: max_connections=16384, handshake=15" \
        " ${CHECK} LimitNOFILE=65535 (systemd override)" \
        " ${CHECK} SYN FIX MEKO (54/min) — standalone ACCEPT убран" \
        " ${CHECK} Порт 80 открыт (ACME), 443 через SYN FIX"
}

# ══════════════════════════════════════════════════════════════════
#  Главная точка входа: стандартные фиксы
# ══════════════════════════════════════════════════════════════════
apply_mtproto_fixes() {
    msg_header "Оптимизация и фиксы DPI"

    local proxy_port
    proxy_port=$(_opt_detect_port)

    # Все шаги молча
    opt_syn_fix            || msg_warn "SYN FIX — ошибка (пропущен)"
    opt_disable_mss        || true
    opt_basic_optimization || true

    # Firewall — открыть порт, но ПОТОМ убрать standalone ACCEPT
    # чтобы трафик шёл через SYN FIX
    opt_firewall           || true

    # Если SYN FIX установлен — убрать standalone ACCEPT для прокси-порта
    # (opt_firewall добавляет ACCEPT на позицию 1, обходя SYNFIX)
    if _is_syn_fix_installed; then
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
        " ${CHECK} SYN FIX (MEKO): iptables 4-правила, iOS+общий" \
        " ${CHECK} MSS отключен в конфиге telemt" \
        " ${CHECK} BBR congestion control + TCP Fast Open" \
        " ${CHECK} sysctl: somaxconn=65535, backlog=65535, file-max=2M" \
        " ${CHECK} TCP keepalive: time=45, intvl=15, probes=3" \
        " ${CHECK} telemt: max_connections=16384, handshake=15" \
        " ${CHECK} telemt: tg_connect=30, keepalive=120 (reanimation)" \
        " ${CHECK} LimitNOFILE=65535 (systemd override)" \
        " ${CHECK} Firewall — порты открыты"
}
