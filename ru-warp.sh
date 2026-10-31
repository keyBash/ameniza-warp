#!/bin/bash
# Российский трафик из контейнеров Amnezia -> через Cloudflare WARP.
# Если WARP упал -> такой трафик блокируется (blackhole), IP сервера не светится.
# Безопасно запускать повторно: правила пересоздаются, дубли не появляются.
set -e
MARK=0x66
TABLE=100

# Порты Amnezia определяются сами; если контейнеры ещё не запущены - значения по умолчанию
AWG_C=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -m1 '^amnezia-awg' || true)
XRAY_C=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -m1 '^amnezia-xray' || true)
AWG_PORT=$(docker port "$AWG_C" 2>/dev/null | head -1 | cut -d/ -f1 || true)
XRAY_PORT=$(docker port "$XRAY_C" 2>/dev/null | head -1 | cut -d/ -f1 || true)
[ -n "$AWG_PORT" ] || AWG_PORT=32651
[ -n "$XRAY_PORT" ] || XRAY_PORT=443

# 1. WARP
ip link show warp >/dev/null 2>&1 || wg-quick up warp
sysctl -qw net.ipv4.conf.all.rp_filter=2
sysctl -qw net.ipv4.conf.all.src_valid_mark=1

# 2. Список российских сетей (ipdeny.com, данные RIPE)
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

# 3. Отдельная таблица маршрутов: через WARP, а без него - в никуда
ip route replace default dev warp table $TABLE
ip route replace blackhole default table $TABLE metric 1000
ip rule show | grep -q "fwmark $MARK" || ip rule add fwmark $MARK table $TABLE priority 100

# 4. Метки: только НОВЫЕ исходящие соединения из контейнеров к российским IP.
#    Ответы клиентам (у них тоже российские IP) не трогаем.
iptables -t mangle -N RUWARP 2>/dev/null || iptables -t mangle -F RUWARP
iptables -t mangle -A RUWARP -p udp --sport "$AWG_PORT" -j RETURN
iptables -t mangle -A RUWARP -p tcp --sport "$XRAY_PORT" -j RETURN
iptables -t mangle -A RUWARP -p udp --sport "$XRAY_PORT" -j RETURN
iptables -t mangle -A RUWARP -m conntrack --ctstate NEW -m set --match-set ru dst -j CONNMARK --set-mark $MARK
iptables -t mangle -A RUWARP -j CONNMARK --restore-mark
for IF in docker0 br-+ amn+; do
  iptables -t mangle -C PREROUTING -i $IF -j RUWARP 2>/dev/null || iptables -t mangle -I PREROUTING -i $IF -j RUWARP
done

# 5. Подмена адреса на выходе в WARP и подгонка размера пакетов
iptables -t nat -C POSTROUTING -o warp -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o warp -j MASQUERADE
iptables -t mangle -C FORWARD -o warp -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
  || iptables -t mangle -A FORWARD -o warp -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

echo "ok: $(ipset list ru | grep -c '/') российских сетей, AWG_PORT=$AWG_PORT, XRAY_PORT=$XRAY_PORT"
