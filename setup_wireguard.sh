#!/bin/bash
# =============================================================================
# setup_wireguard.sh — Автоматическая установка и настройка WireGuard VPN
# Ubuntu 22.04 | Публичный IP сервера: 147.45.104.216
# =============================================================================
# Использование: sudo bash setup_wireguard.sh
# Идемпотентен: повторный запуск не сломает существующую конфигурацию.
# =============================================================================

set -euo pipefail  # Строгий режим: выход при ошибке, неопределённой переменной, ошибке пайпа

# ─────────────────────────────────────────────────────────────────────────────
# НАСТРАИВАЕМЫЕ ПАРАМЕТРЫ
# ─────────────────────────────────────────────────────────────────────────────
SERVER_PUBLIC_IP="147.45.104.216"   # Публичный IP сервера (фиксированный)
WG_INTERFACE="wg0"                  # Имя WireGuard интерфейса
WG_PORT="51820"                     # UDP-порт WireGuard
SERVER_VPN_IP="10.0.0.1"           # IP сервера в VPN-подсети
VPN_SUBNET="10.0.0.0/24"           # VPN-подсеть
VPN_CIDR="24"                       # Маска подсети
CLIENT_DNS="1.1.1.1, 8.8.8.8"     # DNS для клиентов (Cloudflare + Google)
WG_CONFIG="/etc/wireguard/${WG_INTERFACE}.conf"   # Путь к конфигу сервера
CLIENTS_DIR="/etc/wireguard/clients"              # Директория конфигов клиентов
ADD_CLIENT_SCRIPT="/usr/local/bin/add_client.sh"
REMOVE_CLIENT_SCRIPT="/usr/local/bin/remove_client.sh"

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ─────────────────────────────────────────────────────────────────────────────
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# ─────────────────────────────────────────────────────────────────────────────

log_info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_section() { echo -e "\n${BLUE}══════════════════════════════════════════${NC}"; echo -e "${BLUE}  $*${NC}"; echo -e "${BLUE}══════════════════════════════════════════${NC}"; }

# ─────────────────────────────────────────────────────────────────────────────
# ПРОВЕРКА ПРАВ ROOT
# ─────────────────────────────────────────────────────────────────────────────
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Скрипт должен быть запущен от имени root (sudo bash $0)"
        exit 1
    fi
    log_info "Проверка прав root: OK"
}

# ─────────────────────────────────────────────────────────────────────────────
# ОПРЕДЕЛЕНИЕ ОСНОВНОГО СЕТЕВОГО ИНТЕРФЕЙСА
# Нужен для правил iptables (маскарадинг исходящего трафика)
# ─────────────────────────────────────────────────────────────────────────────
detect_main_interface() {
    # Определяем интерфейс, через который идёт маршрут по умолчанию
    MAIN_IFACE=$(ip route show default | awk '/default/ {print $5}' | head -n1)
    if [[ -z "$MAIN_IFACE" ]]; then
        log_error "Не удалось определить основной сетевой интерфейс"
        exit 1
    fi
    log_info "Основной сетевой интерфейс: ${MAIN_IFACE}"
}

# ─────────────────────────────────────────────────────────────────────────────
# ШАГ 1: ОБНОВЛЕНИЕ СИСТЕМЫ И УСТАНОВКА ПАКЕТОВ
# ─────────────────────────────────────────────────────────────────────────────
install_packages() {
    log_section "Установка пакетов"

    log_info "Обновление списка пакетов..."
    apt-get update -qq

    log_info "Обновление установленных пакетов..."
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq

    local packages=(
        wireguard          # Ядро WireGuard и утилиты
        wireguard-tools    # wg, wg-quick
        qrencode           # Генерация QR-кодов для мобильных клиентов
        iptables           # Управление правилами брандмауэра
        iptables-persistent # Сохранение правил iptables между перезагрузками
        ufw                # Упрощённый брандмауэр (Uncomplicated Firewall)
        unattended-upgrades # Автоматическое применение обновлений безопасности
        curl               # HTTP-клиент (утилита)
        net-tools          # ifconfig и другие сетевые утилиты
    )

    log_info "Установка пакетов: ${packages[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${packages[@]}"

    log_info "Все пакеты успешно установлены"
}

# ─────────────────────────────────────────────────────────────────────────────
# ШАГ 2: ВКЛЮЧЕНИЕ IP-ФОРВАРДИНГА
# Необходимо для маршрутизации трафика клиентов через сервер
# ─────────────────────────────────────────────────────────────────────────────
enable_ip_forwarding() {
    log_section "Включение IP-форвардинга"

    # Проверяем, не включён ли уже форвардинг
    if grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null; then
        log_warn "IP-форвардинг уже включён в /etc/sysctl.conf"
    else
        # Добавляем настройку в sysctl.conf для персистентности
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        log_info "Добавлен net.ipv4.ip_forward=1 в /etc/sysctl.conf"
    fi

    # Также проверяем IPv6-форвардинг
    if ! grep -q "^net.ipv6.conf.all.forwarding=1" /etc/sysctl.conf 2>/dev/null; then
        echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
    fi

    # Применяем настройки без перезагрузки
    sysctl -p /etc/sysctl.conf > /dev/null 2>&1 || sysctl -p > /dev/null 2>&1
    log_info "IP-форвардинг активирован (IPv4 + IPv6)"
}

# ─────────────────────────────────────────────────────────────────────────────
# ШАГ 3: ГЕНЕРАЦИЯ КЛЮЧЕЙ СЕРВЕРА
# Ключи генерируются только если конфиг ещё не существует (идемпотентность)
# ─────────────────────────────────────────────────────────────────────────────
generate_server_keys() {
    log_section "Генерация ключей сервера"

    # Директория для хранения ключей
    mkdir -p /etc/wireguard
    chmod 700 /etc/wireguard

    # Файлы для хранения ключей
    local privkey_file="/etc/wireguard/server_private.key"
    local pubkey_file="/etc/wireguard/server_public.key"

    if [[ -f "$privkey_file" && -f "$pubkey_file" ]]; then
        log_warn "Ключи сервера уже существуют, пропускаем генерацию"
        SERVER_PRIVATE_KEY=$(cat "$privkey_file")
        SERVER_PUBLIC_KEY=$(cat "$pubkey_file")
    else
        log_info "Генерация новой пары ключей сервера..."
        # Генерируем приватный ключ
        SERVER_PRIVATE_KEY=$(wg genkey)
        # Вычисляем публичный ключ из приватного
        SERVER_PUBLIC_KEY=$(echo "$SERVER_PRIVATE_KEY" | wg pubkey)

        # Сохраняем ключи в файлы с безопасными правами доступа
        echo "$SERVER_PRIVATE_KEY" > "$privkey_file"
        echo "$SERVER_PUBLIC_KEY"  > "$pubkey_file"
        chmod 600 "$privkey_file"
        chmod 644 "$pubkey_file"

        log_info "Приватный ключ сервера: ${privkey_file}"
        log_info "Публичный ключ сервера:  ${pubkey_file}"
    fi

    log_info "Публичный ключ сервера: ${SERVER_PUBLIC_KEY}"
}

# ─────────────────────────────────────────────────────────────────────────────
# ШАГ 4: СОЗДАНИЕ КОНФИГУРАЦИОННОГО ФАЙЛА СЕРВЕРА
# ─────────────────────────────────────────────────────────────────────────────
create_server_config() {
    log_section "Создание конфигурации сервера"

    if [[ -f "$WG_CONFIG" ]]; then
        log_warn "Конфиг ${WG_CONFIG} уже существует — пропускаем создание"
        log_warn "Для пересоздания удалите файл вручную и перезапустите скрипт"
        return 0
    fi

    log_info "Создание ${WG_CONFIG}..."

    cat > "$WG_CONFIG" <<EOF
# ─────────────────────────────────────────────────────────────────────────────
# WireGuard Server Configuration
# Сгенерировано: $(date '+%Y-%m-%d %H:%M:%S')
# Публичный IP сервера: ${SERVER_PUBLIC_IP}
# ─────────────────────────────────────────────────────────────────────────────

[Interface]
# IP-адрес сервера в VPN-подсети
Address = ${SERVER_VPN_IP}/${VPN_CIDR}

# UDP-порт для входящих подключений WireGuard
ListenPort = ${WG_PORT}

# Приватный ключ сервера (ДЕРЖАТЬ В СЕКРЕТЕ)
PrivateKey = ${SERVER_PRIVATE_KEY}

# ─── Правила iptables ────────────────────────────────────────────────────────
# PostUp — выполняются при поднятии интерфейса wg0:
#   1. FORWARD: разрешаем пересылку пакетов через wg0 (трафик клиентов)
#   2. MASQUERADE: маскируем источник пакетов (NAT) — клиенты выходят
#      в интернет с IP сервера ${SERVER_PUBLIC_IP}
PostUp   = iptables -A FORWARD -i ${WG_INTERFACE} -j ACCEPT; \
           iptables -A FORWARD -o ${WG_INTERFACE} -j ACCEPT; \
           iptables -t nat -A POSTROUTING -o ${MAIN_IFACE} -j MASQUERADE

# PostDown — выполняются при опускании интерфейса (очистка правил):
PostDown = iptables -D FORWARD -i ${WG_INTERFACE} -j ACCEPT; \
           iptables -D FORWARD -o ${WG_INTERFACE} -j ACCEPT; \
           iptables -t nat -D POSTROUTING -o ${MAIN_IFACE} -j MASQUERADE

# ─── Секции [Peer] для клиентов добавляются ниже скриптом add_client.sh ────
EOF

    chmod 600 "$WG_CONFIG"
    log_info "Конфигурация сервера создана: ${WG_CONFIG}"
}

# ─────────────────────────────────────────────────────────────────────────────
# ШАГ 5: НАСТРОЙКА UFW (БРАНДМАУЭР)
# ─────────────────────────────────────────────────────────────────────────────
configure_firewall() {
    log_section "Настройка брандмауэра UFW"

    # Устанавливаем политику по умолчанию: блокировать входящие, разрешать исходящие
    ufw default deny incoming  > /dev/null
    ufw default allow outgoing > /dev/null

    # Разрешаем SSH (порт 22) — ОБЯЗАТЕЛЬНО, иначе потеряем доступ к серверу
    ufw allow 22/tcp comment 'SSH' > /dev/null
    log_info "Разрешён SSH (22/tcp)"

    # Разрешаем WireGuard UDP-порт
    ufw allow "${WG_PORT}/udp" comment 'WireGuard VPN' > /dev/null
    log_info "Разрешён WireGuard (${WG_PORT}/udp)"

    # Разрешаем HTTP/HTTPS (опционально, если сервер используется как веб-сервер)
    # ufw allow 80/tcp comment 'HTTP'   > /dev/null
    # ufw allow 443/tcp comment 'HTTPS' > /dev/null

    # Включаем UFW без интерактивного запроса
    ufw --force enable > /dev/null
    log_info "UFW включён и настроен"

    # Показываем статус
    ufw status numbered
}

# ─────────────────────────────────────────────────────────────────────────────
# ШАГ 6: НАСТРОЙКА АВТООБНОВЛЕНИЙ БЕЗОПАСНОСТИ
# ─────────────────────────────────────────────────────────────────────────────
configure_auto_updates() {
    log_section "Настройка автоматических обновлений безопасности"

    # Конфигурация unattended-upgrades
    cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'APTEOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};

// Автоматически удалять неиспользуемые пакеты
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";

// Автоматически перезагружать при необходимости (осторожно для prod!)
Unattended-Upgrade::Automatic-Reboot "false";

// Логировать действия
Unattended-Upgrade::SyslogEnable "true";
APTEOF

    # Настройка периодичности запуска
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'APTEOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
APTEOF

    # Включаем и запускаем сервис
    systemctl enable unattended-upgrades > /dev/null 2>&1
    systemctl start  unattended-upgrades > /dev/null 2>&1
    log_info "Автообновления безопасности настроены и включены"
}

# ─────────────────────────────────────────────────────────────────────────────
# ШАГ 7: ЗАПУСК WIREGUARD
# ─────────────────────────────────────────────────────────────────────────────
start_wireguard() {
    log_section "Запуск WireGuard"

    # Включаем автозапуск при загрузке системы
    systemctl enable "wg-quick@${WG_INTERFACE}" > /dev/null 2>&1
    log_info "Автозапуск wg-quick@${WG_INTERFACE} включён"

    # Запускаем (или перезапускаем) WireGuard
    if systemctl is-active --quiet "wg-quick@${WG_INTERFACE}"; then
        log_warn "WireGuard уже запущен — перезапускаем для применения конфигурации"
        systemctl restart "wg-quick@${WG_INTERFACE}"
    else
        systemctl start "wg-quick@${WG_INTERFACE}"
    fi

    # Проверяем статус
    if systemctl is-active --quiet "wg-quick@${WG_INTERFACE}"; then
        log_info "WireGuard успешно запущен"
        wg show "${WG_INTERFACE}" 2>/dev/null || true
    else
        log_error "Не удалось запустить WireGuard. Проверьте: journalctl -u wg-quick@${WG_INTERFACE}"
        exit 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# ШАГ 8: СОЗДАНИЕ СКРИПТА ДОБАВЛЕНИЯ КЛИЕНТОВ
# /usr/local/bin/add_client.sh
# ─────────────────────────────────────────────────────────────────────────────
create_add_client_script() {
    log_section "Создание скрипта add_client.sh"

    cat > "$ADD_CLIENT_SCRIPT" <<ADDEOF
#!/bin/bash
# =============================================================================
# add_client.sh — Добавление нового WireGuard клиента
# =============================================================================
# Использование: sudo add_client.sh <имя_клиента>
# Пример:        sudo add_client.sh phone_ivan
# =============================================================================

set -euo pipefail

# ─── Настройки (должны совпадать с настройками сервера) ─────────────────────
SERVER_PUBLIC_IP="${SERVER_PUBLIC_IP}"
SERVER_PUBLIC_KEY_FILE="/etc/wireguard/server_public.key"
WG_INTERFACE="${WG_INTERFACE}"
WG_PORT="${WG_PORT}"
WG_CONFIG="${WG_CONFIG}"
CLIENTS_DIR="${CLIENTS_DIR}"
VPN_SUBNET_BASE="10.0.0"    # Первые три октета подсети
CLIENT_DNS="${CLIENT_DNS}"

# Цвета
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info()  { echo -e "\${GREEN}[INFO]\${NC}  \$*"; }
log_warn()  { echo -e "\${YELLOW}[WARN]\${NC}  \$*"; }
log_error() { echo -e "\${RED}[ERROR]\${NC} \$*" >&2; }

# ─── Проверки ────────────────────────────────────────────────────────────────
[[ \$EUID -ne 0 ]] && { log_error "Запустите от root: sudo add_client.sh <имя>"; exit 1; }
[[ \$# -lt 1 ]]   && { log_error "Укажите имя клиента: sudo add_client.sh <имя>"; exit 1; }

CLIENT_NAME="\$1"
# Проверяем имя: только буквы, цифры, дефис, подчёркивание
[[ ! "\$CLIENT_NAME" =~ ^[a-zA-Z0-9_-]+\$ ]] && {
    log_error "Имя клиента должно содержать только буквы, цифры, '-' и '_'"
    exit 1
}

# Создаём директорию для конфигов клиентов
mkdir -p "\$CLIENTS_DIR"
chmod 700 "\$CLIENTS_DIR"

CLIENT_DIR="\${CLIENTS_DIR}/\${CLIENT_NAME}"

# Проверяем, не существует ли уже такой клиент
if [[ -d "\$CLIENT_DIR" ]]; then
    log_warn "Клиент '\${CLIENT_NAME}' уже существует: \${CLIENT_DIR}"
    log_warn "Для пересоздания сначала удалите клиента: sudo remove_client.sh \${CLIENT_NAME}"
    exit 1
fi

# ─── Определяем следующий свободный IP ──────────────────────────────────────
# IP сервера: 10.0.0.1, клиенты: 10.0.0.2 — 10.0.0.254
find_next_ip() {
    local used_ips
    # Собираем все занятые IP из конфига сервера
    used_ips=\$(grep "AllowedIPs" "\$WG_CONFIG" 2>/dev/null | grep -oP '\d+\.\d+\.\d+\.\K\d+' || true)

    for i in \$(seq 2 254); do
        # Проверяем, не занят ли этот номер
        if ! echo "\$used_ips" | grep -qx "\$i"; then
            echo "\$i"
            return 0
        fi
    done

    log_error "Подсеть заполнена (нет свободных IP в диапазоне 10.0.0.2-254)"
    exit 1
}

NEXT_OCTET=\$(find_next_ip)
CLIENT_VPN_IP="\${VPN_SUBNET_BASE}.\${NEXT_OCTET}"
log_info "Назначен VPN IP клиенту: \${CLIENT_VPN_IP}"

# ─── Генерация ключей клиента ────────────────────────────────────────────────
mkdir -p "\$CLIENT_DIR"
chmod 700 "\$CLIENT_DIR"

CLIENT_PRIVATE_KEY=\$(wg genkey)
CLIENT_PUBLIC_KEY=\$(echo "\$CLIENT_PRIVATE_KEY" | wg pubkey)
CLIENT_PRESHARED_KEY=\$(wg genpsk)  # Дополнительный слой шифрования (PSK)

# Сохраняем ключи
echo "\$CLIENT_PRIVATE_KEY"   > "\${CLIENT_DIR}/private.key"
echo "\$CLIENT_PUBLIC_KEY"    > "\${CLIENT_DIR}/public.key"
echo "\$CLIENT_PRESHARED_KEY" > "\${CLIENT_DIR}/preshared.key"
chmod 600 "\${CLIENT_DIR}/private.key" "\${CLIENT_DIR}/preshared.key"

log_info "Ключи клиента сгенерированы"

# ─── Создание конфига клиента ────────────────────────────────────────────────
SERVER_PUBLIC_KEY=\$(cat "\$SERVER_PUBLIC_KEY_FILE")
CLIENT_CONF="\${CLIENT_DIR}/\${CLIENT_NAME}.conf"

cat > "\$CLIENT_CONF" <<CLIENTCONF
# ─────────────────────────────────────────────────────────────────────────────
# WireGuard Client Configuration: \${CLIENT_NAME}
# Создан: \$(date '+%Y-%m-%d %H:%M:%S')
# VPN IP клиента: \${CLIENT_VPN_IP}/32
# ─────────────────────────────────────────────────────────────────────────────

[Interface]
# Приватный ключ клиента
PrivateKey = \${CLIENT_PRIVATE_KEY}

# IP-адрес клиента в VPN-подсети
Address = \${CLIENT_VPN_IP}/32

# DNS-серверы для использования через VPN
DNS = \${CLIENT_DNS}

[Peer]
# Публичный ключ сервера
PublicKey = \${SERVER_PUBLIC_KEY}

# Pre-shared key (дополнительный уровень защиты)
PresharedKey = \${CLIENT_PRESHARED_KEY}

# Адрес и порт VPN-сервера
Endpoint = \${SERVER_PUBLIC_IP}:\${WG_PORT}

# 0.0.0.0/0 = весь трафик клиента идёт через VPN (full tunnel)
# Для split-tunnel замените на конкретные подсети, например: 10.0.0.0/24
AllowedIPs = 0.0.0.0/0, ::/0

# Keepalive: отправлять пинг каждые 25 сек (важно за NAT)
PersistentKeepalive = 25
CLIENTCONF

chmod 600 "\$CLIENT_CONF"
log_info "Конфиг клиента создан: \${CLIENT_CONF}"

# ─── Добавляем клиента в конфиг сервера ──────────────────────────────────────
log_info "Добавление клиента в конфиг сервера..."

cat >> "\$WG_CONFIG" <<PEERCONF

# ─── Клиент: \${CLIENT_NAME} (добавлен \$(date '+%Y-%m-%d %H:%M:%S')) ───────
[Peer]
# Имя клиента: \${CLIENT_NAME}
PublicKey = \${CLIENT_PUBLIC_KEY}
PresharedKey = \${CLIENT_PRESHARED_KEY}
# IP-адрес клиента — сервер будет маршрутизировать пакеты только на этот адрес
AllowedIPs = \${CLIENT_VPN_IP}/32
PEERCONF

log_info "Клиент добавлен в \${WG_CONFIG}"

# ─── Применяем конфигурацию без перезапуска сервиса ─────────────────────────
# wg addpeer позволяет добавить peer «на горячую» без разрыва соединений
if systemctl is-active --quiet "wg-quick@\${WG_INTERFACE}"; then
    wg addpeer "\${WG_INTERFACE}" \
        "\${CLIENT_PUBLIC_KEY}" \
        preshared-key <(echo "\${CLIENT_PRESHARED_KEY}") \
        allowed-ips "\${CLIENT_VPN_IP}/32" 2>/dev/null || \
    wg syncconf "\${WG_INTERFACE}" <(wg-quick strip "\${WG_INTERFACE}")
    log_info "Конфигурация WireGuard обновлена «на горячую»"
fi

# ─── Генерация QR-кода ───────────────────────────────────────────────────────
QR_FILE="\${CLIENT_DIR}/\${CLIENT_NAME}.png"
log_info "Генерация QR-кода..."

# QR в терминале (для немедленного сканирования)
echo ""
echo "════════════════════════════════════════════════════════"
echo "  QR-код для \${CLIENT_NAME} (сканируйте в приложении WireGuard)"
echo "════════════════════════════════════════════════════════"
qrencode -t ansiutf8 < "\$CLIENT_CONF"

# QR как PNG-файл
qrencode -t png -o "\$QR_FILE" < "\$CLIENT_CONF"
chmod 600 "\$QR_FILE"

# ─── Итоговая информация ─────────────────────────────────────────────────────
echo ""
echo -e "\${GREEN}════════════════════════════════════════════════════════\${NC}"
echo -e "\${GREEN}  Клиент '\${CLIENT_NAME}' успешно добавлен!\${NC}"
echo -e "\${GREEN}════════════════════════════════════════════════════════\${NC}"
echo "  VPN IP клиента : \${CLIENT_VPN_IP}"
echo "  Конфиг файл    : \${CLIENT_CONF}"
echo "  QR PNG файл    : \${QR_FILE}"
echo ""
echo "  Для скачивания конфига на локальный компьютер:"
echo "  scp root@\${SERVER_PUBLIC_IP}:\${CLIENT_CONF} ./\${CLIENT_NAME}.conf"
echo ""
ADDEOF

    chmod +x "$ADD_CLIENT_SCRIPT"
    log_info "Скрипт создан: ${ADD_CLIENT_SCRIPT}"
}

# ─────────────────────────────────────────────────────────────────────────────
# ШАГ 9: СОЗДАНИЕ СКРИПТА УДАЛЕНИЯ КЛИЕНТОВ
# /usr/local/bin/remove_client.sh
# ─────────────────────────────────────────────────────────────────────────────
create_remove_client_script() {
    log_section "Создание скрипта remove_client.sh"

    cat > "$REMOVE_CLIENT_SCRIPT" <<REMOVEEOF
#!/bin/bash
# =============================================================================
# remove_client.sh — Удаление WireGuard клиента
# =============================================================================
# Использование:
#   sudo remove_client.sh <имя_клиента>        # по имени
#   sudo remove_client.sh --ip 10.0.0.5        # по VPN IP
#   sudo remove_client.sh --list               # показать всех клиентов
# =============================================================================

set -euo pipefail

WG_INTERFACE="${WG_INTERFACE}"
WG_CONFIG="${WG_CONFIG}"
CLIENTS_DIR="${CLIENTS_DIR}"

# Цвета
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { echo -e "\${GREEN}[INFO]\${NC}  \$*"; }
log_warn()  { echo -e "\${YELLOW}[WARN]\${NC}  \$*"; }
log_error() { echo -e "\${RED}[ERROR]\${NC} \$*" >&2; }

# ─── Проверки ────────────────────────────────────────────────────────────────
[[ \$EUID -ne 0 ]] && { log_error "Запустите от root: sudo remove_client.sh <имя>"; exit 1; }
[[ \$# -lt 1 ]]   && {
    echo "Использование:"
    echo "  sudo remove_client.sh <имя>         — удалить по имени"
    echo "  sudo remove_client.sh --ip 10.0.0.X — удалить по IP"
    echo "  sudo remove_client.sh --list        — список клиентов"
    exit 1
}

# ─── Вывод списка клиентов ───────────────────────────────────────────────────
if [[ "\$1" == "--list" ]]; then
    echo -e "\${BLUE}Список зарегистрированных клиентов:\${NC}"
    echo ""
    if [[ ! -d "\$CLIENTS_DIR" ]] || [[ -z "\$(ls -A "\$CLIENTS_DIR" 2>/dev/null)" ]]; then
        echo "  (нет клиентов)"
    else
        printf "  %-20s %-15s %-20s\n" "Имя" "VPN IP" "Дата создания"
        printf "  %-20s %-15s %-20s\n" "────────────────────" "───────────────" "────────────────────"
        for dir in "\${CLIENTS_DIR}"/*/; do
            [[ -d "\$dir" ]] || continue
            cname=\$(basename "\$dir")
            # Ищем IP клиента в его конфиге
            cip=\$(grep "^Address" "\${dir}\${cname}.conf" 2>/dev/null | awk '{print \$3}' | cut -d/ -f1 || echo "?")
            cdate=\$(stat -c %y "\${dir}" 2>/dev/null | cut -d' ' -f1 || echo "?")
            printf "  %-20s %-15s %-20s\n" "\$cname" "\$cip" "\$cdate"
        done
    fi
    echo ""
    echo -e "\${BLUE}Активные WireGuard peers:\${NC}"
    wg show "\$WG_INTERFACE" 2>/dev/null || echo "  WireGuard не запущен"
    exit 0
fi

# ─── Определяем клиента для удаления ─────────────────────────────────────────
CLIENT_NAME=""
TARGET_IP=""

if [[ "\$1" == "--ip" ]]; then
    [[ \$# -lt 2 ]] && { log_error "Укажите IP: --ip 10.0.0.X"; exit 1; }
    TARGET_IP="\$2"
    # Ищем имя клиента по IP в его конфиге
    for dir in "\${CLIENTS_DIR}"/*/; do
        [[ -d "\$dir" ]] || continue
        cname=\$(basename "\$dir")
        cip=\$(grep "^Address" "\${dir}\${cname}.conf" 2>/dev/null | awk '{print \$3}' | cut -d/ -f1 || echo "")
        if [[ "\$cip" == "\$TARGET_IP" ]]; then
            CLIENT_NAME="\$cname"
            break
        fi
    done
    [[ -z "\$CLIENT_NAME" ]] && { log_error "Клиент с IP \${TARGET_IP} не найден"; exit 1; }
else
    CLIENT_NAME="\$1"
fi

CLIENT_DIR="\${CLIENTS_DIR}/\${CLIENT_NAME}"

# ─── Проверяем существование клиента ─────────────────────────────────────────
if [[ ! -d "\$CLIENT_DIR" ]]; then
    log_error "Клиент '\${CLIENT_NAME}' не найден в \${CLIENTS_DIR}"
    log_warn  "Используйте --list для просмотра существующих клиентов"
    exit 1
fi

# Получаем публичный ключ клиента (нужен для удаления из WireGuard)
CLIENT_PUBKEY=\$(cat "\${CLIENT_DIR}/public.key" 2>/dev/null || "")
CLIENT_IP=\$(grep "^Address" "\${CLIENT_DIR}/\${CLIENT_NAME}.conf" 2>/dev/null | awk '{print \$3}' | cut -d/ -f1 || echo "?")

log_info "Удаление клиента: \${CLIENT_NAME} (IP: \${CLIENT_IP})"

# ─── Подтверждение ───────────────────────────────────────────────────────────
echo -e "\${YELLOW}ВНИМАНИЕ: Клиент '\${CLIENT_NAME}' (IP: \${CLIENT_IP}) будет удалён!\${NC}"
read -r -p "Продолжить? [y/N] " confirm
[[ "\$confirm" =~ ^[Yy]\$ ]] || { log_warn "Отменено"; exit 0; }

# ─── Удаляем peer из работающего WireGuard «на горячую» ──────────────────────
if [[ -n "\$CLIENT_PUBKEY" ]] && systemctl is-active --quiet "wg-quick@\${WG_INTERFACE}"; then
    if wg show "\$WG_INTERFACE" peers 2>/dev/null | grep -q "\$CLIENT_PUBKEY"; then
        wg set "\$WG_INTERFACE" peer "\$CLIENT_PUBKEY" remove
        log_info "Peer удалён из активного WireGuard интерфейса"
    else
        log_warn "Peer не найден в активном интерфейсе (возможно уже удалён)"
    fi
fi

# ─── Удаляем секцию [Peer] из конфига сервера ────────────────────────────────
# Создаём резервную копию конфига
cp "\$WG_CONFIG" "\${WG_CONFIG}.bak.\$(date +%Y%m%d_%H%M%S)"
log_info "Резервная копия конфига создана"

if [[ -n "\$CLIENT_PUBKEY" ]]; then
    # Python-скрипт для точного удаления секции [Peer] по публичному ключу
    # Bash не очень подходит для парсинга INI-файлов, Python надёжнее
    python3 - "\$WG_CONFIG" "\$CLIENT_PUBKEY" <<'PYEOF'
import sys, re

config_file = sys.argv[1]
pubkey = sys.argv[2]

with open(config_file, 'r') as f:
    content = f.read()

# Разбиваем на блоки по заголовкам [Interface] и [Peer]
# Удаляем блок [Peer], содержащий нужный публичный ключ
# Также удаляем комментарии-заголовки клиента (строки перед [Peer])
pattern = r'\n# ─+[^\n]*\n# Клиент: [^\n]*\n# ─+[^\n]*\n\[Peer\]\n(?:[^\[]*)'
blocks = re.split(r'(?=\n# ─+[^\n]*\n# Клиент:|\n\[Peer\])', content)

result_blocks = []
for block in blocks:
    if '[Peer]' in block and pubkey in block:
        print(f"Удалена секция [Peer] с ключом {pubkey[:20]}...", file=sys.stderr)
        continue
    result_blocks.append(block)

new_content = ''.join(result_blocks).rstrip() + '\n'

with open(config_file, 'w') as f:
    f.write(new_content)

print(f"Конфиг сохранён: {config_file}", file=sys.stderr)
PYEOF
    log_info "Секция [Peer] удалена из \${WG_CONFIG}"
else
    log_warn "Публичный ключ не найден, конфиг сервера не изменён"
    log_warn "Проверьте и отредактируйте \${WG_CONFIG} вручную"
fi

# ─── Удаляем директорию клиента ──────────────────────────────────────────────
rm -rf "\$CLIENT_DIR"
log_info "Директория клиента удалена: \${CLIENT_DIR}"

# ─── Перезапускаем WireGuard для применения изменений ────────────────────────
if systemctl is-active --quiet "wg-quick@\${WG_INTERFACE}"; then
    systemctl restart "wg-quick@\${WG_INTERFACE}"
    log_info "WireGuard перезапущен"
fi

echo ""
echo -e "\${GREEN}Клиент '\${CLIENT_NAME}' (IP: \${CLIENT_IP}) успешно удалён\${NC}"
echo ""
REMOVEEOF

    chmod +x "$REMOVE_CLIENT_SCRIPT"
    log_info "Скрипт создан: ${REMOVE_CLIENT_SCRIPT}"
}

# ─────────────────────────────────────────────────────────────────────────────
# ШАГ 10: СОЗДАНИЕ ДИРЕКТОРИИ ДЛЯ КЛИЕНТОВ
# ─────────────────────────────────────────────────────────────────────────────
create_clients_directory() {
    mkdir -p "$CLIENTS_DIR"
    chmod 700 "$CLIENTS_DIR"
    log_info "Директория для клиентских конфигов: ${CLIENTS_DIR}"
}

# ─────────────────────────────────────────────────────────────────────────────
# ИТОГОВЫЙ ВЫВОД
# ─────────────────────────────────────────────────────────────────────────────
print_summary() {
    log_section "Установка завершена"

    echo ""
    echo "  Публичный IP сервера : ${SERVER_PUBLIC_IP}"
    echo "  WireGuard интерфейс  : ${WG_INTERFACE}"
    echo "  UDP порт             : ${WG_PORT}"
    echo "  VPN подсеть          : ${VPN_SUBNET}"
    echo "  IP сервера в VPN     : ${SERVER_VPN_IP}"
    echo "  Конфиг сервера       : ${WG_CONFIG}"
    echo "  Конфиги клиентов     : ${CLIENTS_DIR}"
    echo ""
    echo "  Публичный ключ сервера: $(cat /etc/wireguard/server_public.key)"
    echo ""
    echo "  Управление клиентами:"
    echo "    Добавить клиента  : sudo add_client.sh <имя>"
    echo "    Удалить клиента   : sudo remove_client.sh <имя>"
    echo "    Список клиентов   : sudo remove_client.sh --list"
    echo ""
    echo "  Управление сервисом:"
    echo "    Статус            : sudo systemctl status wg-quick@${WG_INTERFACE}"
    echo "    Остановить        : sudo systemctl stop wg-quick@${WG_INTERFACE}"
    echo "    Перезапустить     : sudo systemctl restart wg-quick@${WG_INTERFACE}"
    echo "    Показать peers    : sudo wg show ${WG_INTERFACE}"
    echo "    Логи              : sudo journalctl -u wg-quick@${WG_INTERFACE} -f"
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# ГЛАВНАЯ ФУНКЦИЯ — ПОСЛЕДОВАТЕЛЬНОСТЬ ВЫПОЛНЕНИЯ
# ─────────────────────────────────────────────────────────────────────────────
main() {
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║   WireGuard VPN Setup — Ubuntu 22.04                 ║${NC}"
    echo -e "${BLUE}║   Сервер: ${SERVER_PUBLIC_IP}                        ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""

    check_root                  # 0. Проверка прав root
    detect_main_interface       # 0. Определение сетевого интерфейса
    install_packages            # 1. Установка пакетов
    enable_ip_forwarding        # 2. Включение форвардинга
    generate_server_keys        # 3. Генерация ключей сервера
    create_server_config        # 4. Конфиг сервера
    create_clients_directory    # 5. Директория клиентов
    configure_firewall          # 6. Брандмауэр UFW
    configure_auto_updates      # 7. Автообновления
    create_add_client_script    # 8. Скрипт добавления клиентов
    create_remove_client_script # 9. Скрипт удаления клиентов
    start_wireguard             # 10. Запуск WireGuard
    print_summary               # 11. Итоговая информация
}

# Запуск
main "$@"
