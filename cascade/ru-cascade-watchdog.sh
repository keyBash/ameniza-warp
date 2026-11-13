#!/bin/bash
# Сторож туннеля каскада, запускается каждые 30 секунд.
# 1) Туннель "fi" считается живым, если последний handshake был меньше MAXAGE секунд назад
#    (keepalive 25 с, rekey 2 мин). По живости туннеля переключаются таблицы маршрутов.
# 2) При каждом запуске проверяет, что правила (ip rule) и маршруты каскада на месте, и ставит
#    их заново, если их кто-то стёр (например, systemd-networkd при перезапуске после автообновления)
#    или они пропали вместе со старым интерфейсом fi после его перезапуска.
#    Без правил зарубежный трафик молча уходит напрямую с российского IP.
TUN=fi
MARK=0x77
TABLE=200
DNS_MARK=0x78
DNS_TABLE=201
MAXAGE=180
FALLBACK=block
[ -f /etc/default/ru-cascade ] && . /etc/default/ru-cascade
STATE_FILE=/run/ru-cascade.state

GW=$(ip route show default table main | awk '/default/{print $3; exit}')
DEV=$(ip route show default table main | awk '/default/{print $5; exit}')

# Правила: пакеты с метками каскада ищут маршрут в его таблицах
for R in "$MARK $TABLE 100" "$DNS_MARK $DNS_TABLE 101"; do
  set -- $R
  if ! ip rule show | grep -q "fwmark $1 "; then
    ip rule add fwmark "$1" table "$2" priority "$3"
    logger -t ru-cascade "правило fwmark $1 -> table $2 пропало, восстановлено"
  fi
done

state=down
if ip link show $TUN >/dev/null 2>&1; then
  HS=$(awg show $TUN latest-handshakes 2>/dev/null | awk '{print $2}' | sort -n | tail -1)
  NOW=$(date +%s)
  if [ -n "$HS" ] && [ "$HS" -gt 0 ] && [ $((NOW - HS)) -lt $MAXAGE ]; then
    state=up
  fi
fi

# Маршруты в таблицах соответствуют состоянию туннеля?
direct_ok() { [ -z "$GW" ] || grep -q "via $GW dev $DEV" <<<"$1"; }
routes_ok() {
  local fwd dns
  fwd=$(ip route show table $TABLE 2>/dev/null)
  dns=$(ip route show table $DNS_TABLE 2>/dev/null)
  direct_ok "$dns" || return 1
  if [ "$state" = up ]; then
    grep -q "dev $TUN" <<<"$fwd" && grep -q '^blackhole' <<<"$fwd" && grep -q "dev $TUN" <<<"$dns"
  elif [ "$FALLBACK" = "direct" ]; then
    direct_ok "$fwd"
  else
    grep -q '^blackhole' <<<"$fwd"
  fi
}

msg="туннель $TUN: $state"
if [ -f "$STATE_FILE" ] && [ "$(cat "$STATE_FILE")" = "$state" ]; then
  routes_ok && exit 0
  msg="$msg, маршруты пропали - восстановлены"
fi

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
logger -t ru-cascade "$msg (FALLBACK=$FALLBACK)"
echo "$msg"
