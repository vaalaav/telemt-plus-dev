#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  telemt VPS Installer — bootstrap
#  Использование:
#    curl -fsSL -H "Authorization: token TOKEN" URL -o /tmp/tinstall.sh && sudo bash /tmp/tinstall.sh
# ═══════════════════════════════════════════════════════════════════
set -euo pipefail

REPO="https://github.com/vaalaav/telemt-plus-dev.git"
INSTALL_DIR="/opt/telemt-installer"

if [[ $EUID -ne 0 ]]; then
    echo "Запустите от root: sudo bash $0"
    exit 1
fi

# Зависимости
for cmd in git curl jq; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "[*] Установка $cmd..."
        apt-get update -qq 2>/dev/null && apt-get install -y -qq "$cmd" 2>/dev/null
    fi
done

# Клонирование / обновление (при force-push — переклонировать)
if [[ -d "${INSTALL_DIR}/.git" ]]; then
    echo "[*] Обновление..."
    cd "$INSTALL_DIR"
    if ! git pull --ff-only 2>/dev/null; then
        echo "[*] Force-push обнаружен — переклонирование..."
        cd /
        rm -rf "$INSTALL_DIR"
        git clone --depth 1 "$REPO" "$INSTALL_DIR"
    fi
else
    echo "[*] Клонирование репозитория..."
    rm -rf "$INSTALL_DIR"
    git clone --depth 1 "$REPO" "$INSTALL_DIR"
fi

chmod +x "${INSTALL_DIR}/main.sh" "${INSTALL_DIR}/modules/"*.sh

echo "[*] Запуск установщика..."
cd "$INSTALL_DIR"
bash main.sh
