<div align="center">

# 🚀 Telemt VPS Installer

**Модульный TUI-установщик MTProto прокси для Ubuntu 24.04**

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Ubuntu](https://img.shields.io/badge/Ubuntu-24.04-orange.svg)](https://ubuntu.com)
[![Bash](https://img.shields.io/badge/Bash-5.x-green.svg)](https://www.gnu.org/software/bash/)

[🇷🇺 Русский](#-возможности) • [🇬🇧 English](#-features)

<img src="https://img.shields.io/badge/MTProto-Proxy-blue?style=for-the-badge" alt="MTProto Proxy">

</div>

---

## 🇷🇺 Русский

### ⚡ Быстрая установка

```bash
curl -fsSL https://raw.githubusercontent.com/vaalaav/telemt-plus-dev/main/install.sh -o /tmp/tinstall.sh && sudo bash /tmp/tinstall.sh
```

### 🎯 Возможности

**Два режима работы прокси:**

- **Базовый** — классическая установка MTProto прокси с выбором порта, домена и генерацией прокси-ссылки
- **Selfmask** — маскировка прокси под полноценный веб-сайт на порту 443 с SSL-сертификатом Let's Encrypt. Для внешнего наблюдателя сервер выглядит как обычный HTTPS-сайт

**Дополнительные модули:**

- 🔧 **Выбор версии** — динамический список из последних 5 релизов через GitHub API
- 🌐 **Привязка домена** — автоматическая проверка DNS и подстановка домена в прокси-ссылки
- 🛡️ **Фиксы оптимизации MEKO** — SYN FIX, BBR, TCP-тюнинг, обход DPI-блокировок
- 🔗 **Xray Upstream Tunnel** — маршрутизация трафика к Telegram через внешний VPN-туннель
- 🧹 **Интеллектуальная очистка** — аудит установленных компонентов с пошаговым удалением
- 🖥️ **CLI-утилита `mytelemtinfo`** — быстрое управление прокси из терминала

### 📋 Главное меню

```
[ Вариант установки ]
  [1] Базовый telemt
  [2] Маскировка под веб-сайт (Selfmask)

[ Дополнительные опции ]
  [3] Привязка домена к прокси
  [4] Применение фиксов оптимизации MEKO
  [5] Xray Upstream Tunnel

[ Система ]
  [6] Полная или пошаговая очистка системы
  [0] Выход
```

### 🌐 Режим Selfmask

Прокси маскируется под обычный веб-сайт. На сервере разворачивается шаблон сайта из GitHub, выпускается SSL-сертификат, а telemt принимает входящие соединения на порт 443 и автоматически разделяет трафик:

- Браузер → сайт
- Telegram → прокси

Встроенные шаблоны сайтов:
- [Market Terminal Template](https://github.com/vaalaav/Market-Terminal-Template)
- [Kotorunner](https://github.com/vaalaav/kotorunner)
- Любой публичный Git-репозиторий

### 🔗 Xray Upstream Tunnel

Весь исходящий трафик от telemt к серверам Telegram маршрутизируется через внешний VPN-туннель.
Достаточно вставить ключ подключения — скрипт автоматически настроит всю цепочку.
Маршрутизация настроена точечно: через туннель идёт только трафик к подсетям Telegram (9 IPv4 + 5 IPv6 CIDR), остальной — напрямую.

### 🛡️ Оптимизация MEKO

Набор фиксов для стабильной работы в сетях с DPI:
- Двухуровневая SYN-фильтрация (iOS + общий трафик)
- BBR congestion control + TCP Fast Open
- Тонкая настройка sysctl (буферы, keepalive, backlog)
- Увеличение лимитов файловых дескрипторов

### 🔧 CLI-утилита

После установки доступна команда:

```bash
sudo mytelemtinfo
```

Позволяет редактировать конфиг, применять SYN-fix, перезапускать или останавливать сервис, а также запускать очистку — всё из одного меню.

Отдельная установка утилиты:
```bash
sudo curl -fsSL https://raw.githubusercontent.com/vaalaav/telemt-plus-dev/main/modules/mytelemtinfo -o /usr/local/bin/mytelemtinfo && sudo chmod +x /usr/local/bin/mytelemtinfo
```

---

## 🇬🇧 English

### ⚡ Quick Install

```bash
curl -fsSL https://raw.githubusercontent.com/vaalaav/telemt-plus-dev/main/install.sh -o /tmp/tinstall.sh && sudo bash /tmp/tinstall.sh
```

### 🎯 Features

**Two proxy modes:**

- **Standard** — classic MTProto proxy setup with custom port, domain binding, and proxy link generation
- **Selfmask** — disguise the proxy as a real website on port 443 with a Let's Encrypt SSL certificate. To any external observer, the server looks like a regular HTTPS website

**Additional modules:**

- 🔧 **Version selector** — dynamic list of last 5 releases via GitHub API
- 🌐 **Domain binding** — automatic DNS verification and domain substitution in proxy links
- 🛡️ **MEKO optimization fixes** — SYN FIX, BBR, TCP tuning, DPI bypass
- 🔗 **Xray Upstream Tunnel** — route Telegram traffic through an external VPN tunnel
- 🧹 **Smart cleanup** — component audit with step-by-step removal
- 🖥️ **CLI utility `mytelemtinfo`** — quick proxy management from terminal

### 📋 Main Menu

```
[ Installation Mode ]
  [1] Standard telemt
  [2] Website masking (Selfmask)

[ Additional Options ]
  [3] Bind domain to proxy
  [4] Apply MEKO optimization fixes
  [5] Xray Upstream Tunnel

[ System ]
  [6] Full or step-by-step cleanup
  [0] Exit
```

### 🌐 Selfmask Mode

The proxy disguises itself as a regular website. A site template is deployed from GitHub, an SSL certificate is issued, and telemt accepts incoming connections on port 443, automatically splitting traffic:

- Browser → website
- Telegram → proxy

Built-in site templates:
- [Market Terminal Template](https://github.com/vaalaav/Market-Terminal-Template)
- [Kotorunner](https://github.com/vaalaav/kotorunner)
- Any public Git repository

### 🔗 Xray Upstream Tunnel

All outgoing traffic from telemt to Telegram servers is routed through an external VPN tunnel.
Simply paste a connection key — the script will automatically configure the entire chain.
Routing is precise: only Telegram subnet traffic (9 IPv4 + 5 IPv6 CIDRs) goes through the tunnel, everything else goes direct.

### 🛡️ MEKO Optimization

A set of fixes for stable operation in networks with DPI:
- Two-tier SYN filtering (iOS + general traffic)
- BBR congestion control + TCP Fast Open
- Fine-tuned sysctl parameters (buffers, keepalive, backlog)
- Increased file descriptor limits

### 🔧 CLI Utility

After installation, the following command is available:

```bash
sudo mytelemtinfo
```

Edit config, apply SYN-fix, restart or stop the service, and run cleanup — all from one menu.

Standalone utility install:
```bash
sudo curl -fsSL https://raw.githubusercontent.com/vaalaav/telemt-plus-dev/main/modules/mytelemtinfo -o /usr/local/bin/mytelemtinfo && sudo chmod +x /usr/local/bin/mytelemtinfo
```

---

## 📚 Ссылки / References

| Resource | Link |
|---|---|
| Telemt MTProxy | [github.com/nickoala/telemt](https://github.com/nickoala/telemt) |
| Selfmask Guide | [assyoucandy.github.io/telemt-server-guide](https://assyoucandy.github.io/telemt-server-guide/telemt-selfmask-guide.html) |
| MEKO DPI Fix | [github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO](https://github.com/Mekotofeuka/MTPROTO_FIX_By_MEKO) |
| MTProxy Reanimation | [github.com/Liafanx/MTproxy-reanimation](https://github.com/Liafanx/MTproxy-reanimation) |
| Xray Core | [github.com/XTLS/Xray-core](https://github.com/XTLS/Xray-core) |

---

<div align="center">

**Сделано с ❤️ для свободного интернета**

</div>
