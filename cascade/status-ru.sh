#!/bin/bash
# Проверка российского входного узла. После install-ru.sh доступна как: ru-cascade-status

echo "== Туннель на зарубежный сервер (fi) =="
awg show fi 2>/dev/null | grep -E "endpoint|latest handshake|transfer" || echo "туннель не поднят: systemctl restart awg-quick@fi"

echo
echo "== Сторож =="
echo "состояние туннеля: $(cat /run/ru-cascade.state 2>/dev/null || echo неизвестно)"
journalctl -t ru-cascade -n 3 --no-pager 2>/dev/null | tail -3

echo
echo "== Выход через туннель (IP зарубежного сервера или Cloudflare) =="
if ip link show fi >/dev/null 2>&1; then
  ip route add 1.1.1.1 dev fi 2>/dev/null || true
  curl -s --max-time 10 https://1.1.1.1/cdn-cgi/trace | grep -E '^(ip|loc)=' || echo "нет ответа"
  ip route del 1.1.1.1 dev fi 2>/dev/null || true
fi

echo
echo "== Маршрутизация =="
ip rule show | grep -E "0x77|0x78" || echo "нет ip rule (запустите ru-cascade.sh)"
echo "-- зарубежный трафик (table 200):"; ip route show table 200
echo "-- DNS (table 201):"; ip route show table 201

echo
echo "== Счётчики RUCASC (CONNMARK set 0x77 > 0 = зарубежный трафик идёт в туннель) =="
iptables -t mangle -L RUCASC -v -n 2>/dev/null || echo "нет цепочки RUCASC"

echo
echo "== Список российских сетей =="
echo "$(ipset list ru 2>/dev/null | grep -c '/') сетей"
