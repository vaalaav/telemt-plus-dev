#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  modules/cleaner.sh — Полная очистка всех компонентов проекта
# ═══════════════════════════════════════════════════════════════════

cleaner_run() {
    msg_header "Полная очистка системы"

    msg_warn "Будут удалены ВСЕ компоненты, установленные этим проектом:"
    echo ""
    echo -e "    ${C_RED}•${C_RESET} telemt (бинарник, конфиг, сервис, пользователь)"
    echo -e "    ${C_RED}•${C_RESET} telemt_panel (бинарник, конфиг, сервис, пользователь)"
    echo -e "    ${C_RED}•${C_RESET} Nginx конфиги сайта-маски"
    echo -e "    ${C_RED}•${C_RESET} Let's Encrypt сертификаты"
    echo -e "    ${C_RED}•${C_RESET} Сайт-маска (/var/www/html)"
    echo -e "    ${C_RED}•${C_RESET} iptables SYN FIX (цепочка MTPR_SYNFIX)"
    echo -e "    ${C_RED}•${C_RESET} sysctl оптимизации"
    echo -e "    ${C_RED}•${C_RESET} systemd override (LimitNOFILE)"
    echo ""

    if ! confirm_yn "${C_RED}${C_BOLD}Вы уверены? Это действие необратимо!${C_RESET}" "n"; then
        msg_info "Очистка отменена"
        return 0
    fi

    # ── 1. Остановка сервисов ─────────────────────────────────────
    msg_step "Остановка сервисов"

    for svc in telemt telemt-panel telemt-syn-limit; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            systemctl stop "$svc" >> "$LOG_FILE" 2>&1
            msg_ok "Остановлен: ${svc}"
        fi
        if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
            systemctl disable "$svc" >> "$LOG_FILE" 2>&1
        fi
    done

    # ── 2. Удаление systemd-юнитов ───────────────────────────────
    msg_step "Удаление systemd-юнитов"

    local units=(
        /etc/systemd/system/telemt.service
        /etc/systemd/system/telemt-panel.service
        /etc/systemd/system/telemt-syn-limit.service
    )
    for u in "${units[@]}"; do
        if [[ -f "$u" ]]; then
            rm -f "$u"
            msg_ok "Удалён: $(basename "$u")"
        fi
    done

    # systemd override
    rm -rf /etc/systemd/system/telemt.service.d
    systemctl daemon-reload
    msg_ok "systemd перезагружен"

    # ── 3. Удаление бинарников ───────────────────────────────────
    msg_step "Удаление бинарников"

    for bin in /bin/telemt /usr/local/bin/telemt-panel /usr/local/sbin/telemt-syn-limit.sh /usr/local/sbin/telemt-ios-mss.sh; do
        if [[ -f "$bin" ]]; then
            rm -f "$bin"
            msg_ok "Удалён: ${bin}"
        fi
    done

    # ── 4. Удаление конфигов и данных ────────────────────────────
    msg_step "Удаление конфигов и данных"

    local dirs=(
        /etc/telemt
        /etc/telemt-panel
        /opt/telemt
        /opt/mtpr-simple
        /opt/mtproxy-reanimation
        /var/lib/telemt-panel
    )
    for d in "${dirs[@]}"; do
        if [[ -d "$d" ]]; then
            rm -rf "$d"
            msg_ok "Удалена директория: ${d}"
        fi
    done

    # ── 5. Удаление пользователей ────────────────────────────────
    msg_step "Удаление пользователей"

    for user in telemt telemt-panel; do
        if id -u "$user" &>/dev/null; then
            # Завершить все процессы пользователя
            pkill -u "$user" 2>/dev/null || true
            sleep 1
            userdel -r "$user" 2>/dev/null || userdel "$user" 2>/dev/null || true
            msg_ok "Удалён пользователь: ${user}"
        fi
    done

    for grp in telemt; do
        if getent group "$grp" &>/dev/null; then
            groupdel "$grp" 2>/dev/null || true
            msg_ok "Удалена группа: ${grp}"
        fi
    done

    # ── 6. Откат iptables SYN FIX ───────────────────────────────
    msg_step "Откат iptables SYN FIX"

    local chain="MTPR_SYNFIX"
    if iptables -L "$chain" -n &>/dev/null; then
        iptables -D INPUT -j "$chain" 2>/dev/null || true
        iptables -F "$chain" 2>/dev/null || true
        iptables -X "$chain" 2>/dev/null || true
        msg_ok "Цепочка ${chain} удалена"
    else
        msg_info "Цепочка ${chain} не найдена — пропуск"
    fi

    # Сохранить iptables
    mkdir -p /etc/iptables
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save >> "$LOG_FILE" 2>&1
    elif command -v iptables-save &>/dev/null; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null
    fi

    # Откат nftables таблиц (на случай если использовались)
    for tbl in telemt_limit telemt_ios2_fix; do
        nft delete table inet "$tbl" 2>/dev/null || true
        nft delete table ip "$tbl" 2>/dev/null || true
    done

    # ── 7. Откат sysctl ──────────────────────────────────────────
    msg_step "Откат sysctl"

    local sysctl_files=(
        /etc/sysctl.d/99-telemt-tuning.conf
        /etc/sysctl.d/99-custom.conf
        /etc/sysctl.d/99-tg-keepalive.conf
        /etc/sysctl.d/99-bbr.conf
    )
    for f in "${sysctl_files[@]}"; do
        if [[ -f "$f" ]]; then
            rm -f "$f"
            msg_ok "Удалён: ${f}"
        fi
    done
    sysctl --system >> "$LOG_FILE" 2>&1
    msg_ok "sysctl сброшен к дефолтам"

    # ── 8. Очистка Nginx ─────────────────────────────────────────
    msg_step "Очистка Nginx"

    local nginx_files=(
        /etc/nginx/sites-available/site
        /etc/nginx/sites-available/telemt-panel
        /etc/nginx/sites-available/acme-temp
        /etc/nginx/sites-enabled/site
        /etc/nginx/sites-enabled/telemt-panel
        /etc/nginx/sites-enabled/acme-temp
    )
    local nginx_changed=false
    for f in "${nginx_files[@]}"; do
        if [[ -e "$f" ]]; then
            rm -f "$f"
            msg_ok "Удалён: $(basename "$f")"
            nginx_changed=true
        fi
    done

    if [[ "$nginx_changed" == "true" ]]; then
        # Восстановить default конфиг nginx
        if [[ -f /etc/nginx/sites-available/default ]]; then
            ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default 2>/dev/null || true
            msg_ok "Восстановлен nginx default"
        fi
        if command -v nginx &>/dev/null; then
            nginx -t >> "$LOG_FILE" 2>&1 && systemctl reload nginx >> "$LOG_FILE" 2>&1 || \
                msg_warn "nginx -t failed — проверьте конфигурацию вручную"
        fi
    else
        msg_info "Nginx конфиги проекта не найдены"
    fi

    # Очистка /var/www/html (сайт-маска + .well-known)
    if confirm_yn "Очистить /var/www/html (сайт-маска)?" "y"; then
        rm -rf /var/www/html/.well-known 2>/dev/null || true
        rm -rf /var/www/html/* 2>/dev/null || true
        # Восстановить дефолтную страницу nginx
        mkdir -p /var/www/html
        cat > /var/www/html/index.html << 'DEFHTML'
<!doctype html><html><head><title>Welcome to nginx!</title></head>
<body><h1>Welcome to nginx!</h1><p>If you see this page, nginx is installed.</p></body></html>
DEFHTML
        chown -R www-data:www-data /var/www/html 2>/dev/null || true
        msg_ok "/var/www/html очищен и восстановлен"
    fi

    # ── 9. Let's Encrypt сертификаты ─────────────────────────────
    msg_step "Let's Encrypt сертификаты"

    if command -v certbot &>/dev/null; then
        local certs
        certs=$(certbot certificates 2>/dev/null | grep 'Certificate Name:' | awk '{print $3}')
        if [[ -n "$certs" ]]; then
            msg_info "Найденные сертификаты:"
            for cert_name in $certs; do
                echo -e "    ${C_YELLOW}•${C_RESET} ${cert_name}"
            done
            if confirm_yn "Удалить сертификаты Let's Encrypt?" "n"; then
                for cert_name in $certs; do
                    certbot delete --cert-name "$cert_name" --non-interactive >> "$LOG_FILE" 2>&1 && \
                        msg_ok "Удалён сертификат: ${cert_name}" || \
                        msg_warn "Не удалось удалить: ${cert_name}"
                done
            fi
        else
            msg_info "Сертификаты не найдены"
        fi

        # Удалить cron записи certbot renew если были добавлены нами
        if crontab -l 2>/dev/null | grep -q 'certbot renew'; then
            crontab -l 2>/dev/null | grep -v 'certbot renew' | crontab - 2>/dev/null || true
            msg_ok "Cron для certbot renew удалён"
        fi
    else
        msg_info "certbot не установлен — пропуск"
    fi

    # ── 10. Логи ─────────────────────────────────────────────────
    msg_step "Очистка логов"
    rm -rf /var/log/telemt-installer 2>/dev/null || true
    msg_ok "Логи инсталлятора удалены"

    # ── Итог ─────────────────────────────────────────────────────
    echo ""
    msg_ok "Полная очистка завершена"
    draw_info_box 58 \
        "${C_BOLD}Удалено:${C_RESET}" \
        "" \
        " ${CHECK} Сервисы telemt, telemt-panel" \
        " ${CHECK} Бинарники, конфиги, данные" \
        " ${CHECK} Пользователи и группы" \
        " ${CHECK} iptables SYN FIX" \
        " ${CHECK} sysctl оптимизации" \
        " ${CHECK} Nginx конфиги selfmask" \
        " ${CHECK} Логи инсталлятора"
}
