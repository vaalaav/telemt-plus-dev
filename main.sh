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
    local os_info uptime_info cpu ram disk
    local st_telemt st_panel st_nginx

    os_info="$(get_os_info 2>/dev/null || echo 'n/a')"
    uptime_info="$(get_uptime 2>/dev/null || echo 'n/a')"
    cpu="$(get_cpu_usage 2>/dev/null || echo 'n/a')"
    ram="$(get_ram_usage 2>/dev/null || echo 'n/a')"
    disk="$(get_disk_usage 2>/dev/null || echo 'n/a')"
    st_telemt="$(get_service_status telemt 2>/dev/null || echo -e "${C_DIM}Не установлен${C_RESET}")"
    st_panel="$(get_service_status telemt-panel 2>/dev/null || echo -e "${C_DIM}Не установлен${C_RESET}")"
    st_nginx="$(get_service_status nginx 2>/dev/null || echo -e "${C_DIM}Не установлен${C_RESET}")"

    echo -e "  ${C_DIM}┌──────────────────── Состояние сервера ────────────────────┐${C_RESET}"
    echo -e "  ${C_DIM}│${C_RESET}  ОС: ${C_WHITE}${os_info}${C_RESET}   Аптайм: ${C_WHITE}${uptime_info}${C_RESET}"
    echo -e "  ${C_DIM}│${C_RESET}  CPU: ${C_WHITE}${cpu}${C_RESET}   RAM: ${C_WHITE}${ram}${C_RESET}   Disk: ${C_WHITE}${disk}${C_RESET}"
    echo -e "  ${C_DIM}│${C_RESET}"
    echo -e "  ${C_DIM}│${C_RESET}  telemt:       ${st_telemt}"
    echo -e "  ${C_DIM}│${C_RESET}  telemt_panel: ${st_panel}"
    echo -e "  ${C_DIM}│${C_RESET}  Nginx:        ${st_nginx}"
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
    if ! declare -F telemt_install &>/dev/null; then
        msg_warn "Модули ещё не реализованы"
        msg_info "Будет выполнено: telemt → домен → сайт-маска → фиксы → панель"
        return 0
    fi

    # Шаг 1: Установка telemt
    confirm_step "Шаг 1: Установка telemt" || {
        local s=$?
        if [[ $s -eq 2 ]]; then handle_cancel; local h=$?; [[ $h -eq 0 ]] && return 10; [[ $h -eq 2 ]] && return 20; fi
    }
    declare -F telemt_install &>/dev/null && telemt_install

    # Шаг 2: Привязка домена
    confirm_step "Шаг 2: Привязка домена" || {
        local s=$?
        if [[ $s -eq 2 ]]; then handle_cancel; local h=$?; [[ $h -eq 0 ]] && return 10; [[ $h -eq 2 ]] && return 20; fi
    }
    declare -F telemt_bind_domain &>/dev/null && telemt_bind_domain

    # Шаг 3: Настройка сайта-маски
    confirm_step "Шаг 3: Настройка сайта-маски (selfmask)" || {
        local s=$?
        if [[ $s -eq 2 ]]; then handle_cancel; local h=$?; [[ $h -eq 0 ]] && return 10; [[ $h -eq 2 ]] && return 20; fi
    }
    declare -F sitemask_setup &>/dev/null && sitemask_setup

    # Шаг 4: Оптимизация (адаптированная под selfmask)
    confirm_step "Шаг 4: Оптимизация DPI (режим selfmask)" || {
        local s=$?
        if [[ $s -eq 2 ]]; then handle_cancel; local h=$?; [[ $h -eq 0 ]] && return 10; [[ $h -eq 2 ]] && return 20; fi
    }
    declare -F apply_mtproto_fixes_selfmask &>/dev/null && apply_mtproto_fixes_selfmask

    # Шаг 5: Панель управления
    confirm_step "Шаг 5: Установка панели управления" || {
        local s=$?
        if [[ $s -eq 2 ]]; then handle_cancel; local h=$?; [[ $h -eq 0 ]] && return 10; [[ $h -eq 2 ]] && return 20; fi
    }
    declare -F panel_install &>/dev/null && panel_install

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
