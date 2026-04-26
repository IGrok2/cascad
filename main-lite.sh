#!/bin/bash

read -p "Введи IP твоего куда прокинуть: " NL_SERVER

if [[ ! $NL_SERVER =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Невалидный IP"
    exit 1
fi

IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
echo "Интерфейс: $IFACE"

if ! command -v iptables &>/dev/null; then
    apt-get update -qq
    apt-get install -y iptables
fi

IPTABLES=$(which iptables)

echo 1 > /proc/sys/net/ipv4/ip_forward
sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p -q

$IPTABLES -F
$IPTABLES -t nat -F
$IPTABLES -t mangle -F
$IPTABLES -X

$IPTABLES -P INPUT DROP
$IPTABLES -P FORWARD DROP
$IPTABLES -P OUTPUT ACCEPT

$IPTABLES -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
$IPTABLES -A INPUT -i lo -j ACCEPT
$IPTABLES -A INPUT -p tcp --dport 22 -j ACCEPT
$IPTABLES -A INPUT -p tcp --dport 80 -j ACCEPT
$IPTABLES -A INPUT -p tcp --dport 443 -j ACCEPT
$IPTABLES -A INPUT -p icmp -j ACCEPT

$IPTABLES -t nat -A PREROUTING -i $IFACE -p tcp \
  -m multiport ! --dports 22,80,443 \
  -j DNAT --to-destination $NL_SERVER

$IPTABLES -t nat -A PREROUTING -i $IFACE -p udp \
  -j DNAT --to-destination $NL_SERVER

$IPTABLES -t nat -A POSTROUTING -j MASQUERADE

$IPTABLES -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
$IPTABLES -A FORWARD -d $NL_SERVER -j ACCEPT

$IPTABLES-save > /etc/cascade-rules.v4

IPTABLES_RESTORE=$(which iptables-restore)

cat > /etc/systemd/system/cascade.service << EOF
[Unit]
Description=Cascade iptables
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'echo 1 > /proc/sys/net/ipv4/ip_forward && $IPTABLES_RESTORE < /etc/cascade-rules.v4'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable cascade.service

cat > /usr/local/bin/cascade << CTLEOF
#!/bin/bash

NL_SERVER="$NL_SERVER"
IFACE="$IFACE"
RULES_FILE="/etc/cascade-rules.v4"

_status() {
    RULES=\$(iptables -t nat -L PREROUTING -n 2>/dev/null | grep -c "\$NL_SERVER")
    if [ "\$RULES" -gt 0 ]; then
        echo "активен → \$NL_SERVER (\$RULES правил)"
    else
        echo "отключён"
    fi
}

_stop() {
    iptables -t nat -F PREROUTING
    iptables -F FORWARD
    iptables -P FORWARD DROP
    echo "остановлен"
}

_start() {
    iptables -t nat -A PREROUTING -i \$IFACE -p tcp \
      -m multiport ! --dports 22,80,443 \
      -j DNAT --to-destination \$NL_SERVER
    iptables -t nat -A PREROUTING -i \$IFACE -p udp \
      -j DNAT --to-destination \$NL_SERVER
    iptables -t nat -A POSTROUTING -j MASQUERADE
    iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -A FORWARD -d \$NL_SERVER -j ACCEPT
    iptables-save > \$RULES_FILE
    echo "запущен → \$NL_SERVER"
}

echo "cascade ctl"
echo ""
_status
echo ""
echo "1) статус"
echo "2) отключить"
echo "3) включить"
echo "4) выход"
echo ""
read -p "> " choice

case \$choice in
    1) _status ;;
    2) _stop ;;
    3) _start ;;
    4) exit 0 ;;
    *) echo "неверный выбор" ;;
esac
CTLEOF

chmod +x /usr/local/bin/cascade

echo ""
echo "Готово"
echo ""
echo "Управление: cascade"
echo ""
$IPTABLES -t nat -L PREROUTING -n -v
