#!/bin/bash
# Проверка зарубежного выходного узла. После install-fi.sh доступна как: fi-exit-status

echo "== WARP =="
wg show warp 2>/dev/null | grep -E "latest handshake|transfer" || echo "WARP не поднят: wg-quick up warp && fi-exit.sh"

echo
echo "== Выход через WARP (должен быть IP Cloudflare) =="
if ip link show warp >/dev/null 2>&1; then
  ip route add 1.1.1.1 dev warp 2>/dev/null || true
  curl -s --max-time 10 https://1.1.1.1/cdn-cgi/trace | grep -E '^(ip|warp)=' || echo "нет ответа"
  ip route del 1.1.1.1 dev warp 2>/dev/null || true
fi

echo
echo "== Маршрутизация =="
ip rule show | grep 0x66 || echo "нет ip rule (запустите fi-exit.sh)"
ip route show table 100

echo
echo "== Счётчики FIEXIT (CONNMARK set 0x66 > 0 = трафик клиентов идёт в WARP) =="
iptables -t mangle -L FIEXIT -v -n 2>/dev/null || echo "нет цепочки FIEXIT"
