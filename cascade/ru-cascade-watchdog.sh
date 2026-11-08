#!/bin/bash
# Сторож туннеля каскада: каждые 30 секунд проверяет, жив ли туннель "fi",
# и переключает таблицы маршрутов. Туннель считается живым, если последний
# handshake был меньше MAXAGE секунд назад (keepalive 25 с, rekey 2 мин).
TUN=fi
TABLE=200
DNS_TABLE=201
MAXAGE=180
FALLBACK=block
[ -f /etc/default/ru-cascade ] && . /etc/default/ru-cascade
STATE_FILE=/run/ru-cascade.state

GW=$(ip route show default table main | awk '/default/{print $3; exit}')
DEV=$(ip route show default table main | awk '/default/{print $5; exit}')

state=down
if ip link show $TUN >/dev/null 2>&1; then
  HS=$(awg show $TUN latest-handshakes 2>/dev/null | awk '{print $2}' | sort -n | tail -1)
  NOW=$(date +%s)
  if [ -n "$HS" ] && [ "$HS" -gt 0 ] && [ $((NOW - HS)) -lt $MAXAGE ]; then
    state=up
  fi
fi

[ -f "$STATE_FILE" ] && [ "$(cat "$STATE_FILE")" = "$state" ] && exit 0

ip route flush table $TABLE 2>/dev/null || true
ip route flush table $DNS_TABLE 2>/dev/null || true
if [ "$state" = up ]; then
  ip route add default dev $TUN table $TABLE
  ip route add blackhole default table $TABLE metric 1000
  ip route add default dev $TUN table $DNS_TABLE
  ip route add default via "$GW" dev "$DEV" table $DNS_TABLE metric 1000
else
  if [ "$FALLBACK" = "direct" ]; then
    ip route add default via "$GW" dev "$DEV" table $TABLE
  else
    ip route add blackhole default table $TABLE
  fi
  ip route add default via "$GW" dev "$DEV" table $DNS_TABLE
fi
ip route flush cache 2>/dev/null || true
echo "$state" > "$STATE_FILE"
logger -t ru-cascade "туннель $TUN: $state (FALLBACK=$FALLBACK)"
echo "туннель $TUN: $state"
