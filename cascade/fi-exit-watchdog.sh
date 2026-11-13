#!/bin/bash
# Сторож выходного узла каскада, запускается каждые 30 секунд.
# 1) Проверяет, что на месте всё, на чём держится выход через WARP: запрет утечки (FIEXITKS),
#    правило fwmark, интерфейс warp, маршруты таблицы 100, метки FIEXIT. Если чего-то нет
#    (стёр networkd, перезапустились WARP или Docker и т.п.) - заново применяет fi-exit.sh.
# 2) Если WARP перестал отвечать (handshake старше MAXAGE), перезапускает его,
#    но не чаще раза в RESTART_GAP секунд.
# Пока что-то сломано, трафик клиентов блокируется запретом утечки, а не уходит с IP сервера.
MARK=0x66
TABLE=100
MAXAGE=180
RESTART_GAP=300
STAMP=/run/fi-exit.warp-restart
FIEXIT_SH=/usr/local/sbin/fi-exit.sh

apply() {
  local out
  if out=$("$FIEXIT_SH" 2>&1); then
    logger -t fi-exit "$1 - восстановлено"
  else
    logger -t fi-exit "$1 - восстановить не вышло: $(tail -1 <<<"$out")"
  fi
}

# 1. Всё ли на месте
broken=""
ks=ok
iptables -C FIEXITKS -j DROP 2>/dev/null || ks=broken
for IF in docker0 br-+ amn+; do
  iptables -C DOCKER-USER -i $IF -j FIEXITKS 2>/dev/null || ks=broken
done
[ $ks = ok ] || broken="$broken запрет-утечки"
ip rule show | grep -q "fwmark $MARK " || broken="$broken ip-rule"
if ip link show warp >/dev/null 2>&1; then
  T=$(ip route show table $TABLE 2>/dev/null)
  { grep -q "dev warp" <<<"$T" && grep -q '^blackhole' <<<"$T"; } || broken="$broken маршруты"
else
  broken="$broken интерфейс-warp"
fi
for IF in docker0 br-+ amn+; do
  iptables -t mangle -C PREROUTING -i $IF -j FIEXIT 2>/dev/null || { broken="$broken метки"; break; }
done
[ -z "$broken" ] || apply "пропало:$broken"

# 2. WARP не отвечает -> перезапуск
HS=$(wg show warp latest-handshakes 2>/dev/null | awk '{print $2}' | sort -n | tail -1)
NOW=$(date +%s)
if [ -n "$HS" ] && [ $((NOW - HS)) -ge $MAXAGE ]; then
  LAST=$(cat "$STAMP" 2>/dev/null || echo 0)
  if [ $((NOW - LAST)) -ge $RESTART_GAP ]; then
    echo "$NOW" > "$STAMP"
    if [ "$HS" -gt 0 ]; then AGE="$((NOW - HS)) с назад"; else AGE="не было"; fi
    wg-quick down warp >/dev/null 2>&1 || true
    wg-quick up warp >/dev/null 2>&1 || true
    apply "WARP не отвечает (handshake: $AGE), перезапуск"   # маршрут dev warp пропал вместе со старым интерфейсом
  fi
fi
exit 0
