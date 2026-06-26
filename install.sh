#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  telemt VPS Installer — bootstrap
#  curl -fsSL https://raw.githubusercontent.com/vaalaav/telemt-plus-dev/main/install.sh | sudo bash
# ═══════════════════════════════════════════════════════════════════
set -euo pipefail

REPO="https://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@github.com/vaalaav/telemt-plus-dev.git"
INSTALL_DIR="/opt/telemt-installer"

if [[ $EUID -ne 0 ]]; then
    echo "Запустите от root: curl -fsSL ... | sudo bash"
    exit 1
fi

# Зависимости
for cmd in git curl jq; do
    if ! command -v "$cmd" &>/dev/null; then
        apt-get update -qq && apt-get install -y -qq "$cmd"
    fi
done

# Клонирование / обновление
if [[ -d "${INSTALL_DIR}/.git" ]]; then
    echo "[*] Обновление..."
    cd "$INSTALL_DIR" && git pull --ff-only 2>/dev/null || true
else
    echo "[*] Клонирование репозитория..."
    rm -rf "$INSTALL_DIR"
    git clone --depth 1 "$REPO" "$INSTALL_DIR"
fi

chmod +x "${INSTALL_DIR}/main.sh" "${INSTALL_DIR}/modules/"*.sh

echo "[*] Запуск установщика..."
exec bash "${INSTALL_DIR}/main.sh" </dev/tty
