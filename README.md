# CASCADE — Port-Emulation iptables Forwarder

```
 ██████╗ █████╗ ███████╗ ██████╗ █████╗ ██████╗ 
██╔════╝██╔══██╗██╔════╝██╔════╝██╔══██╗██╔══██╗
██║     ███████║███████╗██║     ███████║██║  ██║
██║     ██╔══██║╚════██║██║     ██╔══██║██║  ██║
╚██████╗██║  ██║███████║╚██████╗██║  ██║██████╔╝
 ╚═════╝╚═╝  ╚═╝╚══════╝ ╚═════╝╚═╝  ╚═╝╚═════╝
```

> Умный TCP/UDP форвардер с port emulation — маппит входящий трафик на другие порты при пересылке на EU-сервер.

---

## Что делает

CASCADE превращает Linux-сервер в прозрачный NAT-шлюз с поддержкой port emulation. Провайдер видит стандартные порты (443, 80), а EU-сервер получает трафик на совершенно другие порты (например, VPN-порт 9443).

```
Клиент → :443 → [CASCADE RU сервер] → EU сервер:9443
                       ↑ iptables DNAT + MASQUERADE
```

**Особенности:**
- Port emulation: входящий порт ≠ исходящий порт
- Весь остальной TCP/UDP форвардится напрямую
- Интерактивное TUI-меню (`cascade`) и CLI-команды
- Автостарт через systemd
- Live-мониторинг трафика через tcpdump
- Статистика пакетов в реальном времени
- MOTD при SSH-входе

---

## Требования

- Linux (Ubuntu / Debian)
- root-доступ
- `iptables` (устанавливается автоматически при отсутствии)

---

## Установка

```bash
bash main.sh
```

В процессе скрипт спросит:

1. **IP EU-сервера** — куда форвардить трафик
2. **Кастомные port mappings** — если нужны помимо дефолтных
3. **Локальные порты** — которые остаются на этом сервере (по умолчанию: `22`)

После установки cascade запустится автоматически и откроет TUI-меню.

---

## Port Emulation

По умолчанию настроены маппинги:

| Входящий порт | Порт на EU-сервере | Назначение |
|:---:|:---:|---|
| `443` | `9443` | HTTPS → VPN |
| `80` | `8080` | HTTP → кастомный |

Можно добавить любые свои маппинги во время установки или через `cascade portmap`.

---

## Использование

### TUI-меню

```bash
cascade
```

Интерактивное меню с полным управлением.

### CLI-команды

```bash
cascade status      # статус, маппинги, счётчики
cascade traffic     # live трафик (tcpdump)
cascade sessions    # активные сессии (watch)
cascade top         # топ хостов и портов по трафику
cascade stats       # статистика пакетов (watch)
cascade portmap     # список port emulation маппингов
cascade stop        # остановить форвардинг
cascade start       # запустить форвардинг
cascade restart     # перезапустить правила
cascade nat         # показать NAT-таблицу iptables
```

---

## Мониторинг

| Команда | Описание |
|---|---|
| `cascade traffic` | tcpdump с подсветкой mapped-портов |
| `cascade sessions` | активные соединения через `ss` |
| `cascade stats` | байты/пакеты по iptables-правилам |
| `cascade top` | топ источников по conntrack |

---

## Файлы

| Путь | Описание |
|---|---|
| `/usr/local/bin/cascade` | CTL-утилита |
| `/etc/cascade/config` | конфиг (IP, интерфейс, локальные порты) |
| `/etc/cascade/portmap` | маппинги портов |
| `/etc/cascade-rules.v4` | дамп iptables-правил |
| `/etc/systemd/system/cascade.service` | systemd-сервис |
| `/etc/motd.cascade` | MOTD при SSH-входе |

---

## Автостарт

CASCADE регистрируется как systemd-сервис и запускается автоматически при старте системы:

```bash
systemctl status cascade
systemctl enable cascade   # включить автостарт
systemctl disable cascade  # выключить автостарт
```

---

## Как это работает

```
Входящий пакет на :443
        │
        ▼
iptables PREROUTING (DNAT)
  :443 → EU_IP:9443
        │
        ▼
iptables FORWARD → ACCEPT
        │
        ▼
iptables POSTROUTING (MASQUERADE)
        │
        ▼
EU сервер получает пакет на :9443
```

Весь трафик, не попавший под маппинг, форвардится на EU-сервер без изменения порта. SSH (`:22`) остаётся локальным.

---



```bash
wget https://raw.githubusercontent.com/IGrok2/cascad/main/main.sh
chmod +x main.sh
./main.sh
```


