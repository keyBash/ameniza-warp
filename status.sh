#!/bin/bash
# Быстрая проверка схемы Amnezia + WARP. После install.sh доступна как: ru-warp-status

echo "== WARP =="
wg show warp 2>/dev/null | grep -E "latest handshake|transfer" || echo "WARP не поднят (wg-quick up warp)"

echo
echo "== Выход через WARP =="
if ip link show warp >/dev/null 2>&1; then
  ip route add 1.1.1.1 dev warp 2>/dev/null || true
  curl -s --max-time 10 https://1.1.1.1/cdn-cgi/trace | grep -E '^(ip|warp)=' || echo "нет ответа"
  ip route del 1.1.1.1 dev warp 2>/dev/null || true
fi

echo
echo "== Маршрутизация =="
ip rule show | grep 0x66 || echo "нет ip rule (запустите ru-warp.sh)"
ip route show table 100

echo
echo "== Счётчики RUWARP (CONNMARK set 0x66 > 0 = работает) =="
iptables -t mangle -L RUWARP -v -n 2>/dev/null || echo "нет цепочки RUWARP"

echo
echo "== Список российских сетей =="
echo "$(ipset list ru 2>/dev/null | grep -c '/') сетей"

echo
echo "== Таймер обновления =="
systemctl list-timers ru-warp.timer --no-pager 2>/dev/null | head -2
