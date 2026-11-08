#!/bin/bash
# Российский входной узел каскада.
# Трафик клиентов Amnezia:
#   - к российским IP      -> напрямую с этого сервера (eth0)
#   - DNS-запросы          -> через туннель, а если он мёртв - напрямую
#   - ко всему остальному  -> через туннель AmneziaWG "fi" на зарубежный сервер
# Живость туннеля проверяет сторож (ru-cascade-watchdog.sh) каждые 30 секунд.
# Если туннель мёртв: FALLBACK=block -> зарубежное не открывается (по умолчанию)
#                     FALLBACK=direct -> зарубежное идёт напрямую с российского IP
# Безопасно запускать повторно.
set -e
TUN=fi
MARK=0x77
TABLE=200
DNS_MARK=0x78
DNS_TABLE=201
FALLBACK="${FALLBACK:-block}"
[ -f /etc/default/ru-cascade ] && . /etc/default/ru-cascade

# Порт AmneziaWG этого сервера (ответы клиентам не трогаем)
AWG_C=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -m1 '^amnezia-awg' || true)
AWG_PORT=$(docker port "$AWG_C" 2>/dev/null | head -1 | cut -d/ -f1 || true)
[ -n "$AWG_PORT" ] || { echo "Контейнер AmneziaWG не найден: установите Amnezia через приложение"; exit 1; }

# 1. Туннель на зарубежный сервер
ip link show $TUN >/dev/null 2>&1 || systemctl start awg-quick@$TUN
sysctl -qw net.ipv4.conf.all.rp_filter=2
sysctl -qw net.ipv4.conf.all.src_valid_mark=1

# 2. Список российских сетей
ipset create ru hash:net -exist
TMP=$(mktemp)
if curl -fsS --max-time 60 https://www.ipdeny.com/ipblocks/data/aggregated/ru-aggregated.zone -o "$TMP" \
   && [ "$(wc -l < "$TMP")" -gt 1000 ]; then
  ipset flush ru
  sed 's/^/add ru /' "$TMP" | ipset restore -exist
else
  echo "Список не скачался, оставляю старый"
fi
rm -f "$TMP"
[ "$(ipset list ru | grep -c '/')" -gt 1000 ] || { echo "Список российских сетей пуст - выхожу, чтобы не отправить всё в туннель"; exit 1; }

# 3. Таблицы маршрутов (их содержимое выставляет сторож по живости туннеля):
#    $TABLE   - зарубежный трафик: туннель жив -> туннель, туннель мёртв -> блок (или напрямую)
#    $DNS_TABLE - DNS-запросы к зарубежным резолверам: туннель жив -> туннель, мёртв -> напрямую,
#               чтобы российские сайты открывались, даже если зарубежный сервер недоступен
ip rule show | grep -q "fwmark $MARK " || ip rule add fwmark $MARK table $TABLE priority 100
ip rule show | grep -q "fwmark $DNS_MARK " || ip rule add fwmark $DNS_MARK table $DNS_TABLE priority 101
rm -f /run/ru-cascade.state
/usr/local/sbin/ru-cascade-watchdog.sh

# 4. Метки новых соединений из контейнеров Amnezia:
#    DNS к не российским адресам -> $DNS_MARK; прочее к не российским и не локальным -> $MARK
iptables -t mangle -N RUCASC 2>/dev/null || iptables -t mangle -F RUCASC
iptables -t mangle -A RUCASC -p udp --sport "$AWG_PORT" -j RETURN
iptables -t mangle -A RUCASC -d 10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10,127.0.0.0/8,169.254.0.0/16 -j RETURN
for P in udp tcp; do
  iptables -t mangle -A RUCASC -p $P --dport 53 -m conntrack --ctstate NEW -m set ! --match-set ru dst -j CONNMARK --set-mark $DNS_MARK
done
iptables -t mangle -A RUCASC -m conntrack --ctstate NEW -m connmark --mark 0 -m set ! --match-set ru dst -j CONNMARK --set-mark $MARK
iptables -t mangle -A RUCASC -j CONNMARK --restore-mark
for IF in docker0 br-+ amn+; do
  iptables -t mangle -C PREROUTING -i $IF -j RUCASC 2>/dev/null || iptables -t mangle -I PREROUTING -i $IF -j RUCASC
done

# 5. Подмена адреса на выходе в туннель и подгонка размера пакетов
iptables -t nat -C POSTROUTING -o $TUN -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o $TUN -j MASQUERADE
iptables -t mangle -C FORWARD -o $TUN -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
  || iptables -t mangle -A FORWARD -o $TUN -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

echo "ok: $(ipset list ru | grep -c '/') российских сетей, AWG_PORT=$AWG_PORT, FALLBACK=$FALLBACK"
