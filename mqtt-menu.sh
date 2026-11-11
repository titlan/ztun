#!/bin/bash
# mqtt-menu.sh - Instalador MQTT con menu de usuarios, TLS y puerto 443
# Uso: sudo bash mqtt-menu.sh
#   1. Pide un dominio, genera el certificado TLS con Certbot (Let's Encrypt)
#      por el puerto 80, y configura Mosquitto para escuchar en 443.
#   2. Deja un menu en /usr/local/sbin/mqtt-menu para crear / borrar /
#      listar usuarios MQTT.
#   3. MQTT escucha en 443 de dos formas a la vez, con el mismo certificado:
#        - MQTT con TLS (MQTTS) en 443, protocolo mqtt
#        - MQTT sobre WebSocket seguro (WSS) en 443, protocolo websockets
#      Nota: Mosquitto solo puede tener un listener por puerto, asi que este
#      script usa 443 para WSS (lo que piden la mayoria de clientes web y
#      moviles) y 8883 para MQTT con TLS. Si solo quieres MQTT con TLS en
#      443, cambia "protocol websockets" por "protocol mqtt" en
#      /etc/mosquitto/conf.d/mqtt-tls.conf y reinicia mosquitto.
#
# Requisitos: VPS limpio, Ubuntu 20.04 / 22.04, root, dominio apuntando
# a la IP del VPS, puertos 80 y 443 libres, email para Let's Encrypt.

set -e
if [ "${EUID}" -ne 0 ]; then
    echo "Correlo como root: sudo bash mqtt-menu.sh"
    exit 1
fi

read -rp "    Dominio para el certificado TLS (ej. mqtt.tu-dominio.com): " -e DOMAIN
read -rp "    Email para Let's Encrypt: " -e EMAIL
if [ -z "$DOMAIN" ] || [ -z "$EMAIL" ]; then
    echo "Faltan dominio o email, saliendo"
    exit 1
fi

echo "$DOMAIN" > /root/mqtt_domain
echo "$DOMAIN" > /etc/mosquitto/domain 2>/dev/null || mkdir -p /etc/mosquitto && echo "$DOMAIN" > /etc/mosquitto/domain

apt-get update -y
apt-get install -y mosquitto mosquitto-clients certbot ufw curl

# Certificado TLS con Certbot, por el puerto 80
systemctl stop mosquitto 2>/dev/null || true
systemctl stop apache2 nginx haproxy 2>/dev/null || true
certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" --rsa-key-size 2048

CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
if [ ! -f "$CERT" ] || [ ! -f "$KEY" ]; then
    echo "No se genero el certificado para $DOMAIN, revisa que el dominio apunte a este VPS y el 80 este libre"
    exit 1
fi
chmod 644 "$CERT"
chmod 600 "$KEY"
# Copia el cert a Mosquitto, porque /etc/letsencrypt/live es solo para root
# y Mosquitto corre como usuario mosquitto y no lo puede leer.
mkdir -p /etc/mosquitto/certs
cp "$CERT" /etc/mosquitto/certs/fullchain.pem
cp "$KEY" /etc/mosquitto/certs/privkey.pem
chown -R mosquitto:mosquitto /etc/mosquitto/certs
chmod 644 /etc/mosquitto/certs/fullchain.pem
chmod 600 /etc/mosquitto/certs/privkey.pem
CERT="/etc/mosquitto/certs/fullchain.pem"
KEY="/etc/mosquitto/certs/privkey.pem"

# Config Mosquitto: 8883 MQTT-TLS + 443 WSS, mismo certificado
# password_file y allow_anonymous van UNA sola vez, arriba, son globales.
# Si se repiten por cada listener Mosquitto falla con
# "Duplicate password_file value in configuration".
cat > /etc/mosquitto/conf.d/mqtt-tls.conf <<EOF
allow_anonymous false
password_file /etc/mosquitto/passwd

# MQTT con TLS en 8883
listener 8883
protocol mqtt
certfile $CERT
keyfile $KEY

# MQTT sobre WebSocket seguro en 443
listener 443
protocol websockets
certfile $CERT
keyfile $KEY
EOF

touch /etc/mosquitto/passwd
chown mosquitto:mosquitto /etc/mosquitto/passwd 2>/dev/null || true
chmod 600 /etc/mosquitto/passwd

ufw allow 22/tcp 2>/dev/null || true
ufw allow 80/tcp 2>/dev/null || true
ufw allow 443/tcp 2>/dev/null || true
ufw allow 8883/tcp 2>/dev/null || true

# Renovacion automatica del certificado y reinicio de Mosquitto
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/mosquitto.sh <<'HOOK'
#!/bin/bash
DOMAIN="$(cat /root/mqtt_domain 2>/dev/null || echo "")"
if [ -n "$DOMAIN" ] && [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
    mkdir -p /etc/mosquitto/certs
    cp "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" /etc/mosquitto/certs/fullchain.pem
    cp "/etc/letsencrypt/live/$DOMAIN/privkey.pem" /etc/mosquitto/certs/privkey.pem
    chown -R mosquitto:mosquitto /etc/mosquitto/certs
    chmod 644 /etc/mosquitto/certs/fullchain.pem
    chmod 600 /etc/mosquitto/certs/privkey.pem
fi
systemctl restart mosquitto 2>/dev/null || true
HOOK
chmod +x /etc/letsencrypt/renewal-hooks/deploy/mosquitto.sh

# Menu de usuarios MQTT
cat > /usr/local/sbin/mqtt-menu <<'MENU'
#!/bin/bash
# mqtt-menu - Menu de usuarios MQTT (Mosquitto)
PASSWD="/etc/mosquitto/passwd"
DOMAIN="$(cat /root/mqtt_domain 2>/dev/null || cat /etc/mosquitto/domain 2>/dev/null || echo "tu-dominio.com")"
while true; do
    clear
    echo "=================-MQTT Menu-===================="
    echo "  Dominio: $DOMAIN"
    echo "  WSS:  wss://$DOMAIN:443"
    echo "  MQTTS: mqtts://$DOMAIN:8883"
    echo ""
    echo "  1) Crear usuario MQTT"
    echo "  2) Borrar usuario MQTT"
    echo "  3) Listar usuarios MQTT"
    echo "  4) Ver estado de Mosquitto"
    echo "  5) Reiniciar Mosquitto"
    echo "  0) Salir"
    echo ""
    read -rp "  Elige una opcion: " -e opt
    case "$opt" in
        1)
            read -rp "  Nombre de usuario: " -e user
            if [ -z "$user" ]; then echo "Usuario vacio"; sleep 2; continue; fi
            read -rsp "  Contrasena: " -e pass
            echo ""
            mosquitto_passwd -b "$PASSWD" "$user" "$pass"
            systemctl restart mosquitto 2>/dev/null || true
            echo ""
            echo "Usuario $user creado. Conectate con wss://$DOMAIN:443 o mqtts://$DOMAIN:8883"
            read -rp "  Pulsa Enter para continuar... " -e _
            ;;
        2)
            read -rp "  Nombre de usuario a borrar: " -e user
            mosquitto_passwd -D "$PASSWD" "$user" 2>/dev/null || echo "No se pudo borrar $user"
            systemctl restart mosquitto 2>/dev/null || true
            echo "Usuario $user borrado (si existia)"
            read -rp "  Pulsa Enter para continuar... " -e _
            ;;
        3)
            echo "  Usuarios:"
            cut -d: -f1 "$PASSWD" 2>/dev/null || echo "  (sin usuarios todavia)"
            read -rp "  Pulsa Enter para continuar... " -e _
            ;;
        4)
            systemctl status mosquitto --no-pager -l
            ss -tlnp | grep -E "443|8883" || true
            read -rp "  Pulsa Enter para continuar... " -e _
            ;;
        5)
            systemctl restart mosquitto
            echo "Mosquitto reiniciado"
            sleep 2
            ;;
        0) exit 0 ;;
        *) echo "Opcion no valida"; sleep 1 ;;
    esac
done
MENU
chmod +x /usr/local/sbin/mqtt-menu
ln -sf /usr/local/sbin/mqtt-menu /usr/bin/mqtt-menu

systemctl enable mosquitto
systemctl restart mosquitto
systemctl status mosquitto --no-pager -l || true
ss -tlnp | grep -E "443|8883" || true

echo ""
echo "Listo. MQTT con TLS instalado."
echo "  WSS:   wss://$DOMAIN:443"
echo "  MQTTS: mqtts://$DOMAIN:8883"
echo "  Menu:  mqtt-menu"
echo "Crea tu primer usuario con: mqtt-menu  (opcion 1)"
