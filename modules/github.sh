#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  modules/github.sh — Интеграция с GitHub API
#  Создание приватного репозитория, push всех модулей
# ═══════════════════════════════════════════════════════════════════

# Зависимость — utils.sh уже загружен через main.sh

GITHUB_API="https://api.github.com"
GITHUB_USER=""
GITHUB_TOKEN=""
GITHUB_REPO_NAME=""

# ── Запрос учётных данных GitHub ──────────────────────────────────
github_collect_credentials() {
    msg_header "Интеграция с GitHub"

    prompt_input "Имя пользователя GitHub" GITHUB_USER '^[a-zA-Z0-9_-]+$' "vaalaav"
    prompt_secret "Personal Access Token (PAT)" GITHUB_TOKEN || {
        msg_err "Токен обязателен для работы с GitHub API"
        return 1
    }

    # Проверить валидность токена
    msg_info "Проверка токена..."
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github.v3+json" \
        "${GITHUB_API}/user" 2>/dev/null)

    if [[ "$http_code" != "200" ]]; then
        msg_err "Токен невалиден или нет доступа (HTTP ${http_code})"
        return 1
    fi
    msg_ok "Токен подтверждён для пользователя ${C_BOLD}${GITHUB_USER}${C_RESET}"
}

# ── Создание приватного репозитория ───────────────────────────────
github_create_repo() {
    prompt_input "Имя репозитория" GITHUB_REPO_NAME '^[a-zA-Z0-9._-]+$' "telemt-vps-installer"

    msg_info "Проверка существования репозитория ${GITHUB_USER}/${GITHUB_REPO_NAME}..."
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github.v3+json" \
        "${GITHUB_API}/repos/${GITHUB_USER}/${GITHUB_REPO_NAME}" 2>/dev/null)

    if [[ "$http_code" == "200" ]]; then
        msg_warn "Репозиторий уже существует"
        if ! confirm_yn "Использовать существующий репозиторий и перезаписать?" "n"; then
            return 1
        fi
        msg_ok "Используем существующий: ${GITHUB_USER}/${GITHUB_REPO_NAME}"
        return 0
    fi

    msg_info "Создание приватного репозитория..."
    local response
    response=$(curl -s -w "\n%{http_code}" \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github.v3+json" \
        -X POST "${GITHUB_API}/user/repos" \
        -d "{
            \"name\": \"${GITHUB_REPO_NAME}\",
            \"private\": true,
            \"description\": \"telemt VPS Installer — модульный автоустановщик прокси-серверов\",
            \"auto_init\": false
        }" 2>/dev/null)

    local body http_code
    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" == "201" ]]; then
        msg_ok "Репозиторий создан: https://github.com/${GITHUB_USER}/${GITHUB_REPO_NAME}"
    else
        local err_msg
        err_msg=$(echo "$body" | jq -r '.message // "unknown error"' 2>/dev/null)
        msg_err "Не удалось создать репозиторий (HTTP ${http_code}): ${err_msg}"
        return 1
    fi
}

# ── Инициализация git и push ──────────────────────────────────────
github_init_and_push() {
    local remote_url="https://${GITHUB_TOKEN}@github.com/${GITHUB_USER}/${GITHUB_REPO_NAME}.git"

    cd "$PROJECT_DIR" || { msg_err "Не удалось перейти в ${PROJECT_DIR}"; return 1; }

    # Создать .gitignore
    if [[ ! -f .gitignore ]]; then
        cat > .gitignore << 'EOF'
*.log
*.tmp
.env
__pycache__/
node_modules/
EOF
        msg_ok "Создан .gitignore"
    fi

    # Инициализация / реинициализация
    if [[ ! -d .git ]]; then
        git init -q
        msg_ok "Git-репозиторий инициализирован"
    fi

    git config user.name "${GITHUB_USER}" 2>/dev/null
    git config user.email "${GITHUB_USER}@users.noreply.github.com" 2>/dev/null

    # Настроить remote
    if git remote get-url origin &>/dev/null; then
        git remote set-url origin "$remote_url"
    else
        git remote add origin "$remote_url"
    fi

    # Stage & commit
    git add -A
    local changes
    changes=$(git status --porcelain 2>/dev/null)
    if [[ -z "$changes" ]]; then
        msg_info "Нет изменений для коммита"
    else
        local commit_msg="auto: deploy modules $(date '+%Y-%m-%d %H:%M')"
        git commit -q -m "$commit_msg"
        msg_ok "Коммит: ${commit_msg}"
    fi

    # Push
    spinner_start "Push в GitHub..."
    if git push -u origin "$(git branch --show-current 2>/dev/null || echo main)" --force >> "$LOG_FILE" 2>&1; then
        spinner_stop true "Проект загружен в https://github.com/${GITHUB_USER}/${GITHUB_REPO_NAME}"
    else
        spinner_stop false "Push не удался — см. лог"
        log_raw "GIT PUSH FAILED"
        return 1
    fi
}

# ── Главная точка входа модуля ────────────────────────────────────
github_push_project() {
    github_collect_credentials || return 1
    github_create_repo         || return 1
    github_init_and_push       || return 1
    echo ""
    msg_ok "Все модули загружены в приватный репозиторий GitHub"
}
