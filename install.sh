#!/bin/bash
# Установка WARP и маршрутизации российского трафика для сервера Amnezia.
# Запуск (после установки Amnezia через приложение):  bash install.sh
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
DIR="$(cd "$(dirname "$0")" && pwd)"

[ "$(id -u)" -eq 0 ] || { echo "Запускать от root"; exit 1; }
for f in ru-warp.sh ru-warp.service ru-warp.timer; do
  [ -f "$DIR/$f" ] || { echo "Нет файла $f рядом с install.sh"; exit 1; }
done
# Защита от CRLF, если файлы прошли через Windows
sed -i 's/\r$//' "$DIR/ru-warp.sh" "$DIR/ru-warp.service" "$DIR/ru-warp.timer"

if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^amnezia-'; then
  echo "Контейнеры Amnezia не найдены. Сначала установите Amnezia через приложение."
  exit 1
fi

echo "[1/5] Пакеты"
apt-get update -qq
apt-get install -y -qq wireguard-tools ipset curl

echo "[2/5] wgcf"
if ! command -v wgcf >/dev/null; then
  URL=$(curl -fsSL https://api.github.com/repos/ViRb3/wgcf/releases/latest | grep -o 'https://[^"]*linux_amd64' | head -1 || true)
  [ -n "$URL" ] || { echo "Не удалось найти wgcf на GitHub"; exit 1; }
  curl -fsSL -o /usr/local/bin/wgcf "$URL"
  chmod +x /usr/local/bin/wgcf
fi

echo "[3/5] Аккаунт WARP и конфиг"
mkdir -p /etc/wireguard
cd /etc/wireguard
if [ ! -f warp.conf ]; then
  [ -f wgcf-account.toml ] || wgcf register --accept-tos
  wgcf generate
  cp wgcf-profile.conf warp.conf
  sed -i '/^DNS/d' warp.conf                                   # не трогаем DNS сервера
  sed -i 's/^MTU.*/MTU = 1280/' warp.conf
  sed -i '/^\[Interface\]/a Table = off' warp.conf             # сам трафик в WARP не идёт
  sed -i 's/^Endpoint.*/Endpoint = 162.159.192.1:2408/' warp.conf  # IPv4 стабильнее
  sed -i '/^Endpoint/a PersistentKeepalive = 25' warp.conf
  chmod 600 /etc/wireguard/*
fi
ip link show warp >/dev/null 2>&1 || wg-quick up warp

echo "      проверка выхода через WARP..."
ip route add 1.1.1.1 dev warp 2>/dev/null || true
TRACE=$(curl -s --max-time 15 https://1.1.1.1/cdn-cgi/trace || true)
ip route del 1.1.1.1 dev warp 2>/dev/null || true
echo "$TRACE" | grep -E '^(ip|warp)=' || true
if ! echo "$TRACE" | grep -q '^warp=on'; then
  echo "WARP не работает. Проверьте: wg show warp"
  exit 1
fi

echo "[4/5] Скрипт и автозапуск"
install -m 755 "$DIR/ru-warp.sh" /usr/local/sbin/ru-warp.sh
install -m 755 "$DIR/status.sh" /usr/local/sbin/ru-warp-status 2>/dev/null || true
install -m 644 "$DIR/ru-warp.service" /etc/systemd/system/ru-warp.service
install -m 644 "$DIR/ru-warp.timer" /etc/systemd/system/ru-warp.timer
systemctl daemon-reload
systemctl enable ru-warp.service ru-warp.timer >/dev/null
systemctl start ru-warp.timer

echo "[5/5] Применение правил"
/usr/local/sbin/ru-warp.sh

cat <<'EOT'

Готово.
Проверка с ПК (Amnezia подключена, раздельное туннелирование ВЫКЛ, NetBird выкл):
  yandex.ru/internet  -> IP Cloudflare (104.28.x.x)
  ifconfig.me         -> IP сервера
Состояние на сервере:  ru-warp-status
После этого: reboot и повторить проверку.
EOT
