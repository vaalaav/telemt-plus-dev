#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  modules/cleaner.sh — Интеллектуальная пошаговая очистка системы
#  Аудит → детект компонентов → поочерёдное удаление с confirm_yn
# ═══════════════════════════════════════════════════════════════════

# ── Детекторы компонентов ─────────────────────────────────────────
_has_telemt() {
    [[ -f /bin/telemt ]] || systemctl cat telemt.service &>/dev/null 2>&1
}

_has_panel() {
    [[ -f /usr/local/bin/telemt-panel ]] || systemctl cat telemt-panel.service &>/dev/null 2>&1
}

_has_sitemask() {
    [[ -f /etc/nginx/sites-available/site ]] && grep -q 'selfmask\|mask_port\|telemt VPS Installer' /etc/nginx/sites-available/site 2>/dev/null
}

_has_meko_fixes() {
    [[ -f /etc/sysctl.d/99-telemt-tuning.conf ]] || \
    iptables -L MTPR_SYNFIX -n &>/dev/null 2>&1 || \
    [[ -d /etc/systemd/system/telemt.service.d ]]
}

_has_nginx() {
    command -v nginx &>/dev/null && systemctl is-active --quiet nginx 2>/dev/null
}

_has_certs() {
    command -v certbot &>/dev/null && certbot certificates 2>/dev/null | grep -q 'Certificate Name:'
}

# ── Удаление: telemt ядро ─────────────────────────────────────────
_clean_telemt() {
    msg_step "Удаление telemt"

    # Остановка
    systemctl stop telemt 2>/dev/null || true
    systemctl disable telemt 2>/dev/null || true

    # Systemd
    rm -f /etc/systemd/system/telemt.service
    rm -rf /etc/systemd/system/telemt.service.d
    systemctl daemon-reload

    # Бинарник
    rm -f /bin/telemt

    # Конфиги и данные
    rm -rf /etc/telemt /opt/telemt /opt/mtpr-simple

    # Пользователь
    if id -u telemt &>/dev/null; then
        pkill -u telemt 2>/dev/null || true
        sleep 1
        userdel -r telemt 2>/dev/null || userdel telemt 2>/dev/null || true
    fi
    getent group telemt &>/dev/null && groupdel telemt 2>/dev/null || true

    msg_ok "telemt удалён (бинарник, конфиг, сервис, пользователь)"
}

# ── Удаление: панель ──────────────────────────────────────────────
_clean_panel() {
    msg_step "Удаление telemt_panel"

    systemctl stop telemt-panel 2>/dev/null || true
    systemctl disable telemt-panel 2>/dev/null || true

    rm -f /etc/systemd/system/telemt-panel.service
    systemctl daemon-reload

    rm -f /usr/local/bin/telemt-panel
    rm -rf /etc/telemt-panel /var/lib/telemt-panel

    # Nginx конфиг панели
    rm -f /etc/nginx/sites-available/telemt-panel /etc/nginx/sites-enabled/telemt-panel
    if command -v nginx &>/dev/null; then
        nginx -t >> "$LOG_FILE" 2>&1 && systemctl reload nginx >> "$LOG_FILE" 2>&1 || true
    fi

    if id -u telemt-panel &>/dev/null; then
        pkill -u telemt-panel 2>/dev/null || true
        sleep 1
        userdel telemt-panel 2>/dev/null || true
    fi

    msg_ok "telemt_panel удалена (бинарник, конфиг, сервис, данные)"
}

# ── Удаление: selfmask (nginx конфиги, сайт, сертификаты) ────────
_clean_sitemask() {
    msg_step "Удаление selfmask"

    # Nginx конфиги
    rm -f /etc/nginx/sites-available/site /etc/nginx/sites-enabled/site
    rm -f /etc/nginx/sites-available/acme-temp /etc/nginx/sites-enabled/acme-temp

    # Восстановить default nginx
    if [[ -f /etc/nginx/sites-available/default ]]; then
        ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default 2>/dev/null || true
    fi

    if command -v nginx &>/dev/null; then
        nginx -t >> "$LOG_FILE" 2>&1 && systemctl reload nginx >> "$LOG_FILE" 2>&1 || true
    fi
    msg_ok "Nginx конфиги selfmask удалены"

    # Сайт-маска
    if [[ -d /var/www/html ]]; then
        rm -rf /var/www/html/.well-known 2>/dev/null || true
        rm -rf /var/www/html/* 2>/dev/null || true
        mkdir -p /var/www/html
        echo '<h1>Welcome to nginx!</h1>' > /var/www/html/index.html 2>/dev/null || true
        chown -R www-data:www-data /var/www/html 2>/dev/null || true
        msg_ok "/var/www/html очищен"
    fi

    # SSL-сертификаты
    if command -v certbot &>/dev/null; then
        local certs
        certs=$(certbot certificates 2>/dev/null | grep 'Certificate Name:' | awk '{print $3}')
        if [[ -n "$certs" ]]; then
            for cert_name in $certs; do
                certbot delete --cert-name "$cert_name" --non-interactive >> "$LOG_FILE" 2>&1 && \
                    msg_ok "Сертификат удалён: ${cert_name}" || \
                    msg_warn "Не удалось удалить: ${cert_name}"
            done
        fi
    fi

    # certbot cron
    if crontab -l 2>/dev/null | grep -q 'certbot renew'; then
        crontab -l 2>/dev/null | grep -v 'certbot renew' | crontab - 2>/dev/null || true
        msg_ok "Cron certbot удалён"
    fi

    # Nginx — предложить остановить/удалить
    if _has_nginx; then
        echo ""
        echo -e "    ${C_BOLD}[1]${C_RESET} Остановить Nginx (можно включить позже)"
        echo -e "    ${C_BOLD}[2]${C_RESET} Полностью удалить Nginx"
        echo -e "    ${C_BOLD}[3]${C_RESET} Оставить Nginx"
        local ng=""
        while true; do
            echo -ne "  ${C_BOLD}Nginx${C_RESET} [1/2/3]: "
            read -r ng </dev/tty || true
            case "$ng" in
                1) systemctl stop nginx; systemctl disable nginx >> "$LOG_FILE" 2>&1; msg_ok "Nginx остановлен"; break ;;
                2) systemctl stop nginx 2>/dev/null; apt-get remove -y nginx nginx-common >> "$LOG_FILE" 2>&1; msg_ok "Nginx удалён"; break ;;
                3) msg_info "Nginx оставлен"; break ;;
                *) msg_warn "Введите 1, 2 или 3" ;;
            esac
        done
    fi

    msg_ok "Selfmask удалён"
}

# ── Удаление: фиксы MEKO ─────────────────────────────────────────
_clean_meko_fixes() {
    msg_step "Откат фиксов MEKO"

    # iptables SYN FIX
    local chain="MTPR_SYNFIX"
    if iptables -L "$chain" -n &>/dev/null; then
        iptables -D INPUT -j "$chain" 2>/dev/null || true
        iptables -F "$chain" 2>/dev/null || true
        iptables -X "$chain" 2>/dev/null || true
        msg_ok "iptables: цепочка ${chain} удалена"
    fi

    # Удалить standalone ACCEPT для прокси-портов (если остались)
    local old_port=""
    [[ -f /opt/mtpr-simple/port ]] && old_port=$(cat /opt/mtpr-simple/port 2>/dev/null)
    if [[ -n "$old_port" ]]; then
        while iptables -D INPUT -p tcp --dport "$old_port" -j ACCEPT 2>/dev/null; do :; done
    fi

    # Сбросить INPUT policy на ACCEPT
    local policy
    policy=$(iptables -L INPUT -n 2>/dev/null | head -1 | awk -F'[()]' '{print $2}') || true
    if [[ "$policy" == "DROP" ]]; then
        iptables -P INPUT ACCEPT
        iptables -P FORWARD ACCEPT
        iptables -P OUTPUT ACCEPT
        msg_ok "iptables: policy сброшен на ACCEPT"
    fi

    # Сохранить iptables
    mkdir -p /etc/iptables
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save >> "$LOG_FILE" 2>&1
    elif command -v iptables-save &>/dev/null; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null
    fi

    # nftables таблицы telemt
    if command -v nft &>/dev/null; then
        local nft_tables
        nft_tables=$(nft list tables 2>/dev/null | grep -i 'telemt\|mtpr\|syn_limit' | awk '{print $2, $3}') || true
        if [[ -n "$nft_tables" ]]; then
            while IFS=' ' read -r family table; do
                nft delete table "$family" "$table" 2>/dev/null || true
            done <<< "$nft_tables"
        fi
        for tbl in telemt_limit telemt_ios2_fix telemt_synlimit; do
            nft delete table inet "$tbl" 2>/dev/null || true
            nft delete table ip "$tbl" 2>/dev/null || true
        done
        msg_ok "nftables: telemt-таблицы очищены"
    fi

    # sysctl
    local sysctl_files=(
        /etc/sysctl.d/99-telemt-tuning.conf
        /etc/sysctl.d/99-custom.conf
        /etc/sysctl.d/99-tg-keepalive.conf
        /etc/sysctl.d/99-bbr.conf
    )
    for f in "${sysctl_files[@]}"; do
        [[ -f "$f" ]] && rm -f "$f"
    done
    sysctl --system >> "$LOG_FILE" 2>&1
    msg_ok "sysctl: возвращён к дефолтам Ubuntu 24.04"

    # systemd override (LimitNOFILE)
    rm -rf /etc/systemd/system/telemt.service.d 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true

    msg_ok "Фиксы MEKO откачены"
}

# ══════════════════════════════════════════════════════════════════
#  Главная точка входа: аудит → пошаговый демонтаж
# ══════════════════════════════════════════════════════════════════
cleaner_run() {
    msg_header "Аудит и очистка системы"

    # ── Аудит ─────────────────────────────────────────────────────
    local found_telemt=false found_panel=false found_mask=false found_meko=false
    local found_count=0

    echo ""
    echo -e "  ${C_BOLD}Обнаруженные компоненты:${C_RESET}"
    echo -e "  ${C_DIM}────────────────────────${C_RESET}"

    if _has_telemt; then
        echo -e "    ${C_GREEN}${CHECK}${C_RESET} ${C_BOLD}telemt${C_RESET} — ядро прокси"
        found_telemt=true; ((found_count++))
    fi

    if _has_panel; then
        echo -e "    ${C_GREEN}${CHECK}${C_RESET} ${C_BOLD}telemt_panel${C_RESET} — панель управления"
        found_panel=true; ((found_count++))
    fi

    if _has_sitemask; then
        echo -e "    ${C_GREEN}${CHECK}${C_RESET} ${C_BOLD}selfmask${C_RESET} — маскировка (Nginx + SSL + сайт)"
        found_mask=true; ((found_count++))
    fi

    if _has_meko_fixes; then
        echo -e "    ${C_GREEN}${CHECK}${C_RESET} ${C_BOLD}MEKO фиксы${C_RESET} — SYN FIX, sysctl, LimitNOFILE"
        found_meko=true; ((found_count++))
    fi

    if [[ $found_count -eq 0 ]]; then
        echo -e "    ${C_DIM}Ничего не найдено — система чистая${C_RESET}"
        echo ""
        return 0
    fi

    echo ""
    msg_info "Найдено компонентов: ${C_BOLD}${found_count}${C_RESET}"
    echo ""

    # ── Пошаговое удаление ────────────────────────────────────────

    if [[ "$found_panel" == "true" ]]; then
        if confirm_yn "  ${C_BOLD}Удалить панель управления telemt_panel?${C_RESET}" "n"; then
            _clean_panel
        else
            msg_info "telemt_panel — оставлена"
        fi
        echo ""
    fi

    if [[ "$found_mask" == "true" ]]; then
        if confirm_yn "  ${C_BOLD}Удалить selfmask (сайт, SSL, Nginx конфиги)?${C_RESET}" "n"; then
            _clean_sitemask
        else
            msg_info "Selfmask — оставлен"
        fi
        echo ""
    fi

    if [[ "$found_meko" == "true" ]]; then
        if confirm_yn "  ${C_BOLD}Откатить фиксы MEKO (sysctl, iptables, nftables)?${C_RESET}" "n"; then
            _clean_meko_fixes
        else
            msg_info "Фиксы MEKO — оставлены"
        fi
        echo ""
    fi

    if [[ "$found_telemt" == "true" ]]; then
        if confirm_yn "  ${C_RED}${C_BOLD}Удалить ядро telemt (бинарник, конфиг, сервис)?${C_RESET}" "n"; then
            _clean_telemt
        else
            msg_info "telemt — оставлен"
        fi
        echo ""
    fi

    # ── Логи инсталлятора ─────────────────────────────────────────
    if confirm_yn "  ${C_BOLD}Удалить логи инсталлятора?${C_RESET}" "n"; then
        rm -rf /var/log/telemt-installer 2>/dev/null || true
        msg_ok "Логи удалены"
    fi

    echo ""
    msg_ok "Очистка завершена"
}
