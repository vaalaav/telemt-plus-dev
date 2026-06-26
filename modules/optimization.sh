#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  modules/optimization.sh — Оптимизация и фиксы DPI для telemt
#  Источники: MTproxy-reanimation, MTPROTO_FIX_By_MEKO, community
# ═══════════════════════════════════════════════════════════════════

# ── Константы ─────────────────────────────────────────────────────
OPT_SYSCTL_FILE="/etc/sysctl.d/99-telemt-tuning.conf"
OPT_NFT_TABLE="telemt_limit"
OPT_NFT_SCRIPT="/usr/local/sbin/telemt-syn-limit.sh"
OPT_NFT_SERVICE="telemt-syn-limit"
OPT_NFT_SERVICE_FILE="/etc/systemd/system/${OPT_NFT_SERVICE}.service"
OPT_IOS2_NFT_TABLE="telemt_ios2_fix"
OPT_BACKUP_DIR="/opt/telemt/backups"

# Параметры по умолчанию
OPT_NFT_RATE="1/second"
OPT_NFT_BURST="1"
OPT_NFT_METER_TIMEOUT="60s"
OPT_TUNING_TG_CONNECT="30"
OPT_TUNING_CLIENT_HANDSHAKE="90"
OPT_TUNING_CLIENT_KEEPALIVE="120"
OPT_IOS2_EXTERNAL_PORT="4443"
OPT_IOS2_MSS="92"

# ── Определение порта telemt ──────────────────────────────────────
_opt_detect_port() {
    local port=""
    # Из переменной telemt_core (если загружен)
    if [[ -n "${TELEMT_PORT:-}" ]]; then
        echo "$TELEMT_PORT"
        return 0
    fi
    # Из конфига
    local cfg=""
    for f in /etc/telemt/telemt.toml /etc/telemt/config.toml; do
        [[ -f "$f" ]] && cfg="$f" && break
    done
    if [[ -n "$cfg" ]]; then
        port=$(awk '/^port[[:space:]]*=/ { gsub(/[^0-9]/, "", $3); print $3; exit }' "$cfg" 2>/dev/null)
    fi
    if [[ -z "$port" ]]; then
        port="443"
    fi
    echo "$port"
}

# Определение конфига telemt
_opt_detect_config() {
    if [[ -n "${TELEMT_CONFIG:-}" && -f "${TELEMT_CONFIG:-}" ]]; then
        echo "$TELEMT_CONFIG"
        return
    fi
    for f in /etc/telemt/telemt.toml /etc/telemt/config.toml /opt/telemt/telemt.toml; do
        if [[ -f "$f" ]]; then
            echo "$f"
            return
        fi
    done
}

# ── TOML-утилиты ─────────────────────────────────────────────────
_toml_get() {
    local key="$1" file="$2"
    [[ -f "$file" ]] || return
    awk -v k="$key" '
        /^[[:space:]]*#/ { next }
        $1 == k && $2 == "=" { gsub(/[^0-9]/, "", $3); print $3; exit }
    ' "$file" 2>/dev/null
}

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
    # Добавить секцию и ключ
    echo -e "\n[${section}]\n${key} = ${value}" >> "$file"
    return 0
}

# ══════════════════════════════════════════════════════════════════
#  Фикс 1: SYN Rate Limiting (nftables)
#  Источник: MTproxy-reanimation — inbound SYN limiter
#  Цель: Защита от SYN-флуда, который DPI может использовать для
#  fingerprinting и срыва соединений
# ══════════════════════════════════════════════════════════════════
opt_syn_limiter() {
    msg_step "SYN Rate Limiter (nftables)"

    # Проверка nftables
    if ! command -v nft &>/dev/null; then
        msg_info "Установка nftables..."
        run_with_spinner "apt install nftables" apt-get install -y -qq nftables || {
            msg_err "Не удалось установить nftables"
            return 1
        }
    fi

    local port
    port=$(_opt_detect_port)
    msg_info "Порт telemt: ${port}"

    # Запрос параметров
    draw_info_box 58 \
        "SYN Rate Limiter ограничивает число входящих TCP SYN" \
        "с одного IP на порту прокси. Защищает от SYN-флуда" \
        "и зондирования DPI-систем." \
        "" \
        "Rate:    ${C_WHITE}${OPT_NFT_RATE}${C_RESET} (SYN в секунду с 1 IP)" \
        "Burst:   ${C_WHITE}${OPT_NFT_BURST}${C_RESET} (допустимый всплеск)" \
        "Timeout: ${C_WHITE}${OPT_NFT_METER_TIMEOUT}${C_RESET} (сброс счётчика)"

    if confirm_yn "Изменить параметры?" "n"; then
        prompt_input "Rate (формат: N/second)" OPT_NFT_RATE '^[0-9]+/second$' "$OPT_NFT_RATE"
        prompt_input "Burst" OPT_NFT_BURST '^[0-9]+$' "$OPT_NFT_BURST"
        prompt_input "Meter timeout" OPT_NFT_METER_TIMEOUT '^[0-9]+[smh]$' "$OPT_NFT_METER_TIMEOUT"
    fi

    # Генерация nft-скрипта
    mkdir -p "$(dirname "$OPT_NFT_SCRIPT")"
    cat > "$OPT_NFT_SCRIPT" << NFTEOF
#!/usr/bin/env bash
# telemt SYN rate limiter — сгенерировано telemt VPS Installer
set -e

nft delete table inet ${OPT_NFT_TABLE} 2>/dev/null || true

nft -f - << 'NFT'
table inet ${OPT_NFT_TABLE} {
    chain input {
        type filter hook input priority filter - 1; policy accept;

        # Пропустить loopback
        iif "lo" accept

        # SYN rate limit на порту прокси
        tcp dport ${port} tcp flags syn \
            meter syn_meter { ip saddr timeout ${OPT_NFT_METER_TIMEOUT} limit rate ${OPT_NFT_RATE} burst ${OPT_NFT_BURST} packets } \
            accept

        # Дропнуть SYN сверх лимита
        tcp dport ${port} tcp flags syn drop
    }
}
NFT
NFTEOF
    chmod +x "$OPT_NFT_SCRIPT"

    # Systemd-сервис для автоприменения
    cat > "$OPT_NFT_SERVICE_FILE" << SVCEOF
[Unit]
Description=Telemt SYN Rate Limiter (nftables)
After=network-online.target nftables.service
Before=telemt.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${OPT_NFT_SCRIPT}
ExecStop=/usr/sbin/nft delete table inet ${OPT_NFT_TABLE}

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload

    # Применить
    if run_with_spinner "Применение SYN limiter" bash "$OPT_NFT_SCRIPT"; then
        systemctl enable "$OPT_NFT_SERVICE" >> "$LOG_FILE" 2>&1
        rollback_push "systemctl stop ${OPT_NFT_SERVICE} 2>/dev/null; systemctl disable ${OPT_NFT_SERVICE} 2>/dev/null; rm -f '${OPT_NFT_SERVICE_FILE}' '${OPT_NFT_SCRIPT}'; nft delete table inet ${OPT_NFT_TABLE} 2>/dev/null; systemctl daemon-reload"
        msg_ok "SYN limiter активен (порт ${port}, rate ${OPT_NFT_RATE}, burst ${OPT_NFT_BURST})"
    else
        msg_err "Не удалось применить nftables правила"
        return 1
    fi
}

# ══════════════════════════════════════════════════════════════════
#  Фикс 2: Тюнинг таймаутов Telemt
#  Источник: MTproxy-reanimation — tuning manager
#  tg_connect — таймаут соединения с DC Telegram
#  client_handshake — допуск на TLS-хендшейк
#  client_keepalive — keepalive для клиентского соединения
# ══════════════════════════════════════════════════════════════════
opt_telemt_tuning() {
    msg_step "Тюнинг таймаутов Telemt"

    local cfg
    cfg=$(_opt_detect_config)
    if [[ -z "$cfg" ]]; then
        msg_warn "Конфиг telemt не найден — вручную добавьте параметры:"
        echo ""
        echo "  [general]"
        echo "  tg_connect = ${OPT_TUNING_TG_CONNECT}"
        echo ""
        echo "  [timeouts]"
        echo "  client_handshake = ${OPT_TUNING_CLIENT_HANDSHAKE}"
        echo "  client_keepalive = ${OPT_TUNING_CLIENT_KEEPALIVE}"
        echo ""
        return 0
    fi

    msg_info "Конфиг: ${cfg}"

    draw_info_box 58 \
        "Тюнинг таймаутов стабилизирует соединения:" \
        "" \
        "tg_connect:       ${C_WHITE}${OPT_TUNING_TG_CONNECT}s${C_RESET}  (подключение к DC)" \
        "client_handshake: ${C_WHITE}${OPT_TUNING_CLIENT_HANDSHAKE}s${C_RESET} (TLS handshake)" \
        "client_keepalive: ${C_WHITE}${OPT_TUNING_CLIENT_KEEPALIVE}s${C_RESET} (keepalive клиента)"

    if confirm_yn "Изменить значения?" "n"; then
        prompt_input "tg_connect (сек)" OPT_TUNING_TG_CONNECT '^[0-9]+$' "$OPT_TUNING_TG_CONNECT"
        prompt_input "client_handshake (сек)" OPT_TUNING_CLIENT_HANDSHAKE '^[0-9]+$' "$OPT_TUNING_CLIENT_HANDSHAKE"
        prompt_input "client_keepalive (сек)" OPT_TUNING_CLIENT_KEEPALIVE '^[0-9]+$' "$OPT_TUNING_CLIENT_KEEPALIVE"
    fi

    # Бэкап
    mkdir -p "$OPT_BACKUP_DIR"
    cp "$cfg" "${OPT_BACKUP_DIR}/$(basename "$cfg").pre-tuning.$(date +%s)"
    rollback_push "cp '${OPT_BACKUP_DIR}/$(basename "$cfg").pre-tuning.'* '${cfg}' 2>/dev/null || true"

    local changed=false

    local cur; cur=$(_toml_get "tg_connect" "$cfg")
    if [[ "$cur" != "$OPT_TUNING_TG_CONNECT" ]]; then
        _toml_set "tg_connect" "$OPT_TUNING_TG_CONNECT" "general" "$cfg"
        msg_ok "tg_connect = ${OPT_TUNING_TG_CONNECT}"
        changed=true
    else
        msg_info "tg_connect уже ${OPT_TUNING_TG_CONNECT}"
    fi

    cur=$(_toml_get "client_handshake" "$cfg")
    if [[ "$cur" != "$OPT_TUNING_CLIENT_HANDSHAKE" ]]; then
        _toml_set "client_handshake" "$OPT_TUNING_CLIENT_HANDSHAKE" "timeouts" "$cfg"
        msg_ok "client_handshake = ${OPT_TUNING_CLIENT_HANDSHAKE}"
        changed=true
    else
        msg_info "client_handshake уже ${OPT_TUNING_CLIENT_HANDSHAKE}"
    fi

    cur=$(_toml_get "client_keepalive" "$cfg")
    if [[ "$cur" != "$OPT_TUNING_CLIENT_KEEPALIVE" ]]; then
        _toml_set "client_keepalive" "$OPT_TUNING_CLIENT_KEEPALIVE" "timeouts" "$cfg"
        msg_ok "client_keepalive = ${OPT_TUNING_CLIENT_KEEPALIVE}"
        changed=true
    else
        msg_info "client_keepalive уже ${OPT_TUNING_CLIENT_KEEPALIVE}"
    fi

    # Перезапуск при изменениях
    if [[ "$changed" == "true" ]]; then
        if systemctl is-active --quiet telemt 2>/dev/null; then
            run_with_spinner "Перезапуск telemt" systemctl restart telemt
        fi
    fi
}

# ══════════════════════════════════════════════════════════════════
#  Фикс 3: iOS TCP Keepalive Fix (sysctl)
#  Источник: MTproxy-reanimation — iOS fix вариант 1
#  iOS-клиенты рвут соединение из-за агрессивных таймаутов
#  Уменьшаем TCP keepalive для быстрого обнаружения разрывов
# ══════════════════════════════════════════════════════════════════
opt_ios_keepalive_fix() {
    msg_step "iOS TCP Keepalive Fix (sysctl)"

    local ka_time=60 ka_intvl=10 ka_probes=6

    draw_info_box 58 \
        "iOS-клиенты часто теряют соединение из-за" \
        "стандартных таймаутов TCP keepalive (7200s)." \
        "Снижаем до агрессивных значений:" \
        "" \
        "keepalive_time:     ${C_WHITE}${ka_time}s${C_RESET}" \
        "keepalive_intvl:    ${C_WHITE}${ka_intvl}s${C_RESET}" \
        "keepalive_probes:   ${C_WHITE}${ka_probes}${C_RESET}"

    if confirm_yn "Изменить значения?" "n"; then
        prompt_input "keepalive_time (сек)" ka_time '^[0-9]+$' "$ka_time"
        prompt_input "keepalive_intvl (сек)" ka_intvl '^[0-9]+$' "$ka_intvl"
        prompt_input "keepalive_probes" ka_probes '^[0-9]+$' "$ka_probes"
    fi

    cat > "$OPT_SYSCTL_FILE" << SYSCTLEOF
# telemt TCP tuning — сгенерировано telemt VPS Installer
# iOS keepalive fix
net.ipv4.tcp_keepalive_time = ${ka_time}
net.ipv4.tcp_keepalive_intvl = ${ka_intvl}
net.ipv4.tcp_keepalive_probes = ${ka_probes}

# Оптимизация TCP-стека для прокси
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096
net.core.netdev_max_backlog = 4096

# TCP window scaling и буферы
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

# MTU probing (помогает обойти PMTUD-блокировку DPI)
net.ipv4.tcp_mtu_probing = 1

# Защита от SYN-flood на уровне ядра
net.ipv4.tcp_syncookies = 1
SYSCTLEOF

    rollback_push "rm -f '${OPT_SYSCTL_FILE}'; sysctl --system >> '${LOG_FILE}' 2>&1"

    if run_with_spinner "Применение sysctl" sysctl -p "$OPT_SYSCTL_FILE"; then
        msg_ok "TCP-параметры применены"
    else
        msg_warn "Некоторые параметры могут не поддерживаться ядром"
    fi
}

# ══════════════════════════════════════════════════════════════════
#  Фикс 4: iOS MSS Clamping + Port Redirect
#  Источник: MTproxy-reanimation — iOS fix вариант 2
#  Некоторые iOS-клиенты плохо работают с большим MSS.
#  Создаём отдельный порт с принудительным MSS=92 для iOS.
# ══════════════════════════════════════════════════════════════════
opt_ios_mss_fix() {
    msg_step "iOS MSS Fix (опционально)"

    draw_info_box 58 \
        "MSS clamping создаёт дополнительный порт для" \
        "iOS-клиентов с уменьшенным TCP MSS." \
        "Это помогает в сетях с агрессивным DPI." \
        "" \
        "Внешний порт iOS: ${C_WHITE}${OPT_IOS2_EXTERNAL_PORT}${C_RESET}" \
        "MSS:              ${C_WHITE}${OPT_IOS2_MSS}${C_RESET}"

    if ! confirm_yn "Включить MSS fix для iOS?" "n"; then
        msg_info "Пропущено"
        return 0
    fi

    local telemt_port
    telemt_port=$(_opt_detect_port)

    prompt_input "Внешний порт для iOS" OPT_IOS2_EXTERNAL_PORT '^[0-9]+$' "$OPT_IOS2_EXTERNAL_PORT"
    prompt_input "MSS значение" OPT_IOS2_MSS '^[0-9]+$' "$OPT_IOS2_MSS"

    # nftables правила для MSS clamping + DNAT redirect
    local nft_ios_script="/usr/local/sbin/telemt-ios-mss.sh"
    cat > "$nft_ios_script" << IOSEOF
#!/usr/bin/env bash
# telemt iOS MSS fix — nftables
set -e

nft delete table ip ${OPT_IOS2_NFT_TABLE} 2>/dev/null || true

nft -f - << 'NFT'
table ip ${OPT_IOS2_NFT_TABLE} {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        tcp dport ${OPT_IOS2_EXTERNAL_PORT} redirect to :${telemt_port}
    }

    chain postrouting {
        type filter hook postrouting priority mangle; policy accept;
        tcp sport ${telemt_port} tcp flags syn,rst \
            tcp option maxseg size set ${OPT_IOS2_MSS}
    }
}
NFT
IOSEOF
    chmod +x "$nft_ios_script"

    if run_with_spinner "Применение iOS MSS fix" bash "$nft_ios_script"; then
        rollback_push "nft delete table ip ${OPT_IOS2_NFT_TABLE} 2>/dev/null; rm -f '${nft_ios_script}'"

        # Открыть порт в firewall если ufw активен
        if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
            ufw allow "${OPT_IOS2_EXTERNAL_PORT}/tcp" >> "$LOG_FILE" 2>&1 || true
            rollback_push "ufw delete allow ${OPT_IOS2_EXTERNAL_PORT}/tcp 2>/dev/null || true"
        fi

        msg_ok "iOS MSS fix активен (порт ${OPT_IOS2_EXTERNAL_PORT} → ${telemt_port}, MSS=${OPT_IOS2_MSS})"
        msg_info "Для iOS-клиентов используйте порт ${C_WHITE}${OPT_IOS2_EXTERNAL_PORT}${C_RESET} в ссылке"
    else
        msg_err "Не удалось применить MSS fix"
        return 1
    fi
}

# ══════════════════════════════════════════════════════════════════
#  Фикс 5: Firewall — открытие портов
# ══════════════════════════════════════════════════════════════════
opt_firewall() {
    msg_step "Настройка firewall"

    local port
    port=$(_opt_detect_port)

    # UFW
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        msg_info "UFW активен — открываем порт ${port}/tcp"
        ufw allow "${port}/tcp" >> "$LOG_FILE" 2>&1
        rollback_push "ufw delete allow ${port}/tcp 2>/dev/null || true"
        # API порт только для localhost — не открываем наружу
        msg_ok "UFW: порт ${port}/tcp открыт"
    elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
        msg_info "firewalld активен — открываем порт ${port}/tcp"
        firewall-cmd --permanent --add-port="${port}/tcp" >> "$LOG_FILE" 2>&1
        firewall-cmd --reload >> "$LOG_FILE" 2>&1
        rollback_push "firewall-cmd --permanent --remove-port=${port}/tcp 2>/dev/null; firewall-cmd --reload 2>/dev/null"
        msg_ok "firewalld: порт ${port}/tcp открыт"
    else
        msg_info "Активный firewall-менеджер (ufw/firewalld) не обнаружен"
        msg_info "Убедитесь, что порт ${port}/tcp открыт в настройках VPS"
    fi
}

# ══════════════════════════════════════════════════════════════════
#  Вариант для selfmask: адаптированные фиксы
#  Когда прокси работает за nginx на 443, порты делятся
# ══════════════════════════════════════════════════════════════════
apply_mtproto_fixes_selfmask() {
    msg_header "Оптимизация DPI (режим selfmask)"

    msg_info "В режиме selfmask прокси работает на внутреннем порту,"
    msg_info "а nginx принимает TLS на 443 и мультиплексирует трафик."
    echo ""

    # Тюнинг telemt (всегда применяем)
    opt_telemt_tuning || true

    # sysctl TCP-оптимизация (всегда применяем)
    opt_ios_keepalive_fix || true

    # SYN limiter на порт 443 (nginx)
    msg_info "SYN limiter будет настроен на внешний порт 443 (nginx)"
    local save_port="${TELEMT_PORT:-}"
    TELEMT_PORT="443"
    opt_syn_limiter || true
    TELEMT_PORT="$save_port"

    # Firewall
    opt_firewall || true

    msg_ok "Оптимизация selfmask завершена"
}

# ══════════════════════════════════════════════════════════════════
#  Главная точка входа: стандартные фиксы
# ══════════════════════════════════════════════════════════════════
apply_mtproto_fixes() {
    msg_header "Оптимизация и фиксы DPI"

    # 1. Тюнинг таймаутов telemt
    confirm_step "Тюнинг таймаутов Telemt" && opt_telemt_tuning || {
        local s=$?
        (( s == 2 )) && { handle_cancel; local h=$?; [[ $h -eq 0 ]] && return 10; [[ $h -eq 2 ]] && return 20; }
    }

    # 2. SYN Rate Limiter
    confirm_step "SYN Rate Limiter (nftables)" && opt_syn_limiter || {
        local s=$?
        (( s == 2 )) && { handle_cancel; local h=$?; [[ $h -eq 0 ]] && return 10; [[ $h -eq 2 ]] && return 20; }
    }

    # 3. TCP/Keepalive + сетевая оптимизация
    confirm_step "TCP Keepalive + сетевая оптимизация (sysctl)" && opt_ios_keepalive_fix || {
        local s=$?
        (( s == 2 )) && { handle_cancel; local h=$?; [[ $h -eq 0 ]] && return 10; [[ $h -eq 2 ]] && return 20; }
    }

    # 4. iOS MSS Fix (опционально)
    confirm_step "iOS MSS Fix (опциональный доп. порт)" && opt_ios_mss_fix || {
        local s=$?
        (( s == 2 )) && { handle_cancel; local h=$?; [[ $h -eq 0 ]] && return 10; [[ $h -eq 2 ]] && return 20; }
    }

    # 5. Firewall
    confirm_step "Настройка firewall" && opt_firewall || {
        local s=$?
        (( s == 2 )) && { handle_cancel; local h=$?; [[ $h -eq 0 ]] && return 10; [[ $h -eq 2 ]] && return 20; }
    }

    echo ""
    msg_ok "Все фиксы DPI применены"

    draw_info_box 58 \
        "${C_BOLD}Итого применённые оптимизации:${C_RESET}" \
        "" \
        " ${CHECK} Таймауты Telemt (tg_connect, handshake, keepalive)" \
        " ${CHECK} SYN rate limiter (nftables, per-IP)" \
        " ${CHECK} TCP keepalive (sysctl, iOS-совместимый)" \
        " ${CHECK} Оптимизация TCP-стека (буферы, backlog, MTU)" \
        " ${CHECK} Firewall — порты открыты"
}
