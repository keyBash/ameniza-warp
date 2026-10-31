# VPN-сервер: Amnezia + WARP для российского трафика

Ранбук на случай, если IP заблокируют и нужно поднять всё заново на новом адресе.

## Как устроена схема

```
Клиент (приложение Amnezia, весь трафик в туннель)
        │
        ▼
VPS за границей (AmneziaWG в Docker)
        │
        ├── зарубежные сайты ───────────────► выходят с IP сервера
        │
        └── российские IP (список ipdeny) ──► через Cloudflare WARP
                                               (если WARP упал → блок, без утечки)
```

- Друзьям ничего настраивать не нужно: только ключ Amnezia и кнопка «Подключиться».
- Российские сервисы видят IP Cloudflare (104.28.x.x), а не IP сервера. Поэтому они не могут «слить» адрес сервера в РКН.
- Минус: часть сервисов (Ozon, Wildberries, банки, Госуслуги) не пускает IP Cloudflare. Для них нужно выключать VPN или включать раздельное туннелирование на клиенте.

## Почему банили раньше

- Российские приложения (банки, маркетплейсы, Яндекс, VK, Max) видят IP, с которого к ним пришли, и, по данным СМИ, передают такие адреса РКН.
- Друзья ходили с глобальным туннелем, их телефоны в фоне стучались в российские сервисы с IP сервера, и адрес попадал в базу.
- Блокировки точечные, по отдельным IP: соседний адрес в той же подсети может быть открыт.

---

## Быстрый путь (скрипты из этого репозитория)

Файлы: `install.sh` (установка всего), `ru-warp.sh` (правила), `ru-warp.service` и `ru-warp.timer` (автозапуск), `status.sh` (проверка).

1. Найти рабочий IP и подготовить сервер (разделы 1–2 ниже).
2. Установить Amnezia через приложение (раздел 3).
3. С ПК закинуть папку репозитория на сервер:
   ```powershell
   scp -r ПУТЬ\К\ameniza-warp root@НОВЫЙ_IP:/root/
   ```
4. На сервере:
   ```bash
   bash /root/ameniza-warp/install.sh
   ```
   Скрипт сам поставит пакеты, зарегистрирует WARP, проверит его, установит правила и автозапуск.
5. Проверить с ПК (раздел 6) и на сервере командой `ru-warp-status`, затем `reboot` и проверить ещё раз.

Если bash ругается `$'\r': command not found`, файлы пришли с windows-переводами строк. Исправляется так: `sed -i 's/\r$//' /root/ameniza-warp/*`.

Ниже — то же самое вручную, по шагам.

---

## TODO при смене IP / сервера

### 1. Найти рабочий IP или локацию

- [ ] С **выключенными** Amnezia и NetBird (`netbird down`) проверить новый IP со своего ПК:
  ```powershell
  Test-NetConnection НОВЫЙ_IP -Port 22 -InformationLevel Quiet
  ```
  Нужно `True`. Проверяйте тот порт, на котором что-то реально слушает: на пустом сервере это 22, а не 443.
- [ ] Проверить на check-host.net (TCP, `IP:22`). Узлы `ru Moscow` должны быть `Connected`. Если один узел даёт таймаут, а другой Connected, решает проверка с вашего ПК.
- [ ] Если 3–5 адресов подряд в бане, проверить локации JustHost скриптом ниже и попросить перенос в открытую локацию.

**Скрипт проверки локаций JustHost** (PowerShell, VPN выключен):
```powershell
$codes = 'vie1','vie2','tia1','bru2','sof1','sof2','lon1','lon2','fra1','fra2','ath1','cph1','mum1','dub1','mad1','mad2','lin1','pmo1','yto1','hkg1','rix1','vno1','ams1','ams2','ams3','ams4','osl1','dxb1','waw1','waw2','opo1','otp2','atl1','atl2','atl3','dal1','qla1','qla2','nyc1','nyc2','sea1','chi1','sin1','sin2','ist1','kbp1','hel1','hel2','par1','par2','prg2','zrh1','zrh2','sto1','sto2','tyo2'
foreach ($c in $codes) {
  $h = "lg-$c.justhost.asia"
  try { $ip = ([Net.Dns]::GetHostAddresses($h) | ? AddressFamily -eq 'InterNetwork')[0] } catch { "{0,-5} нет имени" -f $c; continue }
  $t = New-Object Net.Sockets.TcpClient
  try { $ok = $t.ConnectAsync($ip, 443).Wait(3000) } catch { $ok = $false }
  $t.Close()
  "{0,-5} {1,-16} {2}" -f $c, $ip, $(if ($ok) {'OK'} else {'BLOCK'})
}
```
Предпочтительные локации (ближе к Москве): `hel1`/`hel2` (Хельсинки), `rix1` (Рига), `vno1` (Вильнюс), `sto1` (Стокгольм), `waw1`/`waw2` (Варшава). Результат — подсказка, а не гарантия.

**Шаблон письма в поддержку:**
> Все IP, которые выдаются при смене в текущей локации, заблокированы в РФ. Прошу перенести VPS в [локация, например HEL1] и выдать **новый, ранее не использованный** IP.

### 2. Подготовка чистого сервера

Как различать, где вы: `root@...:~#` — это сервер, `PS C:\Users\hoola>` — это ПК.

- [ ] Войти и сменить пароль root:
  ```bash
  ssh root@НОВЫЙ_IP
  passwd
  ```
- [ ] **На ПК** скопировать SSH-ключ на сервер. Ключ уже есть (`id_ed25519`, подпись `laptop`), заново **не** генерировать:
  ```powershell
  type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh root@НОВЫЙ_IP "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
  ```
- [ ] Проверить вход без пароля в новом окне: `ssh root@НОВЫЙ_IP`.
- [ ] Отключить вход по паролю (старую сессию не закрывать, пока не проверите вход в новом окне):
  ```bash
  sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
  grep -rl "PasswordAuthentication yes" /etc/ssh/sshd_config.d/ 2>/dev/null | xargs -r sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/'
  systemctl restart ssh
  ```
- [ ] Чтобы `needrestart` не вешал установку вопросами:
  ```bash
  sed -i "s/^#\?\$nrconf{restart} = .*/\$nrconf{restart} = 'a';/" /etc/needrestart/needrestart.conf
  ```
- [ ] Обновить систему **в фоне**, потому что SSH может оборваться:
  ```bash
  nohup sh -c 'DEBIAN_FRONTEND=noninteractive apt-get update && DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade' > /root/upgrade.log 2>&1 &
  tail -f /root/upgrade.log
  ```
  Выход из `tail` — Ctrl+C, обновление при этом продолжится. На одном ядре это занимает 20+ минут, CPU около 100%, и это нормально.
- [ ] Проверить, что обновление завершилось целиком:
  ```bash
  ps aux | grep -E "apt|dpkg|initramfs" | grep -v grep   # должно быть пусто
  dpkg --audit                                           # должно быть пусто
  apt list --upgradable 2>/dev/null | grep -c upgradable # 0
  ls -lh /boot/initrd.img*                               # файлы по десятки МБ
  lsinitramfs /boot/initrd.img-$(ls /boot/vmlinuz-* | sort -V | tail -1 | sed 's|/boot/vmlinuz-||') | wc -l  # тысячи
  ```
- [ ] `reboot`, через 1–2 минуты зайти снова и проверить `uname -r`.

### 3. Установка Amnezia

- [ ] Десктопное приложение AmneziaVPN → свой сервер:
  - IP: новый адрес, логин `root`;
  - вместо пароля вставить **приватный** ключ: `notepad $env:USERPROFILE\.ssh\id_ed25519` (файл **без** `.pub`, целиком, с BEGIN/END). Ошибка 300 означает, что вставлен не тот ключ или пароль;
  - тип установки: **ручной**, протокол **AmneziaWG** (Xray по желанию, см. раздел «Xray»).
- [ ] **Ключи друзьям пока не раздавать. Самому не подключаться в режиме «весь трафик», пока не готов WARP.**
- [ ] Проверить контейнеры и сетевой интерфейс:
  ```bash
  docker ps
  ip -br link | grep -vE "^(lo|eth0|warp)"   # у Amnezia интерфейс обычно amn0
  ```

### 4. WARP

- [ ] Инструменты и регистрация:
  ```bash
  apt install -y wireguard-tools ipset
  curl -fsSL https://api.github.com/repos/ViRb3/wgcf/releases/latest | grep -o 'https://[^"]*linux_amd64' | head -1 | xargs -I{} curl -fsSL -o /usr/local/bin/wgcf {}
  chmod +x /usr/local/bin/wgcf

  mkdir -p /etc/wireguard && cd /etc/wireguard
  wgcf register --accept-tos
  wgcf generate
  cp wgcf-profile.conf warp.conf
  sed -i '/^DNS/d' warp.conf
  sed -i 's/^MTU.*/MTU = 1280/' warp.conf
  sed -i '/^\[Interface\]/a Table = off' warp.conf
  sed -i 's/^Endpoint.*/Endpoint = 162.159.192.1:2408/' warp.conf
  sed -i '/^Endpoint/a PersistentKeepalive = 25' warp.conf
  chmod 600 /etc/wireguard/*
  wg-quick up warp
  ```
  `Table = off` — интерфейс поднят, но сам трафик в него не идёт. `DNS` удалён, чтобы не подменить DNS сервера. Endpoint по IPv4, потому что так стабильнее.
- [ ] Проверка, где ожидается `warp=on` и IP Cloudflare, а не IP сервера:
  ```bash
  ip route add 1.1.1.1 dev warp
  curl -s https://1.1.1.1/cdn-cgi/trace | grep -E "^ip=|^warp="
  ip route del 1.1.1.1 dev warp
  wg show warp   # должен быть latest handshake
  ```

### 5. Маршрутизация российского трафика через WARP

- [ ] Создать скрипт (вставлять блок **один раз** целиком):
  ```bash
  cat > /usr/local/sbin/ru-warp.sh <<'EOF'
  #!/bin/bash
  # Российский трафик из контейнеров Amnezia -> через WARP. Нет WARP -> блок, без утечки.
  set -e
  MARK=0x66
  TABLE=100

  # Порты Amnezia определяются сами; если контейнеры ещё не запущены, берутся значения по умолчанию
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

  # 3. Отдельная таблица маршрутов: через WARP, а без него в никуда
  ip route replace default dev warp table $TABLE
  ip route replace blackhole default table $TABLE metric 1000
  ip rule show | grep -q "fwmark $MARK" || ip rule add fwmark $MARK table $TABLE priority 100

  # 4. Метки: только новые исходящие соединения из контейнеров к российским IP
  iptables -t mangle -N RUWARP 2>/dev/null || iptables -t mangle -F RUWARP
  iptables -t mangle -A RUWARP -p udp --sport $AWG_PORT -j RETURN
  iptables -t mangle -A RUWARP -p tcp --sport $XRAY_PORT -j RETURN
  iptables -t mangle -A RUWARP -p udp --sport $XRAY_PORT -j RETURN
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
  EOF
  chmod +x /usr/local/sbin/ru-warp.sh
  /usr/local/sbin/ru-warp.sh
  ```
  Ожидается `ok: ~8000–10000 российских сетей` и правильный `AWG_PORT` (сверить с `docker ps`).

- [ ] Автозапуск и еженедельное обновление списка:
  ```bash
  cat > /etc/systemd/system/ru-warp.service <<'EOF'
  [Unit]
  Description=Route RU traffic from Amnezia via WARP
  After=docker.service network-online.target
  Wants=network-online.target

  [Service]
  Type=oneshot
  ExecStart=/usr/local/sbin/ru-warp.sh

  [Install]
  WantedBy=multi-user.target
  EOF

  cat > /etc/systemd/system/ru-warp.timer <<'EOF'
  [Unit]
  Description=Weekly refresh of RU list

  [Timer]
  OnCalendar=weekly
  Persistent=true

  [Install]
  WantedBy=timers.target
  EOF

  systemctl daemon-reload
  systemctl enable ru-warp.service ru-warp.timer
  systemctl start ru-warp.timer
  ```

### 6. Проверка

- [ ] На ПК: Amnezia (AmneziaWG) подключена, **раздельное туннелирование выключено**, NetBird выключен.
  - `yandex.ru/internet` должен показать IP Cloudflare (104.28.x.x);
  - `ifconfig.me` (через **f**) должен показать IP сервера.
- [ ] На сервере:
  ```bash
  iptables -t mangle -L RUWARP -v -n   # счётчики растут, у CONNMARK set 0x66 > 0
  wg show warp | grep transfer         # цифры растут при заходе на российские сайты
  ```
- [ ] `reboot` и повторить проверки: всё должно подняться само.
  ```bash
  uptime
  wg show warp | grep handshake
  iptables -t mangle -L RUWARP -v -n | head -3
  ```

### 7. Раздача

- [ ] Выдать друзьям ключи AmneziaWG.
- [ ] Сказать им одну фразу: «Если российский сайт пишет „выключите VPN“ (Ozon, банки), выключите на минуту».
- [ ] На своих устройствах включить обратно раздельное туннелирование со списком:
  https://github.com/w1zardz/amnezia-vpn-russia-split-tunneling
  (AmneziaVPN → Настройки → Раздельное туннелирование сайтов → «Адреса из списка не должны открываться через VPN» → импорт `amnezia-ru-direct.json`, на iPhone `amnezia-ru-direct-ip.json` → переподключиться). Тогда банки и Ozon видят домашний IP. Установщик-скрипт из репо не нужен, достаточно импорта JSON.

---

## Траблшутинг

| Симптом | Причина / что делать |
|---|---|
| `kex_exchange_identification: ... Connection timed out` | Сервер перегружен (обычно идёт обновление на одном ядре). Подождать, проверить через VNC-консоль хостера `top`. |
| SSH-сессия молча отвалилась посреди долгой команды | Долгие операции запускать через `nohup ... &` с логом в файл. |
| После обрыва висит `needrestart` | `pkill -f needrestart`, затем `dpkg --configure -a`. |
| Сломанное обновление | `dpkg --configure -a && apt upgrade -y`. Перед `reboot` обязательно проверить initramfs (раздел 2). |
| Ошибка 300 в Amnezia | Вставлен публичный ключ (`.pub`) или пароль. Нужен приватный `id_ed25519` целиком. |
| Счётчики `RUWARP` все по нулю | Неверное имя интерфейса Docker. `ip -br link`, добавить имя в цикл `for IF in ...` скрипта. |
| Российские сайты через VPN перестали открываться совсем | Упал WARP (это защита: без WARP трафик блокируется). `wg show warp`, затем `systemctl restart ru-warp`. Если не помогло: `wg-quick down warp; wg-quick up warp; /usr/local/sbin/ru-warp.sh`. |
| Ozon / банк пишет «выключите VPN» | Нормально: сервис не пускает IP Cloudflare. На своих устройствах раздельное туннелирование, друзьям выключать VPN. |
| Новый IP «в бане» сразу после выдачи | Хостер выдаёт засвеченные чужие адреса. Просить **новый, ранее не использованный** IP или другую локацию. |
| `docker logs` не работает | Amnezia отключает логи, это нормально. |

---

## Xray (опционально)

**Зачем он нужен:** от бана IP не спасает. Защищает от блокировки **протокола**: если AmneziaWG (UDP) режут, например на мобильном, а IP жив, Xray по TCP 443 выглядит как обычный HTTPS. Признак, что пора: «на мобильном не подключается, на Wi-Fi работает».

**Известная проблема:** по умолчанию Amnezia маскирует Xray под `www.googletagmanager.com`. Соединение устанавливается, но данных нет (на сервере видно много мелких пакетов `tcp spt:443` при малом объёме). Вероятно, ТСПУ ловит несовпадение «сайт Google ↔ IP не Google».

**Решение:** сменить сайт маскировки на «соседа» по IP.
```bash
cd /root
curl -fsSL https://api.github.com/repos/XTLS/RealiTLScanner/releases/latest | grep -o 'https://[^"]*linux-64[^"]*' | head -1 | xargs -I{} curl -fsSL -o RealiTLScanner {}
chmod +x RealiTLScanner
nohup ./RealiTLScanner -addr IP_СЕРВЕРА_С_0_В_КОНЦЕ/24 -port 443 -thread 20 -timeout 5 -out neighbors.csv > scan.log 2>&1 &
cat neighbors.csv
```
Выбрать домен, который: реальное имя сайта (не `*.xxx` и не служебное имя хостера), открывается из РФ без VPN, не Google и не Cloudflare. Менять сайт лучше через приложение Amnezia, в настройках протокола Xray, чтобы ключи клиентов обновились согласованно.

Правила WARP по IP действуют и на Xray. Дополнительно в Xray можно добавить блок или WARP по доменам (`.ru`, `geosite:category-ru`) для российских сервисов на зарубежных CDN.

---

## Варианты на будущее

- **Домен вместо IP в ключах**, чтобы при смене IP не перевыдавать ключи. DuckDNS из РФ заблокирован, не подходит. Нужен домен, который резолвится из России. Российских регистраторов для VPN-домена избегать.
- **Выход российского трафика через российский VPS** вместо WARP: Ozon и банки будут видеть российский IP. Заменить в скрипте `dev warp` на туннель к российскому серверу.
- **Жёсткий вариант (белый список):** друзьям только Xray, на сервере разрешены только нужные сервисы (соцсети, ИИ, YouTube), остальное в блок. Делается правилами Xray по пользователю (`email` у клиента).
- **Разделение серверов:** отдельный VPS для себя и для друзей, чтобы бан одного не задевал другого.

## Безопасность

- Приватный ключ `C:\Users\hoola\.ssh\id_ed25519` никому не отправлять. Он же даёт доступ к GitHub и GitLab.
- Вход на сервер только по ключу, пароль отключён.
- Если перед переустановкой ключ сервера изменился, на ПК очистить старую запись: `ssh-keygen -R НОВЫЙ_IP`.
