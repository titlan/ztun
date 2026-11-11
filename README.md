# ztun

Instalador MQTT con menú de usuarios, certificado TLS y escucha en el puerto 443.

## Qué hace `mqtt-menu.sh`

1. Pide un dominio y un email.
2. Genera el certificado TLS con Certbot (Let's Encrypt) por el puerto 80.
3. Instala Mosquitto y lo configura con ese certificado:
   - **WSS en 443:** `wss://TU_DOMINIO:443`
   - **MQTTS en 8883:** `mqtts://TU_DOMINIO:8883`
4. Deja el menú `mqtt-menu` para crear, borrar y listar usuarios MQTT.

## Uso en el VPS

```bash
sudo bash mqtt-menu.sh
```

Luego, para crear usuarios:

```bash
mqtt-menu
```

## Requisitos

- VPS limpio, Ubuntu 20.04 / 22.04, como root
- Dominio apuntando a la IP del VPS
- Puertos 80 y 443 libres
