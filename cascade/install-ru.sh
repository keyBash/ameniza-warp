#!/bin/bash
# Установка российского входного узла каскада.
# Перед запуском:
#   1) на этом сервере установлена Amnezia (AmneziaWG) через приложение;
#   2) рядом лежит ключ зарубежного сервера в родном формате AmneziaWG:
#      /root/ru-gateway.conf  (или путь первым аргументом)
# Запуск:  bash install-ru.sh [/путь/к/ru-gateway.conf]
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="${1:-/root/ru-gateway.conf}"
TUN=fi
CONF_DIR=/etc/amnezia/amneziawg

[ "$(id -u)" -eq 0 ] || { echo "Запускать от root"; exit 1; }
[ -f "$SRC" ] || { echo "Нет файла ключа $SRC (родной формат AmneziaWG)"; exit 1; }
grep -q '^\[Peer\]' "$SRC" && grep -q '^Endpoint' "$SRC" || { echo "$SRC не похож на конфиг AmneziaWG"; exit 1; }
docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^amnezia-awg' || { echo "Сначала установите Amnezia (AmneziaWG) через приложение"; exit 1; }
sed -i 's/\r$//' "$DIR"/ru-cascade*.sh "$DIR"/ru-cascade*.service "$DIR"/ru-cascade*.timer "$DIR"/status-ru.sh "$SRC"

echo "[1/5] Пакеты AmneziaWG (может занять несколько минут - собирается модуль ядра)"
apt-get update -qq
apt-get install -y -qq software-properties-common ipset curl "linux-headers-$(uname -r)"
add-apt-repository -y ppa:amnezia/ppa >/dev/null
apt-get update -qq
apt-get install -y -qq amneziawg
command -v awg-quick >/dev/null || { echo "awg-quick не установился"; exit 1; }

echo "[2/5] Конфиг туннеля $TUN"
mkdir -p "$CONF_DIR"
install -m 600 "$SRC" "$CONF_DIR/$TUN.conf"
C="$CONF_DIR/$TUN.conf"
sed -i '/^DNS/d' "$C"                                          # не трогаем DNS сервера
grep -q '^Table' "$C" || sed -i '/^\[Interface\]/a Table = off' "$C"   # сами решаем, что в туннель
if grep -q '^MTU' "$C"; then sed -i 's/^MTU.*/MTU = 1380/' "$C"; else sed -i '/^\[Interface\]/a MTU = 1380' "$C"; fi
grep -q '^PersistentKeepalive' "$C" || sed -i '/^Endpoint/a PersistentKeepalive = 25' "$C"
systemctl enable awg-quick@$TUN >/dev/null 2>&1
systemctl restart awg-quick@$TUN

echo "[3/5] Проверка туннеля"
sleep 3
ip route add 1.1.1.1 dev $TUN 2>/dev/null || true
TRACE=$(curl -s --max-time 15 https://1.1.1.1/cdn-cgi/trace || true)
ip route del 1.1.1.1 dev $TUN 2>/dev/null || true
echo "$TRACE" | grep -E '^(ip|loc)=' || true
EXIT_IP=$(echo "$TRACE" | awk -F= '/^ip=/{print $2}')
MY_IP=$(curl -s --max-time 10 https://1.1.1.1/cdn-cgi/trace | awk -F= '/^ip=/{print $2}')
if [ -z "$EXIT_IP" ] || [ "$EXIT_IP" = "$MY_IP" ]; then
  echo "Туннель не работает (выход через туннель: '${EXIT_IP:-нет ответа}'). Проверьте: awg show $TUN"
  exit 1
fi
echo "      туннель работает: выход $EXIT_IP (этот сервер: $MY_IP)"

echo "[4/5] Скрипт и автозапуск"
install -m 755 "$DIR/ru-cascade.sh" /usr/local/sbin/ru-cascade.sh
install -m 755 "$DIR/ru-cascade-watchdog.sh" /usr/local/sbin/ru-cascade-watchdog.sh
install -m 755 "$DIR/status-ru.sh" /usr/local/sbin/ru-cascade-status
install -m 644 "$DIR/ru-cascade.service" /etc/systemd/system/ru-cascade.service
install -m 644 "$DIR/ru-cascade.timer" /etc/systemd/system/ru-cascade.timer
install -m 644 "$DIR/ru-cascade-watchdog.service" /etc/systemd/system/ru-cascade-watchdog.service
install -m 644 "$DIR/ru-cascade-watchdog.timer" /etc/systemd/system/ru-cascade-watchdog.timer
systemctl daemon-reload
systemctl enable ru-cascade.service ru-cascade.timer ru-cascade-watchdog.timer >/dev/null
systemctl start ru-cascade.timer ru-cascade-watchdog.timer

echo "[5/5] Применение правил"
/usr/local/sbin/ru-cascade.sh

cat <<'EOT'

Готово.
Проверка с ПК (Amnezia подключена к РОССИЙСКОМУ серверу, раздельное туннелирование ВЫКЛ):
  yandex.ru/internet  -> IP российского сервера
  ifconfig.me         -> IP зарубежного сервера (или Cloudflare, если на нём стоит install-fi.sh)
  chatgpt.com, youtube.com открываются
Состояние на сервере:  ru-cascade-status
Потом reboot и проверить ещё раз.
EOT
