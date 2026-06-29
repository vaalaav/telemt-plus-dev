#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  main.sh — Главный управляющий скрипт telemt VPS Installer
#  Запуск: sudo bash main.sh
# ═══════════════════════════════════════════════════════════════════
# НЕ используем set -euo pipefail в интерактивном скрипте —
# read, confirm, status-check возвращают ненулевые коды штатно
set -o pipefail

# ── Определение корня проекта ─────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PROJECT_DIR="$SCRIPT_DIR"
export MODULES_DIR="${PROJECT_DIR}/modules"

# ── Подключение модулей ───────────────────────────────────────────
source "${MODULES_DIR}/utils.sh"

# Подгружаемые по вызову (lazy source):
_load_module() {
    local mod="${MODULES_DIR}/${1}.sh"
    if [[ -f "$mod" ]]; then
        source "$mod"
        log_raw "MODULE LOADED: $1"
    else
        msg_err "Модуль не найден: $mod"
        return 1
    fi
}

# ── Версия ────────────────────────────────────────────────────────
readonly INSTALLER_VERSION="1.0.0"
readonly INSTALLER_NAME="telemt VPS Installer"

# ── ASCII-логотип ─────────────────────────────────────────────────
print_logo() {
    echo -e "${C_CYAN}"
    cat << 'LOGO'
    ╔╦╗╔═╗╦  ╔═╗╔╦╗╔╦╗  ╦╔╗╔╔═╗╔╦╗╔═╗╦  ╦  ╔═╗╦═╗
     ║ ║╣ ║  ║╣ ║║║ ║   ║║║║╚═╗ ║ ╠═╣║  ║  ║╣ ╠╦╝
     ╩ ╚═╝╩═╝╚═╝╩ ╩ ╩   ╩╝╚╝╚═╝ ╩ ╩ ╩╩═╝╩═╝╚═╝╩╚═
LOGO
    echo -e "${C_RESET}"
    echo -e "  ${C_DIM}${INSTALLER_NAME} v${INSTALLER_VERSION} — модульный автоустановщик${C_RESET}"
    echo ""
}

# ── Панель состояния системы ──────────────────────────────────────
print_status_panel() {
    local os_info uptime_info cpu ram disk server_ip domain_info
    local st_telemt st_panel st_nginx

    os_info="$(get_os_info 2>/dev/null || echo 'n/a')"
    uptime_info="$(get_uptime 2>/dev/null || echo 'n/a')"
    cpu="$(get_cpu_usage 2>/dev/null || echo 'n/a')"
    ram="$(get_ram_usage 2>/dev/null || echo 'n/a')"
    disk="$(get_disk_usage 2>/dev/null || echo 'n/a')"
    server_ip="$(curl -4s --max-time 3 ifconfig.me 2>/dev/null || echo 'n/a')"

    # Домен из конфига telemt
    domain_info="не привязан"
    local _cfg=""
    for _f in /etc/telemt/telemt.toml /etc/telemt/config.toml; do
        [[ -f "$_f" ]] && _cfg="$_f" && break
    done
    if [[ -n "$_cfg" ]]; then
        local _ph; _ph=$(grep -E '^public_host[[:space:]]*=' "$_cfg" 2>/dev/null | head -1 | awk -F'=' '{print $2}' | tr -d ' "')
        [[ -n "$_ph" ]] && domain_info="$_ph"
    fi

    st_telemt="$(get_service_status telemt 2>/dev/null || echo -e "${C_DIM}Не установлен${C_RESET}")"
    st_panel="$(get_service_status telemt-panel 2>/dev/null || echo -e "${C_DIM}Не установлен${C_RESET}")"
    st_nginx="$(get_service_status nginx 2>/dev/null || echo -e "${C_DIM}Не установлен${C_RESET}")"

    # Выравнивание: значения начинаются на визуальной колонке 15
    # Кириллица: 1 визуальный символ = 2 байта в UTF-8
    # ОС(2):     визуальная ширина 3  → нужно 12 пробелов
    # Аптайм(6): визуальная ширина 7  → нужно 8 пробелов
    # IP(2):     визуальная ширина 3  → нужно 12 пробелов
    # Домен(5):  визуальная ширина 6  → нужно 9 пробелов
    # CPU(3):    визуальная ширина 4  → нужно 11 пробелов
    # RAM(3):    визуальная ширина 4  → нужно 11 пробелов
    # Disk(4):   визуальная ширина 5  → нужно 10 пробелов
    local L_OS="ОС:            "  # 3 vis + 12 sp = 15
    local L_UP="Аптайм:        "  # 7 vis + 8 sp  = 15
    local L_IP="IP:            "  # 3 vis + 12 sp = 15
    local L_DM="Домен:         "  # 6 vis + 9 sp  = 15
    local L_CP="CPU:           "  # 4 vis + 11 sp = 15
    local L_RM="RAM:           "  # 4 vis + 11 sp = 15
    local L_DK="Disk:          "  # 5 vis + 10 sp = 15

    echo -e "  ${C_DIM}┌───────────────────────────────────────────────────────────┐${C_RESET}"
    echo -e "  ${C_DIM}│${C_RESET}  ${C_BOLD}Состояние сервера${C_RESET}"
    echo -e "  ${C_DIM}├───────────────────────────────────────────────────────────┤${C_RESET}"
    echo -e "  ${C_DIM}│${C_RESET}"
    echo -e "  ${C_DIM}│${C_RESET}   ${L_OS}${C_WHITE}${os_info}${C_RESET}"
    echo -e "  ${C_DIM}│${C_RESET}   ${L_UP}${C_WHITE}${uptime_info}${C_RESET}"
    echo -e "  ${C_DIM}│${C_RESET}   ${L_IP}${C_WHITE}${server_ip}${C_RESET}"
    echo -e "  ${C_DIM}│${C_RESET}   ${L_DM}${C_WHITE}${domain_info}${C_RESET}"
    echo -e "  ${C_DIM}│${C_RESET}   ${L_CP}${C_WHITE}${cpu}${C_RESET}"
    echo -e "  ${C_DIM}│${C_RESET}   ${L_RM}${C_WHITE}${ram}${C_RESET}"
    echo -e "  ${C_DIM}│${C_RESET}   ${L_DK}${C_WHITE}${disk}${C_RESET}"
    echo -e "  ${C_DIM}│${C_RESET}"
    echo -e "  ${C_DIM}│${C_RESET}   ${C_DIM}─── Сервисы ─────────────────────${C_RESET}"
    echo -e "  ${C_DIM}│${C_RESET}   telemt:        ${st_telemt}"
    echo -e "  ${C_DIM}│${C_RESET}   telemt-panel:  ${st_panel}"
    echo -e "  ${C_DIM}│${C_RESET}   Nginx:         ${st_nginx}"

    # Прокси-ссылка (если telemt установлен)
    local proxy_link=""
    if [[ -f /opt/telemt/proxy_links.txt ]]; then
        proxy_link=$(grep -E '^(tg://|https://t\.me/)' /opt/telemt/proxy_links.txt 2>/dev/null | head -1)
    fi
    # Если файла нет — попробовать построить из конфига
    if [[ -z "$proxy_link" && -n "$_cfg" ]]; then
        local _secret _tls_domain _port _host
        _secret=$(grep -E '^hello[[:space:]]*=' "$_cfg" 2>/dev/null | head -1 | awk -F'=' '{print $2}' | tr -d ' "')
        _tls_domain=$(grep -E '^tls_domain[[:space:]]*=' "$_cfg" 2>/dev/null | head -1 | awk -F'=' '{print $2}' | tr -d ' "')
        _port=$(grep -E '^port[[:space:]]*=' "$_cfg" 2>/dev/null | head -1 | awk -F'=' '{print $2}' | tr -d ' "')
        _host="${domain_info}"
        [[ "$_host" == "не привязан" ]] && _host="$server_ip"
        if [[ -n "$_secret" && -n "$_tls_domain" ]]; then
            local _domain_hex
            _domain_hex=$(printf '%s' "$_tls_domain" | od -An -tx1 | tr -d ' \n')
            proxy_link="https://t.me/proxy?server=${_host}&port=${_port:-443}&secret=ee${_secret}${_domain_hex}"
        fi
    fi

    if [[ -n "$proxy_link" ]]; then
        echo -e "  ${C_DIM}│${C_RESET}"
        echo -e "  ${C_DIM}│${C_RESET}   ${C_DIM}─── Прокси-ссылка ───────────────${C_RESET}"
        echo -e "  ${C_DIM}│${C_RESET}   ${C_CYAN}${proxy_link}${C_RESET}"
    fi

    echo -e "  ${C_DIM}│${C_RESET}"
    echo -e "  ${C_DIM}└───────────────────────────────────────────────────────────┘${C_RESET}"
    echo ""
}

# ── Главное меню ──────────────────────────────────────────────────
print_menu() {
    echo -e "  ${C_BOLD}${C_WHITE}Главное меню${C_RESET}"
    echo -e "  ${C_DIM}────────────────────────────────────${C_RESET}"
    echo -e "    ${C_GREEN}[1]${C_RESET} ${C_BOLD}Стандартная установка${C_RESET}"
    echo -e "        ${C_DIM}telemt + домен + фиксы DPI + панель${C_RESET}"
    echo ""
    echo -e "    ${C_BLUE}[2]${C_RESET} ${C_BOLD}Установка под свой сайт${C_RESET}"
    echo -e "        ${C_DIM}+ маскировка (selfmask) + шаблон сайта${C_RESET}"
    echo ""
    echo -e "    ${C_RED}[3]${C_RESET} ${C_BOLD}Полная очистка${C_RESET}"
    echo -e "        ${C_DIM}Удаление всех компонентов проекта${C_RESET}"
    echo ""
    echo -e "    ${C_YELLOW}[4]${C_RESET} ${C_BOLD}GitHub: сохранить проект${C_RESET}"
    echo -e "        ${C_DIM}Push скриптов в приватный репозиторий${C_RESET}"
    echo ""
    echo -e "    ${C_DIM}[0]${C_RESET} ${C_BOLD}Выход${C_RESET}"
    echo -e "  ${C_DIM}────────────────────────────────────${C_RESET}"
}

# ── Обработчики сценариев ─────────────────────────────────────────

# Обёртка: подтверждение → загрузка модуля → запуск → обработка отмен
run_scenario() {
    local name="$1" desc="$2" entry_fn="$3"
    shift 3
    local modules_to_load=("$@")

    echo ""
    if ! confirm_yn "${C_BOLD}Запустить: ${desc}?${C_RESET}" "n"; then
        msg_info "Отменено, возврат в меню"
        return 0
    fi

    # Пересоздать каталог логов (мог быть удалён cleaner-ом)
    init_logging

    # Очистить стек отката для новой сессии
    rollback_clear

    # Загрузить все нужные модули
    for mod in "${modules_to_load[@]}"; do
        _load_module "$mod" || { msg_err "Не удалось загрузить модуль $mod"; return 1; }
    done

    # Запуск главной функции сценария
    local rc=0
    "$entry_fn" || rc=$?

    case $rc in
        0)  msg_ok "Сценарий «${name}» завершён успешно"
            rollback_clear
            ;;
        10) # код 10 = пользователь запросил откат
            rollback_execute
            ;;
        20) # код 20 = выход в меню без отката
            msg_info "Возврат в главное меню"
            ;;
        *)  msg_err "Сценарий «${name}» завершился с ошибкой (код $rc)"
            if confirm_yn "Выполнить откат изменений?" "y"; then
                rollback_execute
            fi
            ;;
    esac
}

do_standard_install() {
    run_scenario "standard" "Стандартная установка" \
        "scenario_standard_install" \
        "telemt_core" "optimization" "panel"
}

do_site_install() {
    run_scenario "sitemask" "Установка под свой сайт" \
        "scenario_site_install" \
        "telemt_core" "optimization" "panel" "site_mask"
}

do_cleanup() {
    run_scenario "cleanup" "Полная очистка системы" \
        "scenario_full_cleanup" \
        "cleaner"
}

do_github_push() {
    _load_module "github" || return 1
    github_push_project
}

# ── Заглушки сценариев (для каркаса) ─────────────────────────────
# Эти функции будут определены в соответствующих модулях.
# Пока — минимальная реализация для тестирования каркаса.

scenario_standard_install() {
    if ! declare -F telemt_install &>/dev/null; then
        msg_warn "Модуль telemt_core ещё не реализован"
        msg_info "Будет выполнено: telemt → домен → фиксы DPI → панель"
        return 0
    fi

    # Шаг 1: Установка telemt
    confirm_step "Шаг 1: Установка telemt" || {
        local s=$?
        if [[ $s -eq 2 ]]; then
            handle_cancel
            local h=$?; [[ $h -eq 0 ]] && return 10; [[ $h -eq 2 ]] && return 20
        fi
        # s=1 → пропуск, идём дальше
    }
    declare -F telemt_install &>/dev/null && telemt_install

    # Шаг 2: Привязка домена
    confirm_step "Шаг 2: Привязка домена" || {
        local s=$?
        if [[ $s -eq 2 ]]; then
            handle_cancel
            local h=$?; [[ $h -eq 0 ]] && return 10; [[ $h -eq 2 ]] && return 20
        fi
    }
    declare -F telemt_bind_domain &>/dev/null && telemt_bind_domain

    # Шаг 3: Оптимизация и фиксы DPI
    confirm_step "Шаг 3: Оптимизация и фиксы DPI" || {
        local s=$?
        if [[ $s -eq 2 ]]; then
            handle_cancel
            local h=$?; [[ $h -eq 0 ]] && return 10; [[ $h -eq 2 ]] && return 20
        fi
    }
    declare -F apply_mtproto_fixes &>/dev/null && apply_mtproto_fixes

    # Шаг 4: Панель управления
    confirm_step "Шаг 4: Установка панели управления" || {
        local s=$?
        if [[ $s -eq 2 ]]; then
            handle_cancel
            local h=$?; [[ $h -eq 0 ]] && return 10; [[ $h -eq 2 ]] && return 20
        fi
    }
    declare -F panel_install &>/dev/null && panel_install

    return 0
}

scenario_site_install() {
    # ══════════════════════════════════════════════════════════════
    #  Сценарий: Установка под свой сайт (selfmask)
    #
    #  Правильный порядок:
    #    1. Параметры selfmask (домен, шаблон)
    #    2. Зависимости (nginx, certbot)
    #    3. Развёртывание сайта из шаблона GitHub
    #    4. SSL-сертификат Let's Encrypt
    #    5. Nginx (3 server-блока)
    #    6. Установка telemt СРАЗУ с mask=true, port=443
    #    7. Оптимизация DPI (selfmask-режим)
    #    8. Панель управления
    # ══════════════════════════════════════════════════════════════

    # ── Шаг 1: Параметры selfmask ────────────────────────────────
    local _do_s1=false
    confirm_step "Шаг 1: Параметры selfmask (домен, шаблон сайта)"
    local s=$?
    if [[ $s -eq 0 ]]; then _do_s1=true
    elif [[ $s -eq 2 ]]; then handle_cancel; local h=$?; [[ $h -eq 0 ]] && return 10; [[ $h -eq 2 ]] && return 20
    fi
    if [[ "$_do_s1" == "true" ]]; then
        sitemask_collect_params || return 1
    else
        msg_warn "Без параметров selfmask установка невозможна"
        return 1
    fi

    # ── Шаг 2: Зависимости ───────────────────────────────────────
    local _do_s2=false
    confirm_step "Шаг 2: Установка зависимостей (nginx, certbot)"
    s=$?
    if [[ $s -eq 0 ]]; then _do_s2=true
    elif [[ $s -eq 2 ]]; then handle_cancel; local h=$?; [[ $h -eq 0 ]] && return 10; [[ $h -eq 2 ]] && return 20
    fi
    [[ "$_do_s2" == "true" ]] && { sitemask_install_deps || return 1; }

    # ── Шаг 3: Развёртывание сайта из шаблона ────────────────────
    local _do_s3=false
    confirm_step "Шаг 3: Развёртывание сайта-маски из шаблона"
    s=$?
    if [[ $s -eq 0 ]]; then _do_s3=true
    elif [[ $s -eq 2 ]]; then handle_cancel; local h=$?; [[ $h -eq 0 ]] && return 10; [[ $h -eq 2 ]] && return 20
    fi
    [[ "$_do_s3" == "true" ]] && { sitemask_deploy_site || return 1; }

    # ── Шаг 4: SSL-сертификат ────────────────────────────────────
    local _do_s4=false
    confirm_step "Шаг 4: Получение SSL-сертификата Let's Encrypt"
    s=$?
    if [[ $s -eq 0 ]]; then _do_s4=true
    elif [[ $s -eq 2 ]]; then handle_cancel; local h=$?; [[ $h -eq 0 ]] && return 10; [[ $h -eq 2 ]] && return 20
    fi
    [[ "$_do_s4" == "true" ]] && { sitemask_obtain_cert || return 1; }

    # ── Шаг 5: Nginx (3 server-блока) ────────────────────────────
    local _do_s5=false
    confirm_step "Шаг 5: Настройка Nginx (3 server-блока selfmask)"
    s=$?
    if [[ $s -eq 0 ]]; then _do_s5=true
    elif [[ $s -eq 2 ]]; then handle_cancel; local h=$?; [[ $h -eq 0 ]] && return 10; [[ $h -eq 2 ]] && return 20
    fi
    [[ "$_do_s5" == "true" ]] && { sitemask_configure_nginx || return 1; }

    # ── Шаг 6: Установка telemt с mask=true ──────────────────────
    local _do_s6=false
    confirm_step "Шаг 6: Установка telemt (порт 443, mask → nginx)"
    s=$?
    if [[ $s -eq 0 ]]; then _do_s6=true
    elif [[ $s -eq 2 ]]; then handle_cancel; local h=$?; [[ $h -eq 0 ]] && return 10; [[ $h -eq 2 ]] && return 20
    fi
    if [[ "$_do_s6" == "true" ]]; then
        # Предустановить параметры telemt для selfmask-режима
        TELEMT_PORT="443"
        TELEMT_PUBLIC_HOST="${MASK_DOMAIN}"
        # Собрать оставшиеся параметры (секрет, TLS-домен, ad_tag)
        sitemask_telemt_params  || return 1
        telemt_download         || return 1
        telemt_setup_env        || return 1
        telemt_generate_config  || return 1
        # Дописать mask-настройки в конфиг
        sitemask_update_telemt_config || return 1
        telemt_create_service   || return 1
        telemt_print_links
    fi

    # ── Шаг 7: Оптимизация DPI ───────────────────────────────────
    local _do_s7=false
    confirm_step "Шаг 7: Оптимизация DPI (режим selfmask)"
    s=$?
    if [[ $s -eq 0 ]]; then _do_s7=true
    elif [[ $s -eq 2 ]]; then handle_cancel; local h=$?; [[ $h -eq 0 ]] && return 10; [[ $h -eq 2 ]] && return 20
    fi
    [[ "$_do_s7" == "true" ]] && { apply_mtproto_fixes_selfmask || true; }

    # ── Шаг 8: Панель управления ─────────────────────────────────
    local _do_s8=false
    confirm_step "Шаг 8: Установка панели управления"
    s=$?
    if [[ $s -eq 0 ]]; then _do_s8=true
    elif [[ $s -eq 2 ]]; then handle_cancel; local h=$?; [[ $h -eq 0 ]] && return 10; [[ $h -eq 2 ]] && return 20
    fi
    [[ "$_do_s8" == "true" ]] && { panel_install || true; }

    # ── Шаг 9: Автопродление + финальная проверка ────────────────
    sitemask_setup_renewal || true
    sitemask_verify || true

    return 0
}

scenario_full_cleanup() {
    if ! declare -F cleaner_run &>/dev/null; then
        msg_warn "Модуль cleaner ещё не реализован"
        return 0
    fi
    cleaner_run
}

# ── Главный цикл ─────────────────────────────────────────────────
main() {
    # Проверка root
    require_root

    # Проверка базовых утилит
    require_commands curl git jq

    # Отключаем set -e для интерактивного цикла —
    # иначе любой read/status-check обрушит скрипт
    set +e

    while true; do
        clear
        print_logo
        print_status_panel
        print_menu

        echo -ne "  ${C_BOLD}Выберите действие${C_RESET} [0-4]: "
        local choice=""
        read -r choice </dev/tty || true

        case "$choice" in
            1) do_standard_install ;;
            2) do_site_install     ;;
            3) do_cleanup          ;;
            4) do_github_push      ;;
            0)
                echo ""
                msg_info "До свидания!"
                exit 0
                ;;
            *)
                msg_warn "Некорректный выбор"
                ;;
        esac

        echo ""
        echo -ne "  ${C_DIM}Нажмите Enter для возврата в меню...${C_RESET}"
        read -r </dev/tty || true
    done
}

main "$@"
