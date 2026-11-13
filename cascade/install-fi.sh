#!/bin/bash
# Установка зарубежного выходного узла: трафик клиентов уходит через Cloudflare WARP.
# Перед запуском на этом сервере установлена Amnezia (AmneziaWG) через приложение.
# Запуск:  bash install-fi.sh
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
DIR="$(cd "$(dirname "$0")" && pwd)"

[ "$(id -u)" -eq 0 ] || { echo "Запускать от root"; exit 1; }
docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^amnezia-awg' || { echo "Сначала установите Amnezia (AmneziaWG) через приложение"; exit 1; }
sed -i 's/\r$//' "$DIR"/fi-exit.sh "$DIR"/fi-exit.service "$DIR"/status-fi.sh "$DIR"/networkd-cascade.conf

echo "[1/4] Пакеты"
apt-get update -qq
apt-get install -y -qq wireguard-tools curl

echo "[2/4] WARP"
if ! command -v wgcf >/dev/null; then
  URL=$(curl -fsSL https://api.github.com/repos/ViRb3/wgcf/releases/latest | grep -o 'https://[^"]*linux_amd64' | head -1 || true)
  [ -n "$URL" ] || { echo "Не удалось найти wgcf на GitHub"; exit 1; }
  curl -fsSL -o /usr/local/bin/wgcf "$URL"
  chmod +x /usr/local/bin/wgcf
fi
mkdir -p /etc/wireguard
cd /etc/wireguard
if [ ! -f warp.conf ]; then
  [ -f wgcf-account.toml ] || wgcf register --accept-tos
  wgcf generate
  cp wgcf-profile.conf warp.conf
  sed -i '/^DNS/d' warp.conf
  sed -i 's/^MTU.*/MTU = 1280/' warp.conf
  sed -i '/^\[Interface\]/a Table = off' warp.conf
  sed -i 's/^Endpoint.*/Endpoint = 162.159.192.1:2408/' warp.conf
  sed -i '/^Endpoint/a PersistentKeepalive = 25' warp.conf
  chmod 600 /etc/wireguard/*
fi
ip link show warp >/dev/null 2>&1 || wg-quick up warp
sleep 2
ip route add 1.1.1.1 dev warp 2>/dev/null || true
TRACE=$(curl -s --max-time 15 https://1.1.1.1/cdn-cgi/trace || true)
ip route del 1.1.1.1 dev warp 2>/dev/null || true
echo "$TRACE" | grep -E '^(ip|warp)=' || true
echo "$TRACE" | grep -q '^warp=on' || { echo "WARP не работает. Проверьте: wg show warp"; exit 1; }

echo "[3/4] Скрипт и автозапуск"
install -m 755 "$DIR/fi-exit.sh" /usr/local/sbin/fi-exit.sh
install -m 755 "$DIR/status-fi.sh" /usr/local/sbin/fi-exit-status
install -m 644 "$DIR/fi-exit.service" /etc/systemd/system/fi-exit.service
# networkd не должен стирать правило WARP при своих перезапусках (иначе трафик уходит с IP сервера)
install -D -m 644 "$DIR/networkd-cascade.conf" /etc/systemd/networkd.conf.d/10-cascade.conf
systemctl try-restart systemd-networkd 2>/dev/null || true
systemctl daemon-reload
systemctl enable fi-exit.service >/dev/null

echo "[4/4] Применение правил"
/usr/local/sbin/fi-exit.sh

cat <<'EOT'

Готово. Проверка с ПК (Amnezia подключена к РОССИЙСКОМУ серверу):
  ifconfig.me         -> IP Cloudflare (104.28.x.x), а НЕ IP этого сервера
  yandex.ru/internet  -> IP российского сервера
  chatgpt.com, youtube.com открываются
Состояние на этом сервере:  fi-exit-status
EOT
