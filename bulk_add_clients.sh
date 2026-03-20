#!/bin/bash
# =============================================================================
# bulk_add_clients.sh — Массовое добавление WireGuard клиентов
# =============================================================================
# Использование:
#   sudo bash bulk_add_clients.sh                        # добавить user_001..user_150
#   sudo bash bulk_add_clients.sh 50                     # добавить user_001..user_050
#   sudo bash bulk_add_clients.sh 150 vpn_user           # добавить vpn_user_001..vpn_user_150
#   sudo bash bulk_add_clients.sh 150 vpn_user 20        # начать с vpn_user_020
# =============================================================================

set -euo pipefail

# ─── Параметры ───────────────────────────────────────────────────────────────
TOTAL=${1:-150}          # Количество клиентов (по умолчанию 150)
PREFIX=${2:-"user"}      # Префикс имени (по умолчанию "user")
START_FROM=${3:-1}       # Начать с номера (по умолчанию 1)

ADD_CLIENT_SCRIPT="/usr/local/bin/add_client.sh"
CLIENTS_DIR="/etc/wireguard/clients"
OUTPUT_DIR="/root/wg_clients_export"   # Директория для экспорта конфигов

# Цвета
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_section() { echo -e "\n${BLUE}══════════════════════════════════════════${NC}"; echo -e "${BLUE}  $*${NC}"; echo -e "${BLUE}══════════════════════════════════════════${NC}"; }

# ─── Проверки ─────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && { log_error "Запустите от root: sudo bash $0"; exit 1; }

if [[ ! -f "$ADD_CLIENT_SCRIPT" ]]; then
    log_error "Скрипт add_client.sh не найден: ${ADD_CLIENT_SCRIPT}"
    log_error "Сначала запустите setup_wireguard.sh"
    exit 1
fi

# Проверяем корректность параметров
if ! [[ "$TOTAL" =~ ^[0-9]+$ ]] || [[ $TOTAL -lt 1 ]]; then
    log_error "Некорректное количество клиентов: ${TOTAL}"
    exit 1
fi

if [[ $((TOTAL + 1)) -gt 253 ]]; then
    log_error "Слишком много клиентов! Максимум для /24 подсети: 253"
    log_error "Учтите уже существующих клиентов при планировании"
    exit 1
fi

# ─── Подготовка ───────────────────────────────────────────────────────────────
mkdir -p "$OUTPUT_DIR"

END_AT=$(( START_FROM + TOTAL - 1 ))

log_section "Массовое добавление WireGuard клиентов"
echo "  Префикс имени  : ${PREFIX}"
echo "  Диапазон       : ${PREFIX}_$(printf '%03d' $START_FROM) — ${PREFIX}_$(printf '%03d' $END_AT)"
echo "  Всего клиентов : ${TOTAL}"
echo "  Экспорт в      : ${OUTPUT_DIR}"
echo ""

# ─── Предупреждение об имеющихся клиентах ────────────────────────────────────
EXISTING_COUNT=0
if [[ -d "$CLIENTS_DIR" ]]; then
    EXISTING_COUNT=$(find "$CLIENTS_DIR" -maxdepth 1 -mindepth 1 -type d | wc -l)
fi

if [[ $EXISTING_COUNT -gt 0 ]]; then
    log_warn "Уже существует клиентов: ${EXISTING_COUNT}"
    log_warn "Общее количество после добавления: $((EXISTING_COUNT + TOTAL))"
    if [[ $((EXISTING_COUNT + TOTAL + 1)) -gt 253 ]]; then
        log_error "ОШИБКА: Превышен лимит /24 подсети (253 клиента)"
        log_error "Уже есть: ${EXISTING_COUNT}, добавляется: ${TOTAL}, итого: $((EXISTING_COUNT + TOTAL))"
        exit 1
    fi
fi

# ─── Подтверждение ────────────────────────────────────────────────────────────
echo ""
read -r -p "Начать добавление ${TOTAL} клиентов? [y/N] " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { log_warn "Отменено"; exit 0; }

# ─── Счётчики ─────────────────────────────────────────────────────────────────
ADDED=0
SKIPPED=0
FAILED=0
FAILED_NAMES=()

log_section "Добавление клиентов..."

START_TIME=$(date +%s)

# ─── Основной цикл добавления ────────────────────────────────────────────────
for i in $(seq "$START_FROM" "$END_AT"); do
    CLIENT_NAME="${PREFIX}_$(printf '%03d' $i)"

    # Пропускаем уже существующих
    if [[ -d "${CLIENTS_DIR}/${CLIENT_NAME}" ]]; then
        log_warn "Пропуск (уже существует): ${CLIENT_NAME}"
        (( SKIPPED++ )) || true
        continue
    fi

    # Добавляем клиента
    printf "${GREEN}[%3d/%d]${NC} Добавляем %-25s ... " "$((ADDED + SKIPPED + FAILED + 1))" "$TOTAL" "$CLIENT_NAME"

    if bash "$ADD_CLIENT_SCRIPT" "$CLIENT_NAME" > /tmp/add_client_output.log 2>&1; then
        # Копируем конфиг в папку экспорта
        CONF_SRC="${CLIENTS_DIR}/${CLIENT_NAME}/${CLIENT_NAME}.conf"
        if [[ -f "$CONF_SRC" ]]; then
            cp "$CONF_SRC" "${OUTPUT_DIR}/${CLIENT_NAME}.conf"
        fi
        echo -e "${GREEN}OK${NC}"
        (( ADDED++ )) || true
    else
        echo -e "${RED}ОШИБКА${NC}"
        cat /tmp/add_client_output.log >&2
        FAILED_NAMES+=("$CLIENT_NAME")
        (( FAILED++ )) || true
    fi

    # Небольшая пауза каждые 10 клиентов для снижения нагрузки
    if [[ $((( ADDED + SKIPPED ) % 10)) -eq 0 ]] && [[ $(( ADDED + SKIPPED )) -gt 0 ]]; then
        sleep 0.5
    fi
done

# ─── Создание архива конфигов ─────────────────────────────────────────────────
END_TIME=$(date +%s)
DURATION=$(( END_TIME - START_TIME ))

if [[ $ADDED -gt 0 ]]; then
    ARCHIVE_NAME="wg_clients_$(date +%Y%m%d_%H%M%S).tar.gz"
    tar -czf "/root/${ARCHIVE_NAME}" -C "$OUTPUT_DIR" .
    log_info "Архив с конфигами: /root/${ARCHIVE_NAME}"
    log_info "Для скачивания: scp root@SERVER_IP:/root/${ARCHIVE_NAME} ./"
fi

# ─── Итог ─────────────────────────────────────────────────────────────────────
log_section "Готово"
echo ""
echo "  Время выполнения : ${DURATION} сек"
echo "  Добавлено        : ${ADDED}"
echo "  Пропущено        : ${SKIPPED}"
echo "  Ошибок           : ${FAILED}"
echo ""

if [[ ${#FAILED_NAMES[@]} -gt 0 ]]; then
    log_warn "Не удалось добавить:"
    for name in "${FAILED_NAMES[@]}"; do
        echo "    - $name"
    done
fi

# Показываем итоговую статистику WireGuard
echo ""
log_info "Текущее состояние WireGuard:"
wg show wg0 2>/dev/null | head -20 || echo "  WireGuard не запущен"

TOTAL_CLIENTS=0
if [[ -d "$CLIENTS_DIR" ]]; then
    TOTAL_CLIENTS=$(find "$CLIENTS_DIR" -maxdepth 1 -mindepth 1 -type d | wc -l)
fi

echo ""
echo -e "${GREEN}Итого зарегистрировано клиентов: ${TOTAL_CLIENTS}${NC}"
echo "Конфиги для раздачи: ${OUTPUT_DIR}/"
echo ""
