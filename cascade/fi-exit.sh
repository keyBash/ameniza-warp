#!/bin/bash
# Зарубежный выходной узел каскада.
# Весь трафик клиентов (пришедший из туннеля от российского сервера) выходит в интернет
# через Cloudflare WARP, а НЕ с IP этого сервера. IP сервера знает только российский узел.
# Если WARP недоступен -> трафик отбрасывается (blackhole), с IP сервера наружу ничего не уходит.
# Запрет утечки (цепочка FIEXITKS) работает отдельно от маршрутов: даже если правило или маршруты
# стёрты, трафик клиентов может уйти только в WARP, иначе отбрасывается.
# Безопасно запускать повторно.
#   fi-exit.sh             - всё
#   fi-exit.sh killswitch  - только запрет утечки (ставится при загрузке до запуска Docker)
set -e
MARK=0x66
TABLE=100
LOCAL=10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10,127.0.0.0/8,169.254.0.0/16

# 0. Запрет утечки: пересылаемый трафик из контейнеров наружу - только в WARP.
#    Исключения: ответы на входящие соединения (сам туннель от российского сервера приходит
#    через проброс порта Docker, то есть DNAT) и локальные адреса (между контейнерами).
#    DOCKER-USER Docker проверяет раньше своих правил и не очищает.
iptables -N DOCKER-USER 2>/dev/null || true
iptables -N FIEXITKS 2>/dev/null || iptables -F FIEXITKS
iptables -A FIEXITKS -o warp -j RETURN
iptables -A FIEXITKS -m conntrack --ctstate DNAT -j RETURN
iptables -A FIEXITKS -d $LOCAL -j RETURN
iptables -A FIEXITKS -j DROP
for IF in docker0 br-+ amn+; do
  iptables -C DOCKER-USER -i $IF -j FIEXITKS 2>/dev/null || iptables -I DOCKER-USER -i $IF -j FIEXITKS
done
[ "${1:-}" = killswitch ] && { echo "ok: запрет утечки установлен"; exit 0; }

AWG_C=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -m1 '^amnezia-awg' || true)
AWG_PORT=$(docker port "$AWG_C" 2>/dev/null | head -1 | cut -d/ -f1 || true)
[ -n "$AWG_PORT" ] || { echo "Контейнер AmneziaWG не найден"; exit 1; }

# 1. WARP
ip link show warp >/dev/null 2>&1 || wg-quick up warp
sysctl -qw net.ipv4.conf.all.rp_filter=2
sysctl -qw net.ipv4.conf.all.src_valid_mark=1

# 2. Таблица маршрутов: через WARP, без него - в никуда
ip route replace default dev warp table $TABLE
ip route replace blackhole default table $TABLE metric 1000
ip rule show | grep -q "fwmark $MARK " || ip rule add fwmark $MARK table $TABLE priority 100

# 3. Метки: все новые соединения клиентов из контейнера Amnezia, кроме ответов в туннель и локальных адресов
iptables -t mangle -N FIEXIT 2>/dev/null || iptables -t mangle -F FIEXIT
iptables -t mangle -A FIEXIT -p udp --sport "$AWG_PORT" -j RETURN
iptables -t mangle -A FIEXIT -d $LOCAL -j RETURN
iptables -t mangle -A FIEXIT -m conntrack --ctstate NEW -j CONNMARK --set-mark $MARK
iptables -t mangle -A FIEXIT -j CONNMARK --restore-mark
for IF in docker0 br-+ amn+; do
  iptables -t mangle -C PREROUTING -i $IF -j FIEXIT 2>/dev/null || iptables -t mangle -I PREROUTING -i $IF -j FIEXIT
done

# 4. Подмена адреса на выходе в WARP и подгонка размера пакетов
iptables -t nat -C POSTROUTING -o warp -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o warp -j MASQUERADE
iptables -t mangle -C FORWARD -o warp -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
  || iptables -t mangle -A FORWARD -o warp -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

echo "ok: весь трафик клиентов -> WARP, AWG_PORT=$AWG_PORT"
