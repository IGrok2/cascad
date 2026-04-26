#!/bin/bash

# ─────────────────────────────────────────────
#  CASCADE — port-emulation iptables forwarder
#  usage: bash main.sh
# ─────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

banner() {
  echo -e "${CYAN}${BOLD}"
  echo "  ██████╗ █████╗ ███████╗ ██████╗ █████╗ ██████╗ "
  echo " ██╔════╝██╔══██╗██╔════╝██╔════╝██╔══██╗██╔══██╗"
  echo " ██║     ███████║███████╗██║     ███████║██║  ██║"
  echo " ██║     ██╔══██║╚════██║██║     ██╔══██║██║  ██║"
  echo " ╚██████╗██║  ██║███████║╚██████╗██║  ██║██████╔╝"
  echo "  ╚═════╝╚═╝  ╚═╝╚══════╝ ╚═════╝╚═╝  ╚═╝╚═════╝ "
  echo -e "${RESET}"
}

banner

# ── deps ──────────────────────────────────────
if ! command -v iptables &>/dev/null; then
  echo -e "${YELLOW}Устанавливаю iptables...${RESET}"
  apt-get update -qq && apt-get install -y iptables
fi
IPT=$(which iptables)
IPT_RESTORE=$(which iptables-restore)
IPT_SAVE=$(which iptables-save)

# ── input ─────────────────────────────────────
echo ""
read -p "$(echo -e ${BOLD}EU IP сервера${RESET} [куда форвардить]: )" NL_SERVER

if [[ ! $NL_SERVER =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo -e "${RED}Невалидный IP${RESET}"; exit 1
fi

IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
echo -e "Интерфейс: ${CYAN}$IFACE${RESET}"

# ── port emulation config ──────────────────────
echo ""
echo -e "${BOLD}═══ Port Emulation (маппинг портов) ═══${RESET}"
echo -e "Трафик на локальный порт → форвардится на EU сервер на ДРУГОЙ порт"
echo -e "Пример: RU провайдер видит 443, EU сервер получает на 9443 (VPN)"
echo ""

# Default port map: local:remote
declare -A PORT_MAP
PORT_MAP[443]=9443      # HTTPS → VPN port
PORT_MAP[80]=8080       # HTTP → кастомный
# Можно добавить ещё в интерактивном режиме

echo -e "Дефолтные маппинги:"
for lport in "${!PORT_MAP[@]}"; do
  echo -e "  ${CYAN}:${lport}${RESET} → EU:${GREEN}${PORT_MAP[$lport]}${RESET}"
done
echo ""

read -p "Добавить свои маппинги? (y/n): " ADD_MAPS
if [[ "$ADD_MAPS" == "y" ]]; then
  echo "Формат: LOCAL_PORT:REMOTE_PORT (пустая строка — стоп)"
  while true; do
    read -p "  маппинг: " entry
    [[ -z "$entry" ]] && break
    lp=$(echo "$entry" | cut -d: -f1)
    rp=$(echo "$entry" | cut -d: -f2)
    if [[ "$lp" =~ ^[0-9]+$ && "$rp" =~ ^[0-9]+$ ]]; then
      PORT_MAP[$lp]=$rp
      echo -e "  ${GREEN}добавлено: $lp → $rp${RESET}"
    else
      echo -e "  ${RED}неверный формат${RESET}"
    fi
  done
fi

# Порты, которые НЕ трогаем (остаются на этом сервере)
LOCAL_PORTS="22"
read -p "Локальные порты через запятую (не форвардить) [default: 22]: " user_local
[[ -n "$user_local" ]] && LOCAL_PORTS="$user_local"

# ── apply rules ────────────────────────────────
echo ""
echo -e "${YELLOW}Применяю правила...${RESET}"

# ip_forward
echo 1 > /proc/sys/net/ipv4/ip_forward
sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p -q

# flush
$IPT -F
$IPT -t nat -F
$IPT -t mangle -F
$IPT -X

# policies
$IPT -P INPUT DROP
$IPT -P FORWARD DROP
$IPT -P OUTPUT ACCEPT

# base INPUT
$IPT -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
$IPT -A INPUT -i lo -j ACCEPT
$IPT -A INPUT -p icmp -j ACCEPT

# allow local ports on this server
IFS=',' read -ra LP_ARR <<< "$LOCAL_PORTS"
for lp in "${LP_ARR[@]}"; do
  lp=$(echo "$lp" | tr -d ' ')
  $IPT -A INPUT -p tcp --dport "$lp" -j ACCEPT
  echo -e "  INPUT allow: ${CYAN}$lp${RESET}"
done

# ── port emulation DNAT rules ──────────────────
echo ""
echo -e "${BOLD}Port emulation DNAT:${RESET}"
for lport in "${!PORT_MAP[@]}"; do
  rport=${PORT_MAP[$lport]}
  $IPT -t nat -A PREROUTING -i $IFACE -p tcp --dport "$lport" \
    -j DNAT --to-destination "$NL_SERVER:$rport"
  $IPT -A FORWARD -d $NL_SERVER -p tcp --dport "$rport" -j ACCEPT
  echo -e "  TCP :${CYAN}${lport}${RESET} → ${NL_SERVER}:${GREEN}${rport}${RESET}"
done

# ── forward all other TCP/UDP (кроме локальных) ──
# собираем список исключений (local ports + mapped local ports)
ALL_LOCAL=$(printf "%s," "${LP_ARR[@]}")
for lp in "${!PORT_MAP[@]}"; do
  ALL_LOCAL="${ALL_LOCAL}${lp},"
done
ALL_LOCAL=${ALL_LOCAL%,}  # trim trailing comma

# Форвардим оставшийся TCP (без маппинга и локальных)
$IPT -t nat -A PREROUTING -i $IFACE -p tcp \
  -m multiport ! --dports "$ALL_LOCAL" \
  -j DNAT --to-destination "$NL_SERVER"

# UDP форвард всего
$IPT -t nat -A PREROUTING -i $IFACE -p udp \
  -j DNAT --to-destination "$NL_SERVER"

$IPT -t nat -A POSTROUTING -j MASQUERADE
$IPT -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
$IPT -A FORWARD -d $NL_SERVER -j ACCEPT

# ── persist ────────────────────────────────────
$IPT_SAVE > /etc/cascade-rules.v4

# Сохраняем конфиг для cascade CTL
mkdir -p /etc/cascade
cat > /etc/cascade/config << CONF
NL_SERVER="$NL_SERVER"
IFACE="$IFACE"
LOCAL_PORTS="$LOCAL_PORTS"
CONF

# Сохраняем маппинги
: > /etc/cascade/portmap
for lp in "${!PORT_MAP[@]}"; do
  echo "$lp:${PORT_MAP[$lp]}" >> /etc/cascade/portmap
done

# ── systemd service ─────────────────────────────
cat > /etc/systemd/system/cascade.service << EOF
[Unit]
Description=Cascade iptables port emulator
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'echo 1 > /proc/sys/net/ipv4/ip_forward && $IPT_RESTORE < /etc/cascade-rules.v4'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable cascade.service

# ── cascade CTL ────────────────────────────────
cat > /usr/local/bin/cascade << 'CTLEOF'
#!/bin/bash

# ─────────────────────────────────────────
#  cascade — управление port-emulation
# ─────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; BOLD='\033[1m'
DIM='\033[2m'; RESET='\033[0m'
BLUE='\033[0;34m'; WHITE='\033[1;37m'

source /etc/cascade/config 2>/dev/null || { echo "cascade не установлен"; exit 1; }

_banner() {
  clear
  echo -e "${CYAN}${BOLD}"
  echo " ██████╗ █████╗ ███████╗ ██████╗ █████╗ ██████╗ "
  echo "██╔════╝██╔══██╗██╔════╝██╔════╝██╔══██╗██╔══██╗"
  echo "██║     ███████║███████╗██║     ███████║██║  ██║"
  echo "██║     ██╔══██║╚════██║██║     ██╔══██║██║  ██║"
  echo "╚██████╗██║  ██║███████║╚██████╗██║  ██║██████╔╝"
  echo " ╚═════╝╚═╝  ╚═╝╚══════╝ ╚═════╝╚═╝  ╚═╝╚═════╝"
  echo -e "${RESET}"
}

_line() { echo -e "${DIM}────────────────────────────────────────────────────${RESET}"; }
_dline() { echo -e "${DIM}════════════════════════════════════════════════════${RESET}"; }

_is_active() {
  iptables -t nat -L PREROUTING -n 2>/dev/null | grep -q "$NL_SERVER"
}

_status_chip() {
  if _is_active; then
    echo -e " ${GREEN}${BOLD}● АКТИВЕН${RESET}  →  ${CYAN}$NL_SERVER${RESET}  [${DIM}$IFACE${RESET}]"
  else
    echo -e " ${RED}${BOLD}○ ОТКЛЮЧЁН${RESET}"
  fi
}

_portmap_list() {
  if [[ ! -s /etc/cascade/portmap ]]; then
    echo -e "  ${DIM}(нет маппингов)${RESET}"
    return
  fi
  while IFS=: read -r lp rp; do
    printf "  ${CYAN}:%-6s${RESET}  ──▸  ${GREEN}%s:%-6s${RESET}\n" "$lp" "$NL_SERVER" "$rp"
  done < /etc/cascade/portmap
}

# ── СТАТУС ─────────────────────────────────────────────────
_status() {
  _banner
  _status_chip
  _line

  # uptime cascade.service
  local uptime_str=""
  if systemctl is-active cascade.service &>/dev/null; then
    uptime_str=$(systemctl show cascade.service --property=ActiveEnterTimestamp | cut -d= -f2)
    echo -e " ${DIM}сервис:${RESET} ${GREEN}запущен${RESET}  (с ${uptime_str})"
  else
    echo -e " ${DIM}сервис:${RESET} ${RED}остановлен${RESET}"
  fi

  # правила iptables
  local rules
  rules=$(iptables -t nat -L PREROUTING -n 2>/dev/null | grep -c "$NL_SERVER" || echo 0)
  echo -e " ${DIM}nat правил:${RESET} ${WHITE}$rules${RESET}"

  # активные соединения
  local conns=0
  if command -v conntrack &>/dev/null; then
    conns=$(conntrack -L --dst "$NL_SERVER" 2>/dev/null | wc -l)
  fi
  echo -e " ${DIM}активных сессий:${RESET} ${WHITE}$conns${RESET}"

  _line
  echo -e " ${BOLD}Port emulation:${RESET}"
  _portmap_list
  _line

  # статистика пакетов по маппингам
  echo -e " ${BOLD}Пакеты (FORWARD):${RESET}"
  iptables -L FORWARD -n -v 2>/dev/null | awk 'NR>2 && $1+0>0 {
    pkts=$1; bytes=$2;
    if (bytes >= 1073741824) b=sprintf("%.1f GB", bytes/1073741824)
    else if (bytes >= 1048576) b=sprintf("%.1f MB", bytes/1048576)
    else if (bytes >= 1024) b=sprintf("%.1f KB", bytes/1024)
    else b=bytes" B"
    printf "  pkts=%-8s  bytes=%-10s  %s\n", pkts, b, $0
  }' | head -8

  echo ""
}

# ── LIVE ТРАФИК (tcpdump) ────────────────────────────────────
_live_traffic() {
  if ! command -v tcpdump &>/dev/null; then
    echo -e "${YELLOW}Устанавливаю tcpdump...${RESET}"
    apt-get install -y tcpdump -qq 2>/dev/null
  fi

  # спрашиваем фильтр
  _banner
  echo -e " ${GREEN}${BOLD}▸ LIVE ТРАФИК${RESET}  ${DIM}(Ctrl+C для выхода)${RESET}"
  _line
  echo -e "  Фильтр по порту (Enter = все):"
  echo -e "  ${DIM}Примеры: 443  /  80  /  9443  /  all${RESET}"
  read -p "  порт: " port_filter

  local tcpdump_filter="host $NL_SERVER"
  local filter_label="→ $NL_SERVER"
  if [[ -n "$port_filter" && "$port_filter" != "all" ]]; then
    tcpdump_filter="host $NL_SERVER and port $port_filter"
    filter_label="→ $NL_SERVER :$port_filter"
  fi

  clear
  _banner
  echo -e " ${GREEN}${BOLD}▸ LIVE ТРАФИК${RESET}  ${DIM}(Ctrl+C → выход)${RESET}"
  echo -e " Фильтр: ${CYAN}$filter_label${RESET}  |  iface: ${DIM}$IFACE${RESET}"
  _line
  printf "  ${BOLD}%-8s  %-21s  %-21s  %-5s  %-5s  %-7s  %s${RESET}\n" \
    "ВРЕМЯ" "ИСТОЧНИК" "НАЗНАЧЕНИЕ" "SPORT" "DPORT" "PROTO" "ФЛАГИ"
  _line

  # tcpdump → построчный парсинг
  tcpdump -i "$IFACE" -n -l -q "$tcpdump_filter" 2>/dev/null | while read -r line; do
    local now src dst proto flags color flag_str

    now=$(date '+%H:%M:%S')

    # TCP строки: "IP src.sport > dst.dport: Flags [SFA], ..."
    if echo "$line" | grep -qP '^\d+\.\d+ IP '; then
      proto="TCP"
      color=$CYAN

      src_full=$(echo "$line" | grep -oP 'IP \K[\d.]+\.\d+(?= >)')
      dst_full=$(echo "$line" | grep -oP '> \K[\d.]+\.\d+(?=:)')

      src_ip=$(echo "$src_full" | grep -oP '^[\d.]+(?=\.\d+$)')
      sport=$(echo "$src_full" | grep -oP '\d+$')
      dst_ip=$(echo "$dst_full" | grep -oP '^[\d.]+(?=\.\d+$)')
      dport=$(echo "$dst_full" | grep -oP '\d+$')

      # флаги TCP
      raw_flags=$(echo "$line" | grep -oP 'Flags \[\K[^\]]+' | head -1)
      flag_str=""
      [[ "$raw_flags" == *"S"* && "$raw_flags" != *"."* ]] && flag_str="${GREEN}SYN${RESET}"
      [[ "$raw_flags" == *"S"* && "$raw_flags" == *"."* ]]  && flag_str="${CYAN}SYN-ACK${RESET}"
      [[ "$raw_flags" == *"F"* ]] && flag_str="${YELLOW}FIN${RESET}"
      [[ "$raw_flags" == *"R"* ]] && flag_str="${RED}RST${RESET}"
      [[ "$raw_flags" == *"P"* && -z "$flag_str" ]] && flag_str="${DIM}PSH${RESET}"
      [[ "$raw_flags" == "."  ]] && flag_str="${DIM}ACK${RESET}"
      [[ -z "$flag_str" ]] && flag_str="${DIM}${raw_flags}${RESET}"

    # UDP строки: "IP src.sport > dst.dport: UDP, ..."
    elif echo "$line" | grep -qP 'UDP'; then
      proto="UDP"
      color=$MAGENTA
      src_full=$(echo "$line" | grep -oP 'IP \K[\d.]+\.\d+(?= >)')
      dst_full=$(echo "$line" | grep -oP '> \K[\d.]+\.\d+(?=:)')
      src_ip=$(echo "$src_full" | grep -oP '^[\d.]+(?=\.\d+$)')
      sport=$(echo "$src_full" | grep -oP '\d+$')
      dst_ip=$(echo "$dst_full" | grep -oP '^[\d.]+(?=\.\d+$)')
      dport=$(echo "$dst_full" | grep -oP '\d+$')
      flag_str="${DIM}datagram${RESET}"
    else
      continue
    fi

    [[ -z "$src_ip" || -z "$dst_ip" ]] && continue

    # подсвечиваем mapped порты
    local dport_str
    if grep -q ":${dport}$" /etc/cascade/portmap 2>/dev/null; then
      dport_str="${GREEN}${dport}*${RESET}"
    else
      dport_str="${CYAN}${dport}${RESET}"
    fi

    printf "  %-8s  %-21s  %-21s  ${DIM}%-5s${RESET}  %-5b  ${color}%-7s${RESET}  %b\n" \
      "$now" "$src_ip" "$dst_ip" "$sport" "$dport_str" "$proto" "$flag_str"
  done
}

# ── WATCH СЕССИИ (ss + iptables) ───────────────────────────
_watch_sessions() {
  while true; do
    _banner
    echo -e " ${BOLD}▸ АКТИВНЫЕ СЕССИИ${RESET}  ${DIM}(обновление 2с, Ctrl+C выход)${RESET}"
    echo -e " Таргет: ${CYAN}$NL_SERVER${RESET}  |  $(date '+%H:%M:%S')"
    _line
    printf "  ${BOLD}%-5s  %-22s  %-22s  %-12s  %s${RESET}\n" \
      "PROTO" "ИСТОЧНИК" "НАЗНАЧЕНИЕ" "СОСТОЯНИЕ" "INFO"
    _line

    local ss_count=0
    while read -r line; do
      proto=$(echo "$line" | awk '{print $1}' | tr '[:lower:]' '[:upper:]')
      state=$(echo "$line" | awk '{print $2}')
      src=$(echo "$line" | awk '{print $4}')
      dst=$(echo "$line" | awk '{print $5}')
      case "$proto" in
        TCP) pc=$CYAN ;;
        UDP) pc=$MAGENTA ;;
        *)   pc=$DIM ;;
      esac
      case "$state" in
        ESTAB*)    sc="${GREEN}ESTABLISHED${RESET}" ;;
        TIME-WAIT) sc="${YELLOW}TIME-WAIT${RESET}" ;;
        CLOSE*)    sc="${RED}${state}${RESET}" ;;
        *)         sc="${DIM}${state}${RESET}" ;;
      esac
      dport=$(echo "$dst" | grep -oP ':\K\d+$')
      mapped=""
      grep -q ":${dport}$" /etc/cascade/portmap 2>/dev/null && mapped="${GREEN}[mapped]${RESET}"
      printf "  ${pc}%-5s${RESET}  %-22s  %-22s  %-12b  %b\n" \
        "$proto" "$src" "$dst" "$sc" "$mapped"
      ss_count=$((ss_count+1))
    done < <(ss -tnup 2>/dev/null | grep "$NL_SERVER" | head -30)

    if [[ "$ss_count" -eq 0 ]]; then
      echo -e "  ${DIM}(нет сессий через ss — трафик идёт как FORWARD через NAT)${RESET}"
      echo ""
      echo -e "  ${BOLD}Счётчики FORWARD правил:${RESET}"
      iptables -L FORWARD -n -v 2>/dev/null | awk 'NR>2 && $1+0>0 {
        if ($2+0>=1048576) b=sprintf("%.2f MB",$2/1048576)
        else if ($2+0>=1024) b=sprintf("%.1f KB",$2/1024)
        else b=$2" B"
        printf "    pkts=\033[1;37m%-8s\033[0m  bytes=\033[0;36m%s\033[0m\n", $1, b
      }'
    fi

    _line
    echo -e "  Активных: ${WHITE}$ss_count${RESET}  ${DIM}| [2] live трафик для полной картины${RESET}"
    sleep 2
  done
}

# ── WATCH STATS ────────────────────────────────────────────
_watch_stats() {
  while true; do
    _banner
    echo -e " ${BOLD}▸ СТАТИСТИКА ПАКЕТОВ${RESET}  ${DIM}(Ctrl+C выход)${RESET}  $(date '+%H:%M:%S')"
    _line

    echo -e " ${BOLD}NAT PREROUTING:${RESET}"
    iptables -t nat -L PREROUTING -n -v 2>/dev/null | awk 'NR>2 {
      pkts=$1; bytes=$2;
      if (bytes+0 >= 1048576) b=sprintf("%.2f MB", bytes/1048576)
      else if (bytes+0 >= 1024) b=sprintf("%.1f KB", bytes/1024)
      else b=bytes" B"
      sub(/.*DNAT.*to:/,"→ ")
      printf "  pkts=\033[1;37m%-8s\033[0m  bytes=\033[0;36m%-12s\033[0m  %s\n", pkts, b, $0
    }'

    _line
    echo -e " ${BOLD}FORWARD:${RESET}"
    iptables -L FORWARD -n -v 2>/dev/null | awk 'NR>2 && $1+0>0 {
      pkts=$1; bytes=$2;
      if (bytes+0 >= 1048576) b=sprintf("%.2f MB", bytes/1048576)
      else if (bytes+0 >= 1024) b=sprintf("%.1f KB", bytes/1024)
      else b=bytes" B"
      printf "  pkts=\033[1;37m%-8s\033[0m  bytes=\033[0;36m%-12s\033[0m\n", pkts, b
    }'

    _line
    sleep 2
  done
}

# ── TOP ХОСТОВ ─────────────────────────────────────────────
_top_hosts() {
  _banner
  echo -e " ${BOLD}▸ ТОП ИСТОЧНИКОВ${RESET}  (по активным сессиям)"
  _line

  if ! command -v conntrack &>/dev/null; then
    echo -e "  ${RED}conntrack не найден${RESET}"; return
  fi

  echo -e "  ${BOLD}Частота источников → $NL_SERVER:${RESET}"
  conntrack -L --dst "$NL_SERVER" 2>/dev/null \
    | grep -oP 'src=\K[\d.]+' \
    | sort | uniq -c | sort -rn | head -15 \
    | awk '{
        bar=""
        n=int($1/2); if(n>40) n=40
        for(i=0;i<n;i++) bar=bar"█"
        printf "  \033[1;37m%4d\033[0m  \033[0;36m%-16s\033[0m  \033[0;32m%s\033[0m\n", $1, $2, bar
      }'

  _line
  echo -e "\n  ${BOLD}Топ портов назначения:${RESET}"
  conntrack -L --dst "$NL_SERVER" 2>/dev/null \
    | grep -oP 'dport=\K\d+' \
    | sort | uniq -c | sort -rn | head -10 \
    | awk '{
        printf "  \033[1;37m%4d\033[0m  :\033[0;36m%-6s\033[0m\n", $1, $2
      }'
  echo ""
}

# ── СТОП / СТАРТ ───────────────────────────────────────────
_refresh_motd() {
  [[ ! -f /etc/cascade/config ]] && return
  source /etc/cascade/config
  local portmap_lines=""
  while IFS=: read -r lp rp; do
    portmap_lines+="    :${lp}  ──▸  ${NL_SERVER}:${rp}\n"
  done < /etc/cascade/portmap
  cat > /etc/motd.cascade << MOTD

 ██████╗ █████╗ ███████╗ ██████╗ █████╗ ██████╗
██╔════╝██╔══██╗██╔════╝██╔════╝██╔══██╗██╔══██╗
██║     ███████║███████╗██║     ███████║██║  ██║
██║     ██╔══██║╚════██║██║     ██╔══██║██║  ██║
╚██████╗██║  ██║███████║╚██████╗██║  ██║██████╔╝
 ╚═════╝╚═╝  ╚═╝╚══════╝ ╚═════╝╚═╝  ╚═╝╚═════╝

  EU сервер : ${NL_SERVER}
  Интерфейс : ${IFACE}

  Port emulation:
$(echo -e "$portmap_lines")
  ─────────────────────────────────────────────────
  cascade              — открыть TUI меню
  cascade status       — статус и маппинги
  cascade traffic      — live трафик (tcpdump)
  cascade sessions     — активные сессии
  cascade top          — топ хостов/портов
  cascade stats        — статистика пакетов
  cascade portmap      — список маппингов
  cascade stop|start   — стоп / запуск
  cascade restart      — перезапуск правил
  ─────────────────────────────────────────────────

MOTD
}

_stop() {
  iptables -t nat -F PREROUTING
  iptables -F FORWARD
  iptables -P FORWARD DROP
  echo -e "${RED}${BOLD}● cascade остановлен${RESET}"
}

_start() {
  source /etc/cascade/config
  while IFS=: read -r lp rp; do
    iptables -t nat -A PREROUTING -i $IFACE -p tcp --dport "$lp" \
      -j DNAT --to-destination "$NL_SERVER:$rp"
    iptables -A FORWARD -d $NL_SERVER -p tcp --dport "$rp" -j ACCEPT
  done < /etc/cascade/portmap
  ALL_LOCAL="$LOCAL_PORTS"
  while IFS=: read -r lp _; do ALL_LOCAL="${ALL_LOCAL},${lp}"; done < /etc/cascade/portmap
  iptables -t nat -A PREROUTING -i $IFACE -p tcp \
    -m multiport ! --dports "$ALL_LOCAL" -j DNAT --to-destination "$NL_SERVER"
  iptables -t nat -A PREROUTING -i $IFACE -p udp \
    -j DNAT --to-destination "$NL_SERVER"
  iptables -t nat -A POSTROUTING -j MASQUERADE
  iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  iptables -A FORWARD -d $NL_SERVER -j ACCEPT
  iptables-save > /etc/cascade-rules.v4
  _refresh_motd
  echo -e "${GREEN}${BOLD}● cascade запущен${RESET}  →  $NL_SERVER"
}

_portmap_add() {
  echo -e "${BOLD}Добавить port emulation маппинг${RESET}"
  echo -e "${DIM}Формат: локальный_порт:удалённый_порт${RESET}"
  read -p "$(echo -e ${CYAN}  маппинг${RESET}: )" entry
  local lp rp
  lp=$(echo "$entry" | cut -d: -f1 | tr -d ' ')
  rp=$(echo "$entry" | cut -d: -f2 | tr -d ' ')
  if [[ "$lp" =~ ^[0-9]+$ && "$rp" =~ ^[0-9]+$ ]]; then
    # убираем если уже есть
    sed -i "/^${lp}:/d" /etc/cascade/portmap
    echo "$lp:$rp" >> /etc/cascade/portmap
    echo -e "  ${GREEN}Добавлено: :$lp → EU:$rp${RESET}"
    echo -e "  Перезапускаю правила..."
    _stop; _start
  else
    echo -e "  ${RED}Неверный формат${RESET}"
  fi
}

_portmap_del() {
  echo -e "${BOLD}Удалить маппинг:${RESET}"
  _portmap_list
  read -p "$(echo -e ${CYAN}  порт для удаления${RESET}: )" lp
  if grep -q "^${lp}:" /etc/cascade/portmap; then
    sed -i "/^${lp}:/d" /etc/cascade/portmap
    echo -e "  ${GREEN}Удалено${RESET}"
    _stop; _start
  else
    echo -e "  ${RED}Маппинг :$lp не найден${RESET}"
  fi
}

_change_target() {
  echo -e "${BOLD}Сменить EU сервер${RESET}"
  read -p "$(echo -e ${CYAN}  новый IP${RESET}: )" newip
  if [[ ! $newip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo -e "  ${RED}Невалидный IP${RESET}"; return
  fi
  sed -i "s/NL_SERVER=.*/NL_SERVER=\"$newip\"/" /etc/cascade/config
  NL_SERVER="$newip"
  _stop; _start
  echo -e "  ${GREEN}Таргет изменён на $newip${RESET}"
}

_flush_save() {
  iptables-save > /etc/cascade-rules.v4
  echo -e "${GREEN}Правила сохранены${RESET} → /etc/cascade-rules.v4"
}

_show_nat() {
  _banner
  echo -e " ${BOLD}NAT PREROUTING:${RESET}"
  _line
  iptables -t nat -L PREROUTING -n -v --line-numbers
  echo ""
  echo -e " ${BOLD}NAT POSTROUTING:${RESET}"
  _line
  iptables -t nat -L POSTROUTING -n -v
  echo ""
}

_reset_counters() {
  iptables -Z; iptables -t nat -Z
  echo -e "${GREEN}Счётчики сброшены${RESET}"
}

# ── ГЛАВНОЕ МЕНЮ ────────────────────────────────────────────
_menu() {
  while true; do
    _banner
    _status_chip
    _line
    echo ""
    echo -e "  ${BOLD}${WHITE}[1]${RESET}  статус / обзор"
    echo -e "  ${BOLD}${WHITE}[2]${RESET}  ${GREEN}live трафик${RESET}          ← смотреть что идёт в реальном времени"
    echo -e "  ${BOLD}${WHITE}[3]${RESET}  ${GREEN}активные сессии${RESET}      ← кто сейчас подключён (watch)"
    echo -e "  ${BOLD}${WHITE}[4]${RESET}  ${GREEN}топ хостов/портов${RESET}    ← откуда больше всего трафика"
    echo -e "  ${BOLD}${WHITE}[5]${RESET}  ${CYAN}статистика пакетов${RESET}   ← байты/пакеты по правилам (watch)"
    echo ""
    echo -e "  ${BOLD}${WHITE}[6]${RESET}  port emulation → список маппингов"
    echo -e "  ${BOLD}${WHITE}[7]${RESET}  port emulation → добавить маппинг"
    echo -e "  ${BOLD}${WHITE}[8]${RESET}  port emulation → удалить маппинг"
    echo ""
    echo -e "  ${BOLD}${WHITE}[9]${RESET}  ${RED}остановить${RESET}  cascade"
    echo -e "  ${BOLD}${WHITE}[10]${RESET} ${GREEN}запустить${RESET}   cascade"
    echo -e "  ${BOLD}${WHITE}[11]${RESET} сменить EU сервер"
    echo -e "  ${BOLD}${WHITE}[12]${RESET} NAT таблица (iptables)"
    echo -e "  ${BOLD}${WHITE}[13]${RESET} сбросить счётчики пакетов"
    echo -e "  ${BOLD}${WHITE}[14]${RESET} сохранить правила (persist)"
    echo -e "  ${BOLD}${WHITE}[0]${RESET}  выход"
    echo ""
    _line
    read -p "$(echo -e ${CYAN}  cascade${RESET} ▸ )" choice

    case $choice in
      1)  _status; read -p "  [Enter] назад..." ;;
      2)  _live_traffic ;;
      3)  _watch_sessions ;;
      4)  _top_hosts; read -p "  [Enter] назад..." ;;
      5)  _watch_stats ;;
      6)  _banner; echo -e " ${BOLD}Port emulation маппинги:${RESET}"; _line; _portmap_list; echo ""; read -p "  [Enter] назад..." ;;
      7)  _portmap_add; sleep 1 ;;
      8)  _portmap_del; sleep 1 ;;
      9)  _stop; sleep 1 ;;
      10) _start; sleep 1 ;;
      11) _change_target; sleep 1 ;;
      12) _show_nat; read -p "  [Enter] назад..." ;;
      13) _reset_counters; sleep 1 ;;
      14) _flush_save; sleep 1 ;;
      0)  echo -e "${DIM}bye${RESET}"; exit 0 ;;
      *)  echo -e "  ${RED}неверный выбор${RESET}"; sleep 0.5 ;;
    esac
  done
}

# ── CLI args ────────────────────────────────────────────────
case "$1" in
  status)   _status ;;
  traffic)  _live_traffic ;;
  sessions) _watch_sessions ;;
  top)      _top_hosts ;;
  stats)    _watch_stats ;;
  nat)      _show_nat ;;
  stop)     _stop ;;
  start)    _start ;;
  restart)  _stop; sleep 0.5; _start ;;
  portmap)  _portmap_list ;;
  "")       _menu ;;
  *)        echo -e "Использование: cascade [status|traffic|sessions|top|stats|nat|stop|start|restart|portmap]" ;;
esac

CTLEOF

chmod +x /usr/local/bin/cascade

# ── systemd: правильный autostart ──────────────
# Пересоздаём сервис — используем cascade start вместо iptables-restore
# это надёжнее: пересоздаёт правила из конфига, а не из дампа
cat > /etc/systemd/system/cascade.service << EOF
[Unit]
Description=Cascade port-emulation (iptables NAT)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'echo 1 > /proc/sys/net/ipv4/ip_forward; /usr/local/bin/cascade start'
ExecStop=/usr/local/bin/cascade stop

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable cascade.service
systemctl start cascade.service

# ── MOTD ────────────────────────────────────────
# Убираем старый cascade motd если есть
rm -f /etc/update-motd.d/99-cascade /etc/profile.d/cascade-motd.sh

# Генерируем статический /etc/motd.cascade (обновляется при cascade start/stop)
_write_motd() {
  local portmap_lines=""
  while IFS=: read -r lp rp; do
    portmap_lines+="    :${lp}  ──▸  ${NL_SERVER}:${rp}\n"
  done < /etc/cascade/portmap

  cat > /etc/motd.cascade << MOTD

 ██████╗ █████╗ ███████╗ ██████╗ █████╗ ██████╗
██╔════╝██╔══██╗██╔════╝██╔════╝██╔══██╗██╔══██╗
██║     ███████║███████╗██║     ███████║██║  ██║
██║     ██╔══██║╚════██║██║     ██╔══██║██║  ██║
╚██████╗██║  ██║███████║╚██████╗██║  ██║██████╔╝
 ╚═════╝╚═╝  ╚═╝╚══════╝ ╚═════╝╚═╝  ╚═╝╚═════╝

  EU сервер : ${NL_SERVER}
  Интерфейс : ${IFACE}

  Port emulation:
$(echo -e "$portmap_lines")
  ─────────────────────────────────────────────────
  cascade              — открыть TUI меню
  cascade status       — статус и маппинги
  cascade traffic      — live трафик (tcpdump)
  cascade sessions     — активные сессии
  cascade top          — топ хостов/портов
  cascade stats        — статистика пакетов
  cascade portmap      — список маппингов
  cascade stop|start   — стоп / запуск
  cascade restart      — перезапуск правил
  ─────────────────────────────────────────────────

MOTD
}

_write_motd

# Подключаем motd через update-motd.d (работает на Ubuntu/Debian)
cat > /etc/update-motd.d/99-cascade << 'MOTDEOF'
#!/bin/bash
cat /etc/motd.cascade 2>/dev/null
MOTDEOF
chmod +x /etc/update-motd.d/99-cascade

# Fallback: если update-motd.d не поддерживается — добавляем в /etc/profile.d
cat > /etc/profile.d/cascade-motd.sh << 'PROFEOF'
# показываем cascade info только в интерактивных сессиях
if [ -t 1 ] && [ -f /etc/motd.cascade ]; then
  # проверяем что ещё не показали в этой сессии
  if [ -z "$CASCADE_MOTD_SHOWN" ]; then
    export CASCADE_MOTD_SHOWN=1
    cat /etc/motd.cascade
  fi
fi
PROFEOF

# ── done ───────────────────────────────────────
clear
echo ""
echo -e "${GREEN}${BOLD}════════════════════════════════════${RESET}"
echo -e "${GREEN}${BOLD}   cascade установлен успешно!${RESET}"
echo -e "${GREEN}${BOLD}════════════════════════════════════${RESET}"
echo ""
echo -e "  EU сервер  : ${CYAN}$NL_SERVER${RESET}"
echo -e "  Интерфейс  : ${CYAN}$IFACE${RESET}"
echo -e "  Локальные  : ${CYAN}$LOCAL_PORTS${RESET}"
echo -e "  Автостарт  : ${GREEN}✓ включён (systemd)${RESET}"
echo ""
echo -e "  ${BOLD}Port emulation:${RESET}"
while IFS=: read -r lp rp; do
  echo -e "    :${CYAN}${lp}${RESET}  ──▸  ${NL_SERVER}:${GREEN}${rp}${RESET}"
done < /etc/cascade/portmap
echo ""
echo -e "  ${DIM}MOTD добавлен — будет показываться при входе по SSH${RESET}"
echo ""
echo -e "${CYAN}${BOLD}  Открываю cascade...${RESET}"
sleep 2

# ── запускаем CLI сразу после установки ──
exec /usr/local/bin/cascade
