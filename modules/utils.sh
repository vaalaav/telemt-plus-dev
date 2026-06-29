#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  modules/utils.sh — общие утилиты: цвета, логирование, TUI, откат
# ═══════════════════════════════════════════════════════════════════

# ── Цвета и стили ─────────────────────────────────────────────────
readonly C_RESET='\e[0m'
readonly C_BOLD='\e[1m'
readonly C_DIM='\e[2m'
readonly C_RED='\e[1;31m'
readonly C_GREEN='\e[1;32m'
readonly C_YELLOW='\e[1;33m'
readonly C_BLUE='\e[1;34m'
readonly C_MAGENTA='\e[1;35m'
readonly C_CYAN='\e[1;36m'
readonly C_WHITE='\e[1;37m'
readonly C_BG_RED='\e[41m'
readonly C_BG_GREEN='\e[42m'
readonly C_BG_BLUE='\e[44m'

# ── Box-drawing символы ───────────────────────────────────────────
readonly BOX_TL='╔' BOX_TR='╗' BOX_BL='╚' BOX_BR='╝'
readonly BOX_H='═' BOX_V='║'
readonly BOX_TL_S='┌' BOX_TR_S='┐' BOX_BL_S='└' BOX_BR_S='┘'
readonly BOX_H_S='─' BOX_V_S='│'
readonly ARROW='▸' BULLET='●' CHECK='✔' CROSS='✘' WARN='⚠'

# ── Лог-файл ─────────────────────────────────────────────────────
LOG_DIR="/var/log/telemt-installer"
LOG_FILE="${LOG_DIR}/install-$(date +%Y%m%d-%H%M%S).log"

init_logging() {
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    touch "$LOG_FILE" 2>/dev/null || {
        LOG_FILE="/tmp/telemt-install-$(date +%Y%m%d-%H%M%S).log"
        touch "$LOG_FILE" 2>/dev/null || true
    }
}

# ── Логирование ───────────────────────────────────────────────────
log_raw() {
    [[ -d "$LOG_DIR" ]] || mkdir -p "$LOG_DIR" 2>/dev/null || true
    [[ -f "$LOG_FILE" ]] || touch "$LOG_FILE" 2>/dev/null || true
    echo "[$(date '+%H:%M:%S')] $*" >> "$LOG_FILE" 2>/dev/null || true
}

msg_info()    { echo -e "  ${C_CYAN}${BULLET}${C_RESET} $*";       log_raw "INFO: $*"; }
msg_ok()      { echo -e "  ${C_GREEN}${CHECK}${C_RESET} $*";       log_raw "OK:   $*"; }
msg_warn()    { echo -e "  ${C_YELLOW}${WARN}${C_RESET} $*";       log_raw "WARN: $*"; }
msg_err()     { echo -e "  ${C_RED}${CROSS}${C_RESET} $*";         log_raw "ERR:  $*"; }
msg_step()    { echo -e "\n  ${C_BOLD}${C_BLUE}${ARROW} $*${C_RESET}"; log_raw "STEP: $*"; }
msg_header()  { echo -e "\n${C_BOLD}${C_MAGENTA}  ── $* ──${C_RESET}"; log_raw "=== $* ==="; }

# ── Спиннер ───────────────────────────────────────────────────────
_spinner_pid=""

spinner_start() {
    local msg="${1:-Выполняется...}"
    (
        local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
        local i=0
        while true; do
            printf "\r  ${C_CYAN}%s${C_RESET} %s" "${frames[i++ % ${#frames[@]}]}" "$msg"
            sleep 0.1
        done
    ) &
    _spinner_pid=$!
    disown "$_spinner_pid" 2>/dev/null
}

spinner_stop() {
    local ok="${1:-true}"
    if [[ -n "$_spinner_pid" ]] && kill -0 "$_spinner_pid" 2>/dev/null; then
        kill "$_spinner_pid" 2>/dev/null; wait "$_spinner_pid" 2>/dev/null || true
    fi
    _spinner_pid=""
    printf "\r\033[K"
    if [[ "$ok" == "true" ]]; then
        msg_ok "${2:-Готово}"
    else
        msg_err "${2:-Ошибка}"
    fi
}

# ── Выполнение команд с логированием ─────────────────────────────
run_cmd() {
    local desc="$1"; shift
    log_raw "RUN [$desc]: $*"
    if "$@" >> "$LOG_FILE" 2>&1; then
        log_raw "RUN [$desc]: OK"
        return 0
    else
        local rc=$?
        log_raw "RUN [$desc]: FAILED (rc=$rc)"
        return $rc
    fi
}

run_with_spinner() {
    local desc="$1"; shift
    spinner_start "$desc"
    if run_cmd "$desc" "$@"; then
        spinner_stop true "$desc"
        return 0
    else
        spinner_stop false "$desc — ошибка (см. лог)"
        return 1
    fi
}

# ── Горизонтальная линия ──────────────────────────────────────────
draw_hline() {
    local w="${1:-60}" char="${2:-$BOX_H}"
    printf '%0.s'"$char" $(seq 1 "$w")
}

# ── Блок информации (левая акцентная полоса, без правой рамки) ────
draw_info_box() {
    local _width="${1:-60}"
    shift
    local lines=("$@")

    echo ""
    echo -e "  ${C_CYAN}▐${C_DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
    for line in "${lines[@]}"; do
        if [[ -z "$line" ]]; then
            echo -e "  ${C_CYAN}▐${C_RESET}"
        else
            echo -e "  ${C_CYAN}▐${C_RESET}  ${line}"
        fi
    done
    echo -e "  ${C_CYAN}▐${C_DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
    echo ""
}

# ══════════════════════════════════════════════════════════════════
#  ВВОД ДАННЫХ — защита от дурака (бесконечный цикл валидации)
# ══════════════════════════════════════════════════════════════════

# ── Запрос строки с валидацией (regex) ────────────────────────────
# Использование: prompt_input "Текст" VAR_NAME '^regex$' "default"
prompt_input() {
    local prompt="$1" var_name="$2" pattern="${3:-.*}" default="${4:-}"
    local value
    while true; do
        echo -ne "  ${C_BOLD}${prompt}${C_RESET}"
        [[ -n "$default" ]] && echo -ne " ${C_DIM}[${default}]${C_RESET}"
        echo -ne ": "
        read -r value </dev/tty || true
        value="${value:-$default}"
        if [[ -z "$value" ]]; then
            msg_warn "Значение не может быть пустым. Повторите ввод."
            continue
        fi
        if [[ "$value" =~ $pattern ]]; then
            eval "$var_name='$value'"
            return 0
        else
            msg_warn "Недопустимый формат. Повторите ввод."
        fi
    done
}

# ── Запрос секрета (без эха) ──────────────────────────────────────
prompt_secret() {
    local prompt="$1" var_name="$2"
    local value
    while true; do
        echo -ne "  ${C_BOLD}${prompt}${C_RESET}: "
        read -rs value </dev/tty || true
        echo
        if [[ -n "$value" ]]; then
            eval "$var_name='$value'"
            return 0
        fi
        msg_warn "Значение не может быть пустым. Повторите ввод."
    done
}

# ── Да/Нет (y/n) с защитой от опечаток ───────────────────────────
# Возвращает: 0=да, 1=нет
confirm_yn() {
    local prompt="$1" default="${2:-n}"
    local hint="y/N"
    [[ "$default" == "y" ]] && hint="Y/n"

    while true; do
        echo -ne "  ${C_BOLD}${prompt}${C_RESET} [${hint}]: "
        local answer
        read -r answer </dev/tty || true
        answer="${answer:-$default}"
        case "$answer" in
            [Yy]) return 0 ;;
            [Nn]) return 1 ;;
            *)    msg_warn "Неверный ввод. Используйте ${C_BOLD}y${C_RESET} или ${C_BOLD}n${C_RESET}." ;;
        esac
    done
}

# ── Трёхвариантный выбор для шагов (1/2/3) ───────────────────────
# Возвращает: 0=подтвердить, 1=пропустить, 2=отмена
confirm_step() {
    local step_name="$1"
    while true; do
        echo ""
        echo -e "  ${C_BOLD}${C_WHITE}${step_name}${C_RESET}"
        echo -e "  ${C_DIM}───────────────${C_RESET}"
        echo -e "    ${C_GREEN}${C_BOLD}[1]${C_RESET} ${C_BOLD}Подтвердить (Yes)${C_RESET}"
        echo -e "    ${C_YELLOW}${C_BOLD}[2]${C_RESET} ${C_BOLD}Пропустить${C_RESET}"
        echo -e "    ${C_RED}${C_BOLD}[3]${C_RESET} ${C_BOLD}Отмена${C_RESET}"
        echo -ne "  ${C_BOLD}Выбор${C_RESET} [1/2/3]: "

        local choice
        read -r choice </dev/tty || true
        case "$choice" in
            1|"") return 0 ;;
            2)    return 1 ;;
            3)    return 2 ;;
            *)    msg_warn "Неверный ввод. Используйте ${C_BOLD}1${C_RESET}, ${C_BOLD}2${C_RESET} или ${C_BOLD}3${C_RESET}." ;;
        esac
    done
}

# ── Обработка отмены: откат / пропуск / выход ─────────────────────
# Возвращает: 0=откат, 1=пропустить, 2=выход в меню
handle_cancel() {
    while true; do
        echo ""
        echo -e "  ${C_RED}${C_BOLD}Операция отменена.${C_RESET} Что делать?"
        echo -e "    ${C_RED}${C_BOLD}[1]${C_RESET} ${C_BOLD}Полный откат действий текущей сессии${C_RESET}"
        echo -e "    ${C_YELLOW}${C_BOLD}[2]${C_RESET} ${C_BOLD}Пропустить этот шаг, продолжить${C_RESET}"
        echo -e "    ${C_CYAN}${C_BOLD}[3]${C_RESET} ${C_BOLD}Выход в главное меню${C_RESET}"
        echo -ne "  ${C_BOLD}Выбор${C_RESET} [1/2/3]: "

        local choice
        read -r choice </dev/tty || true
        case "$choice" in
            1) return 0 ;;
            2) return 1 ;;
            3) return 2 ;;
            *) msg_warn "Неверный ввод. Используйте ${C_BOLD}1${C_RESET}, ${C_BOLD}2${C_RESET} или ${C_BOLD}3${C_RESET}." ;;
        esac
    done
}

# ── Выбор из N вариантов (универсальный) ──────────────────────────
# Использование: ask_choice "Заголовок" result_var "Вариант 1" "Вариант 2" ...
# Записывает номер выбора (1-N) в result_var
ask_choice() {
    local title="$1" var_name="$2"
    shift 2
    local options=("$@")
    local count=${#options[@]}

    while true; do
        echo ""
        echo -e "  ${C_BOLD}${C_WHITE}${title}${C_RESET}"
        echo -e "  ${C_DIM}───────────────${C_RESET}"
        local i
        for (( i=0; i<count; i++ )); do
            echo -e "    ${C_GREEN}${C_BOLD}[$((i+1))]${C_RESET} ${C_BOLD}${options[i]}${C_RESET}"
        done
        echo -ne "  ${C_BOLD}Выбор${C_RESET} [1-${count}]: "

        local choice
        read -r choice </dev/tty || true
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= count )); then
            eval "$var_name='$choice'"
            return 0
        fi
        msg_warn "Неверный ввод. Введите число от ${C_BOLD}1${C_RESET} до ${C_BOLD}${count}${C_RESET}."
    done
}

# ── Система отката (Rollback) ────────────────────────────────────
declare -ga ROLLBACK_STACK=()

rollback_push() {
    ROLLBACK_STACK+=("$*")
    log_raw "ROLLBACK_PUSH: $*"
}

rollback_execute() {
    if [[ ${#ROLLBACK_STACK[@]} -eq 0 ]]; then
        msg_info "Нечего откатывать — стек пуст"
        return 0
    fi
    msg_header "Откат изменений (${#ROLLBACK_STACK[@]} действий)"
    local i
    for (( i=${#ROLLBACK_STACK[@]}-1; i>=0; i-- )); do
        local cmd="${ROLLBACK_STACK[i]}"
        msg_info "Откат: ${cmd}"
        if eval "$cmd" >> "$LOG_FILE" 2>&1; then
            msg_ok "OK"
        else
            msg_warn "Не удалось: ${cmd}"
        fi
    done
    ROLLBACK_STACK=()
    msg_ok "Откат завершён"
}

rollback_clear() {
    ROLLBACK_STACK=()
}

# ── Проверка зависимостей ────────────────────────────────────────
require_root() {
    if [[ $EUID -ne 0 ]]; then
        msg_err "Скрипт требует запуска от root (sudo)"
        exit 1
    fi
}

require_commands() {
    local missing=()
    for cmd in "$@"; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        msg_info "Установка: ${missing[*]}..."
        apt-get update -qq >> "$LOG_FILE" 2>&1
        apt-get install -y -qq "${missing[@]}" >> "$LOG_FILE" 2>&1 && \
            msg_ok "Установлено: ${missing[*]}" || \
            { msg_err "Не удалось установить: ${missing[*]}"; return 1; }
    fi
}

# ── Сбор информации о системе ────────────────────────────────────
get_os_info() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        echo "${PRETTY_NAME:-Ubuntu}"
    else
        echo "Linux (unknown)"
    fi
}

get_uptime() {
    uptime -p 2>/dev/null | sed 's/^up //' || echo "n/a"
}

get_cpu_usage() {
    awk '{u=$2+$4; t=$2+$4+$5; if(NR>1) printf "%.0f%%", (u-pu)/(t-pt)*100; pu=u; pt=t}' \
        <(head -1 /proc/stat) <(sleep 0.3 && head -1 /proc/stat) 2>/dev/null || echo "n/a"
}

get_ram_usage() {
    free -m 2>/dev/null | awk 'NR==2{printf "%dМБ/%dМБ (%.0f%%)", $3, $2, $3/$2*100}' || echo "n/a"
}

get_disk_usage() {
    df -h / 2>/dev/null | awk 'NR==2{printf "%s/%s (%s)", $3, $2, $5}' || echo "n/a"
}

get_service_status() {
    local svc="$1"
    if ! systemctl list-unit-files "${svc}.service" &>/dev/null 2>&1 && \
       ! systemctl cat "${svc}.service" &>/dev/null 2>&1; then
        echo -e "${C_DIM}Не установлен${C_RESET}"
        return
    fi
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        echo -e "${C_GREEN}● Активен${C_RESET}"
    else
        echo -e "${C_RED}● Остановлен${C_RESET}"
    fi
}

# ── Trap для корректного завершения ──────────────────────────────
cleanup_on_exit() {
    if [[ -n "${_spinner_pid:-}" ]] && kill -0 "$_spinner_pid" 2>/dev/null; then
        kill "$_spinner_pid" 2>/dev/null || true
    fi
    tput cnorm 2>/dev/null || true
}

setup_traps() {
    trap cleanup_on_exit EXIT
    trap 'msg_warn "Прервано (SIGINT)"; cleanup_on_exit; exit 130' INT
    trap 'msg_warn "Прервано (SIGTERM)"; cleanup_on_exit; exit 143' TERM
}

# Инициализация при подключении модуля
init_logging
setup_traps
