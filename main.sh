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

    echo ""
    echo -e "  ${C_CYAN}▐${C_DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
    echo -e "  ${C_CYAN}▐${C_RESET}  ${C_BOLD}${C_WHITE}Состояние сервера${C_RESET}"
    echo -e "  ${C_CYAN}▐${C_RESET}"
    echo -e "  ${C_CYAN}▐${C_RESET}  ${L_OS}${C_WHITE}${os_info}${C_RESET}"
    echo -e "  ${C_CYAN}▐${C_RESET}  ${L_UP}${C_WHITE}${uptime_info}${C_RESET}"
    echo -e "  ${C_CYAN}▐${C_RESET}  ${L_IP}${C_GREEN}${server_ip}${C_RESET}"
    echo -e "  ${C_CYAN}▐${C_RESET}  ${L_DM}${C_WHITE}${domain_info}${C_RESET}"
    echo -e "  ${C_CYAN}▐${C_RESET}  ${L_CP}${C_WHITE}${cpu}${C_RESET}"
    echo -e "  ${C_CYAN}▐${C_RESET}  ${L_RM}${C_WHITE}${ram}${C_RESET}"
    echo -e "  ${C_CYAN}▐${C_RESET}  ${L_DK}${C_WHITE}${disk}${C_RESET}"
    echo -e "  ${C_CYAN}▐${C_RESET}"
    echo -e "  ${C_CYAN}▐${C_RESET}  ${C_DIM}── Сервисы ──${C_RESET}"
    echo -e "  ${C_CYAN}▐${C_RESET}  telemt:        ${st_telemt}"
    echo -e "  ${C_CYAN}▐${C_RESET}  telemt-panel:  ${st_panel}"
    echo -e "  ${C_CYAN}▐${C_RESET}  Nginx:         ${st_nginx}"

    # Прокси-ссылка (если telemt установлен)
    local proxy_link=""
    if [[ -f /opt/telemt/proxy_links.txt ]]; then
        proxy_link=$(grep -E '^(tg://|https://t\.me/)' /opt/telemt/proxy_links.txt 2>/dev/null | head -1)
    fi
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
        echo -e "  ${C_CYAN}▐${C_RESET}"
        echo -e "  ${C_CYAN}▐${C_RESET}  ${C_DIM}── Прокси ──${C_RESET}"
        echo -e "  ${C_CYAN}▐${C_RESET}  ${C_CYAN}${proxy_link}${C_RESET}"
    fi

    # Панель управления (если установлена)
    local panel_url=""
    if [[ -f /var/lib/telemt-panel/credentials.txt ]]; then
        panel_url=$(grep '^URL:' /var/lib/telemt-panel/credentials.txt 2>/dev/null | awk '{print $2}')
    fi
    if [[ -n "$panel_url" ]]; then
        echo -e "  ${C_CYAN}▐${C_RESET}"
        echo -e "  ${C_CYAN}▐${C_RESET}  ${C_DIM}── Панель ──${C_RESET}"
        echo -e "  ${C_CYAN}▐${C_RESET}  ${C_MAGENTA}${panel_url}${C_RESET}"
    fi

    echo -e "  ${C_CYAN}▐${C_DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
    echo ""
}

# ── Главное меню ──────────────────────────────────────────────────
print_menu() {
    echo -e "  ${C_BOLD}${C_WHITE}Главное меню${C_RESET}"
    echo -e "  ${C_DIM}────────────────────────────────────${C_RESET}"
    echo -e "    ${C_GREEN}[1]${C_RESET} ${C_BOLD}Стандартная установка${C_RESET}"
    echo -e "        ${C_DIM}telemt + домен + фиксы DPI${C_RESET}"
    echo ""
    echo -e "    ${C_BLUE}[2]${C_RESET} ${C_BOLD}Установка под свой сайт${C_RESET}"
    echo -e "        ${C_DIM}+ маскировка (selfmask) + шаблон сайта${C_RESET}"
    echo ""
    echo -e "    ${C_MAGENTA}[3]${C_RESET} ${C_BOLD}Панель управления${C_RESET}"
    echo -e "        ${C_DIM}Установка telemt_panel${C_RESET}"
    echo ""
    echo -e "    ${C_RED}[4]${C_RESET} ${C_BOLD}Полная очистка${C_RESET}"
    echo -e "        ${C_DIM}Удаление всех компонентов проекта${C_RESET}"
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
    echo ""
    echo -e "  ${C_RED}${C_BOLD}ВНИМАНИЕ: Это полностью удалит все компоненты и конфиги!${C_RESET}"
    if ! confirm_yn "  ${C_BOLD}Вы уверены?${C_RESET}" "n"; then
        msg_info "Отменено, возврат в меню"
        return 0
    fi
    run_scenario "cleanup" "Полная очистка системы" \
        "scenario_full_cleanup" \
        "cleaner"
}

do_panel_install() {
    _load_module "panel" || return 1
    init_logging
    panel_install
}

do_github_push() {
    _load_module "github" || return 1
    github_push_project
}

# ── Заглушки сценариев (для каркаса) ─────────────────────────────
# Эти функции будут определены в соответствующих модулях.
# Пока — минимальная реализация для тестирования каркаса.

scenario_standard_install() {
    # ══════════════════════════════════════════════════════════════
    #  Сценарий 1: Стандартная установка
    #  Обязательно: telemt + домен (ввод данных)
    #  Опционально: фиксы DPI, панель
    # ══════════════════════════════════════════════════════════════

    # ── Обязательные шаги (молча) ─────────────────────────────────
    telemt_install     || return 1
    telemt_bind_domain || true

    # ── Опциональные компоненты (с вопросом) ──────────────────────
    echo ""
    if confirm_yn "  ${C_BOLD}Установить фиксы DPI (MEKO)?${C_RESET}" "y"; then
        apply_mtproto_fixes || true
    fi

    echo ""

    return 0
}

scenario_site_install() {
    # ══════════════════════════════════════════════════════════════
    #  Сценарий 2: Установка под свой сайт (selfmask)
    #  Обязательно: параметры → зависимости → сайт → SSL → nginx → telemt
    #  Опционально: фиксы DPI, панель
    # ══════════════════════════════════════════════════════════════

    # ── Обязательные шаги (молча, только сбор данных) ──────────────
    sitemask_collect_params       || return 1
    sitemask_install_deps         || return 1
    sitemask_deploy_site          || return 1
    sitemask_obtain_cert          || return 1
    sitemask_configure_nginx      || return 1

    # telemt с mask=true (параметры → скачивание → конфиг → сервис)
    TELEMT_PORT="443"
    TELEMT_PUBLIC_HOST="${MASK_DOMAIN}"
    sitemask_telemt_params        || return 1
    telemt_download               || return 1
    telemt_setup_env              || return 1
    telemt_generate_config        || return 1
    sitemask_update_telemt_config || return 1
    telemt_create_service         || return 1
    telemt_print_links

    # ── Опциональные компоненты (с вопросом) ──────────────────────
    echo ""
    if confirm_yn "  ${C_BOLD}Установить фиксы DPI (MEKO, selfmask)?${C_RESET}" "y"; then
        apply_mtproto_fixes_selfmask || true
    fi

    echo ""

    # ── Финализация (молча) ───────────────────────────────────────
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
            3) do_panel_install    ;;
            4) do_cleanup          ;;
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
