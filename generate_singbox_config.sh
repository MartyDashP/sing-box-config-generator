#!/bin/bash
# generate_singbox_config.sh
# Скрипт для генерации конфигурации sing-box (VLESS + Reality) для нескольких пользователей.
# Читает base.conf рядом со скриптом, пишет /etc/sing-box/config.json и output.conf
#
# Режимы:
#   full   - полностью перегенерировать ключи, UUID всех пользователей и конфиг
#   update - сохранить существующие ключи и UUID известных пользователей,
#            сгенерировать UUID только для новых, обновить конфиг под текущий список
#
# Формат base.conf (лежит рядом со скриптом):
#   domain=example.ru
#   log_level=debug
#   server_name=MyServer
#   flag=🇷🇺          # опционально: флаг (эмодзи или текст) для названия профиля
#   # опционально (по умолчанию как в примере):
#   # handshake_server=127.0.0.1
#   # handshake_port=8443
#   # пользователи — просто имена, по одному на строку (комментарии и пустые строки игнорируются)
#   alice
#   bob
#   charlie
#
# Результирующий файл output.conf содержит:
#   - общие параметры и ключи (для возможности update)
#   - UUID каждого пользователя
#   - готовые vless:// ссылки

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_CONFIG="${SCRIPT_DIR}/base.conf"
OUTPUT_FILE="${SCRIPT_DIR}/output.conf"
CONFIG_JSON="/etc/sing-box/config.json"
BACKUP_JSON="/root/config.json.bak"

usage() {
  echo "Использование: $0 {full|update}"
  echo "  full   - полная перегенерация"
  echo "  update - добавить только новых пользователей (сравнение с output.conf)"
  exit 1
}

[[ $# -eq 1 ]] || usage
MODE="$1"
[[ "$MODE" == "full" || "$MODE" == "update" ]] || usage

[[ -f "$BASE_CONFIG" ]] || { echo "Ошибка: не найден $BASE_CONFIG"; exit 1; }
command -v sing-box >/dev/null || { echo "Ошибка: sing-box не найден в PATH"; exit 1; }

# ---------- Парсинг base.conf ----------
DOMAIN=""
LOG_LEVEL="info"
SERVER_NAME="server"
FLAG=""
HANDSHAKE_SERVER="127.0.0.1"
HANDSHAKE_PORT="8443"
declare -a USERS=()

while IFS= read -r line || [[ -n "$line" ]]; do
  # убираем комментарии и пробелы
  line="${line%%#*}"
  line="$(echo "$line" | xargs)"
  [[ -z "$line" ]] && continue

  if [[ "$line" == *=* ]]; then
    key="${line%%=*}"
    val="${line#*=}"
    val="$(echo "$val" | xargs)"
    case "$key" in
      domain)            DOMAIN="$val" ;;
      log_level)         LOG_LEVEL="$val" ;;
      server_name)       SERVER_NAME="$val" ;;
      flag)              FLAG="$val" ;;
      handshake_server)  HANDSHAKE_SERVER="$val" ;;
      handshake_port)    HANDSHAKE_PORT="$val" ;;
    esac
  else
    # имя пользователя
    USERS+=("$line")
  fi
done < "$BASE_CONFIG"

[[ -n "$DOMAIN" ]] || { echo "Ошибка: в base.conf не указан domain="; exit 1; }
[[ ${#USERS[@]} -gt 0 ]] || { echo "Ошибка: в base.conf нет ни одного пользователя"; exit 1; }

echo "Домен: $DOMAIN"
echo "Сервер: $SERVER_NAME"
[[ -n "$FLAG" ]] && echo "Флаг: $FLAG"
echo "Пользователей: ${#USERS[@]}"
echo "Режим: $MODE"

# ---------- Чтение существующего состояния (только для update) ----------
declare -A UUID_MAP
PRIV=""
PUB=""
SID=""

if [[ "$MODE" == "update" && -f "$OUTPUT_FILE" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^PRIVATE_KEY=(.*)$ ]]; then
      PRIV="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^PUBLIC_KEY=(.*)$ ]]; then
      PUB="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^SHORT_ID=(.*)$ ]]; then
      SID="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^USER_([^=]+)=(.*)$ ]]; then
      UUID_MAP["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
    fi
  done < "$OUTPUT_FILE"
  echo "Загружено состояние из $OUTPUT_FILE (пользователей в состоянии: ${#UUID_MAP[@]})"
fi

# ---------- Генерация ключей при необходимости ----------
if [[ "$MODE" == "full" || -z "$PRIV" || -z "$PUB" || -z "$SID" ]]; then
  echo "Генерация новой пары Reality-ключей и Short ID..."
  KP="$(sing-box generate reality-keypair)"
  PRIV="$(echo "$KP" | awk '/PrivateKey/{print $2}')"
  PUB="$(echo "$KP" | awk '/PublicKey/{print $2}')"
  SID="$(sing-box generate rand --hex 8)"
  # в full-режиме сбрасываем старые UUID
  if [[ "$MODE" == "full" ]]; then
    UUID_MAP=()
  fi
fi

[[ -n "$PRIV" && -n "$PUB" && -n "$SID" ]] || { echo "Ошибка генерации ключей"; exit 1; }

# ---------- Сбор пользователей и ссылок ----------
USERS_JSON=""
USER_STATE=""
declare -a LINKS=()
sep=""

for user in "${USERS[@]}"; do
  if [[ "$MODE" == "update" && -n "${UUID_MAP[$user]:-}" ]]; then
    uuid="${UUID_MAP[$user]}"
    echo "  $user — существующий UUID"
  else
    uuid="$(sing-box generate uuid)"
    echo "  $user — новый UUID"
  fi

  USERS_JSON+="${sep}{ \"uuid\": \"${uuid}\", \"flow\": \"xtls-rprx-vision\" }"
  sep=$',\n        '

  USER_STATE+="USER_${user}=${uuid}"$'\n'

  # Ссылка (фрагмент = [flag]server_name-user)
  if [[ -n "$FLAG" ]]; then
    remark="${FLAG} ${SERVER_NAME}-${user}"
  else
    remark="${SERVER_NAME}-${user}"
  fi
  link="vless://${uuid}@${DOMAIN}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DOMAIN}&fp=chrome&pbk=${PUB}&sid=${SID}&type=tcp#${remark}"
  LINKS+=("$link")
done

# ---------- Бэкап и запись config.json ----------
if [[ -f "$CONFIG_JSON" ]]; then
  cp -f "$CONFIG_JSON" "$BACKUP_JSON" || true
  echo "Бэкап сохранён в $BACKUP_JSON"
fi

cat > "$CONFIG_JSON" <<EOF
{
  "log": { "level": "${LOG_LEVEL}" },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": 443,
      "users": [
        ${USERS_JSON}
      ],
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "reality": {
          "enabled": true,
          "handshake": { "server": "${HANDSHAKE_SERVER}", "server_port": ${HANDSHAKE_PORT} },
          "private_key": "${PRIV}",
          "short_id": ["${SID}"]
        }
      }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ]
}
EOF

echo "Конфиг записан в $CONFIG_JSON"

# ---------- Проверка и перезапуск ----------
if sing-box check -c "$CONFIG_JSON"; then
  echo "Проверка конфига успешна"
  systemctl restart sing-box
  echo "sing-box перезапущен"
else
  echo "Ошибка: sing-box check не прошёл. Конфиг не применён."
  exit 1
fi

# ---------- Запись результирующего файла ----------
{
  echo "# sing-box VLESS+Reality — сгенерировано $(date '+%Y-%m-%d %H:%M:%S') (режим: ${MODE})"
  echo "# Этот файл используется скриптом для режима update. Ссылки ниже можно раздавать пользователям."
  echo
  echo "DOMAIN=${DOMAIN}"
  echo "LOG_LEVEL=${LOG_LEVEL}"
  echo "SERVER_NAME=${SERVER_NAME}"
  echo "FLAG=${FLAG}"
  echo "PRIVATE_KEY=${PRIV}"
  echo "PUBLIC_KEY=${PUB}"
  echo "SHORT_ID=${SID}"
  echo "HANDSHAKE_SERVER=${HANDSHAKE_SERVER}"
  echo "HANDSHAKE_PORT=${HANDSHAKE_PORT}"
  echo
  echo "# UUID пользователей (USER_<имя>=<uuid>)"
  echo -n "$USER_STATE"
  echo
  echo "# === Ссылки для подключения ==="
  for i in "${!USERS[@]}"; do
    echo "# ${USERS[$i]}"
    echo "${LINKS[$i]}"
    echo
  done
} > "$OUTPUT_FILE"

echo
echo "Готово. Результирующий файл: $OUTPUT_FILE"
echo "Ссылки:"
for link in "${LINKS[@]}"; do
  echo "$link"
done
