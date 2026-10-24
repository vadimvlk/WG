#!/usr/bin/env bash
# WireGuard VPN на Ubuntu.
# Создаёт сразу нескольких клиентов с указанными именами.
#
# Использование:  bash setup.sh Mob PC
# (без аргументов создаст: Mob PC)
# Опционально:  WG_PORT=51820 WG_DNS="77.88.8.8, 1.1.1.1" bash setup.sh Mob PC
set -euo pipefail

if [[ $EUID -ne 0 ]]; then echo "Запусти от root (или через sudo)"; exit 1; fi

CLIENTS=("$@")
if [[ ${#CLIENTS[@]} -eq 0 ]]; then CLIENTS=(Mob PC); fi
if [[ ${#CLIENTS[@]} -gt 250 ]]; then echo "Слишком много клиентов (максимум 250)"; exit 1; fi

# Проверка имён: латиница/цифры/_/-, до 15 символов, без повторов (без учёта регистра — Windows)
declare -A SEEN=()
for c in "${CLIENTS[@]}"; do
  if [[ ! "$c" =~ ^[A-Za-z0-9_-]{1,15}$ ]]; then
    echo "Плохое имя клиента: '$c' (только латиница, цифры, _ и -, до 15 символов)"; exit 1
  fi
  key="${c,,}"
  if [[ -n "${SEEN[$key]:-}" ]]; then echo "Имя '$c' повторяется"; exit 1; fi
  SEEN[$key]=1
done

WG_IF=wg0
WG_PORT="${WG_PORT:-51820}"
WG_NET="10.8.0"
# DNS для клиентов
WG_DNS="${WG_DNS:-77.88.8.8, 77.88.8.1, 1.1.1.1, 8.8.8.8}"
OUT_DIR=/root/wg-clients

if [[ -e /etc/wireguard/${WG_IF}.conf ]]; then
  echo "/etc/wireguard/${WG_IF}.conf уже существует — сервер уже настроен."
  echo "Чтобы начать заново:  systemctl disable --now wg-quick@${WG_IF}; rm -f /etc/wireguard/${WG_IF}.conf; rm -rf ${OUT_DIR}"
  exit 1
fi

echo "==> Установка пакетов"
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
# на свежем VPS apt часто занят автообновлением — ждём до 5 минут вместо ошибки
apt-get -o DPkg::Lock::Timeout=300 update -y
apt-get -o DPkg::Lock::Timeout=300 install -y wireguard wireguard-tools qrencode iptables curl

echo "==> Определяю сеть"
EXT_IF=$(ip -4 route show default | awk '{print $5; exit}' || true)
if [[ -z "$EXT_IF" ]]; then echo "Не удалось определить внешний сетевой интерфейс"; exit 1; fi
PUB_IP=$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)
if [[ -z "$PUB_IP" ]]; then
  PUB_IP=$(ip -4 addr show "$EXT_IF" | awk '/inet /{sub(/\/.*/,"",$2); print $2; exit}' || true)
fi
if [[ ! "$PUB_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo "Не удалось определить публичный IPv4 сервера"; exit 1; fi
echo "    интерфейс: $EXT_IF, публичный IP: $PUB_IP, порт: $WG_PORT/udp"

echo "==> Включаю пересылку трафика (IP forwarding)"
echo "net.ipv4.ip_forward=1" >/etc/sysctl.d/99-wireguard.conf
sysctl -p /etc/sysctl.d/99-wireguard.conf >/dev/null

echo "==> Генерирую ключи сервера"
umask 077
mkdir -p /etc/wireguard "$OUT_DIR"
SRV_PRIV=$(wg genkey)
SRV_PUB=$(echo "$SRV_PRIV" | wg pubkey)

# NAT (MASQUERADE): трафик клиентов выходит в интернет с IP сервера
cat >/etc/wireguard/${WG_IF}.conf <<EOF
[Interface]
Address = ${WG_NET}.1/24
ListenPort = ${WG_PORT}
PrivateKey = ${SRV_PRIV}
PostUp = iptables -I FORWARD -i %i -j ACCEPT; iptables -I FORWARD -o %i -m state --state RELATED,ESTABLISHED -j ACCEPT; iptables -t nat -A POSTROUTING -s ${WG_NET}.0/24 -o ${EXT_IF} -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -m state --state RELATED,ESTABLISHED -j ACCEPT; iptables -t nat -D POSTROUTING -s ${WG_NET}.0/24 -o ${EXT_IF} -j MASQUERADE
EOF

echo "==> Создаю клиентов"
i=2
for name in "${CLIENTS[@]}"; do
  C_PRIV=$(wg genkey)
  C_PUB=$(echo "$C_PRIV" | wg pubkey)
  C_PSK=$(wg genpsk)
  C_IP="${WG_NET}.${i}"

  cat >>/etc/wireguard/${WG_IF}.conf <<EOF

# ${name}
[Peer]
PublicKey = ${C_PUB}
PresharedKey = ${C_PSK}
AllowedIPs = ${C_IP}/32
EOF

  # AllowedIPs = 0.0.0.0/0, ::/0 — ВЕСЬ трафик клиента идёт в туннель (полноценный VPN).
  # ::/0 нужен, чтобы IPv6 не утекал мимо VPN (на Windows это ещё и включает kill-switch).
  cat >"${OUT_DIR}/${name}.conf" <<EOF
[Interface]
PrivateKey = ${C_PRIV}
Address = ${C_IP}/32
DNS = ${WG_DNS}

[Peer]
PublicKey = ${SRV_PUB}
PresharedKey = ${C_PSK}
Endpoint = ${PUB_IP}:${WG_PORT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF
  echo "    ${name} -> ${C_IP}"
  i=$((i+1))
done

echo "==> Открываю порт и запускаю"
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  ufw allow "${WG_PORT}/udp"
  ufw route allow in on "${WG_IF}" out on "${EXT_IF}" || true
fi
systemctl enable --now wg-quick@${WG_IF}

if ! systemctl is-active --quiet wg-quick@${WG_IF}; then
  echo "ОШИБКА: WireGuard не запустился. Смотри: journalctl -u wg-quick@${WG_IF} --no-pager"
  exit 1
fi

echo
echo "================ ГОТОВО ================"
wg show ${WG_IF}
echo
for name in "${CLIENTS[@]}"; do
  echo "----- ${name}  (${OUT_DIR}/${name}.conf) -----"
  cat "${OUT_DIR}/${name}.conf"
  echo
  qrencode -t ansiutf8 <"${OUT_DIR}/${name}.conf"
  echo
done
echo "Скачать все конфиги на Windows (PowerShell):"
echo "  scp root@${PUB_IP}:${OUT_DIR}/*.conf ."
echo "После подключения открой https://ifconfig.me — должен показаться ${PUB_IP}"
