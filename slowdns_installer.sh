#!/bin/bash

# ==============================================================================
# Script para la instalación y gestión de SlowDNS + Dropbear
# ==============================================================================
#
# Descripción:
# ------------
# Este script automatiza la instalación y configuración de un servidor de
# túnel DNS (SlowDNS) usando el servidor 'dnstt-server' y el servidor SSH
# ligero Dropbear. También proporciona herramientas para la gestión de
- usuarios.
#
# Hecho por: Jules
#
# ==============================================================================

# Colores para la salida
VERDE="\\e[1;32m"
ROJO="\\e[1;31m"
AMARILLO="\\e[1;33m"
CYAN="\\e[1;36m"
FIN="\\e[0m"

# Función para detectar si el sistema operativo está basado en Debian/Ubuntu
check_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [[ "$ID" == "debian" || "$ID" == "ubuntu" || "$ID_LIKE" == "debian" ]]; then
            echo -e "$VERDE Distribución compatible detectada. ($PRETTY_NAME)$FIN"
        else
            echo -e "$ROJO Este script solo es compatible con distribuciones basadas en Debian/Ubuntu.$FIN"
            exit 1
        fi
    else
        echo -e "$ROJO No se pudo detectar la distribución del sistema operativo.$FIN"
        exit 1
    fi
}

# Función para comprobar si el script se ejecuta como root
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "$ROJO Este script debe ejecutarse como root.$FIN"
        exit 1
    fi
}

# Función para instalar las dependencias necesarias
install_dependencies() {
    echo -e "$CYAN Actualizando la lista de paquetes...$FIN"
    apt-get update
    echo -e "$CYAN Instalando dependencias (dropbear, curl)...$FIN"
    apt-get install -y dropbear curl
    echo -e "$VERDE Dependencias instaladas correctamente.$FIN"
}

# Comprobaciones iniciales
check_root
check_distro

# Función para descargar e instalar el servidor dnstt
install_dnstt_server() {
    echo -e "$CYAN Detectando la arquitectura del servidor...$FIN"
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) ARCH_NAME="amd64" ;;
        aarch64) ARCH_NAME="arm64" ;;
        *)
            echo -e "$ROJO Arquitectura no soportada: $ARCH$FIN"
            echo -e "$AMARILLO Por favor, instala 'dnstt-server' manualmente en /usr/local/bin/$FIN"
            exit 1
            ;;
    esac
    echo -e "$VERDE Arquitectura detectada: $ARCH ($ARCH_NAME)$FIN"

    echo -e "$CYAN Obteniendo la última versión de dnstt-server...$FIN"
    LATEST_TAG=$(curl -s "https://api.github.com/repos/d3-pub/dnstt/releases/latest" | grep -Po '"tag_name": "\K.*?(?=")')
    if [ -z "$LATEST_TAG" ]; then
        echo -e "$ROJO No se pudo obtener la última versión de dnstt. Usando v1.1.2 como fallback.$FIN"
        LATEST_TAG="v1.1.2" # Fallback version
    fi
    echo -e "$VERDE Última versión encontrada: $LATEST_TAG$FIN"

    DOWNLOAD_URL="https://github.com/d3-pub/dnstt/releases/download/${LATEST_TAG}/dnstt-server-linux-${ARCH_NAME}"

    echo -e "$CYAN Descargando dnstt-server desde $DOWNLOAD_URL...$FIN"
    curl -L -o /usr/local/bin/dnstt-server "$DOWNLOAD_URL"

    if [ $? -ne 0 ]; then
        echo -e "$ROJO La descarga de dnstt-server falló.$FIN"
        exit 1
    fi

    chmod +x /usr/local/bin/dnstt-server
    echo -e "$VERDE dnstt-server instalado correctamente en /usr/local/bin/dnstt-server$FIN"
}

# Función para configurar el servidor DNS (dnstt)
configure_dnstt() {
    # Instalar el binario del servidor dnstt
    install_dnstt_server

    echo -e "$CYAN Configurando el servidor DNS (dnstt)...$FIN"

    # Crear directorio de configuración
    mkdir -p /etc/slowdns

    # Generar claves si no existen
    if [ ! -f /etc/slowdns/server.key ] || [ ! -f /etc/slowdns/server.pub ]; then
        echo -e "$AMARILLO Generando claves para el servidor DNS...$FIN"
        /usr/local/bin/dnstt-server -gen-key -privkey-file /etc/slowdns/server.key -pubkey-file /etc/slowdns/server.pub
    else
        echo -e "$VERDE Las claves del servidor DNS ya existen.$FIN"
    fi

    # Pedir el dominio NS
    read -p "Introduce tu dominio NS (ej: t.dominio.com): " NS_DOMAIN
    if [ -z "$NS_DOMAIN" ]; then
        echo -e "$ROJO El dominio NS no puede estar vacío.$FIN"
        exit 1
    fi

    # Detectar la IP pública del servidor
    SERVER_IP=$(curl -s ifconfig.me)

    # Crear el servicio systemd
    echo -e "$CYAN Creando el servicio systemd para SlowDNS...$FIN"
    cat > /etc/systemd/system/slowdns.service <<EOF
[Unit]
Description=dnstt-server (SlowDNS)
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/dnstt-server -udp :53 -privkey-file /etc/slowdns/server.key $NS_DOMAIN 127.0.0.1:2222
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    # Recargar, habilitar e iniciar el servicio
    systemctl daemon-reload
    systemctl enable slowdns
    systemctl start slowdns

    # Mostrar información de configuración
    PUBLIC_KEY=$(cat /etc/slowdns/server.pub)
    echo -e "$VERDE ¡Servidor DNS configurado!$FIN"
    echo -e "$AMARILLO ========================================================================$FIN"
    echo -e "$CYAN Para que el túnel funcione, debes configurar los siguientes registros DNS:$FIN"
    echo ""
    echo -e " 1. Un registro A para tu servidor:"
    echo -e "    $CYAN$NS_DOMAIN.    IN    A    $SERVER_IP$FIN"
    echo ""
    echo -e " 2. Un registro NS para el subdominio del túnel:"
    echo -e "    $CYAN$NS_DOMAIN.    IN    NS    $NS_DOMAIN.$FIN"
    echo ""
    echo -e " Clave pública del servidor para el cliente:"
    echo -e "    $CYAN$PUBLIC_KEY$FIN"
    echo -e "$AMARILLO ========================================================================$FIN"
}

# Función para configurar Dropbear
configure_dropbear() {
    echo -e "$CYAN Configurando Dropbear...$FIN"

    # Copia de seguridad del archivo de configuración original
    cp /etc/default/dropbear /etc/default/dropbear.bak

    # Modificar la configuración de Dropbear
    cat > /etc/default/dropbear <<EOF
# Activado por el script de SlowDNS
NO_START=0

# Puerto de escucha (lo cambiamos a 2222 para que coincida con dnstt)
DROPBEAR_PORT=2222

# Opciones adicionales
DROPBEAR_EXTRA_ARGS=""

# Banner de bienvenida
DROPBEAR_BANNER="/etc/issue.net"

# Deshabilitar login de root con contraseña
DROPBEAR_RECEIVE_WINDOW=65536
EOF

    # Crear el banner
    echo "¡Bienvenido a tu servidor SlowDNS!" > /etc/issue.net

    # Reiniciar Dropbear para aplicar los cambios
    systemctl restart dropbear
    echo -e "$VERDE Dropbear configurado para escuchar en el puerto 2222.$FIN"
}


# --- Funciones de gestión de usuarios ---

# Función para crear un nuevo usuario
create_user() {
    echo -e "$CYAN --- Crear nuevo usuario ---$FIN"
    read -p "Nombre de usuario: " username
    if id "$username" &>/dev/null; then
        echo -e "$ROJO El usuario '$username' ya existe.$FIN"
        return
    fi

    read -s -p "Contraseña: " password
    echo "" # Añadir un salto de línea después de la entrada de la contraseña
    read -p "¿Cuántos días de validez? (ej: 30): " days_valid

    # Crear el usuario sin acceso a una shell real
    useradd -M -s /bin/false "$username"
    echo "$username:$password" | chpasswd

    # Establecer la fecha de expiración
    expire_date=$(date -d "+$days_valid days" +"%Y-%m-%d")
    chage -E "$expire_date" "$username"

    echo -e "$VERDE ¡Usuario '$username' creado con éxito!$FIN"
    echo -e "$AMARILLO Expira el: $expire_date$FIN"
}

# Función para eliminar un usuario
delete_user() {
    echo -e "$CYAN --- Eliminar usuario ---$FIN"
    read -p "Nombre de usuario a eliminar: " username
    if ! id "$username" &>/dev/null; then
        echo -e "$ROJO El usuario '$username' no existe.$FIN"
        return
    fi
    userdel -r "$username"
    echo -e "$VERDE Usuario '$username' eliminado con éxito.$FIN"
}

# Función para renovar un usuario
renew_user() {
    echo -e "$CYAN --- Renovar usuario ---$FIN"
    read -p "Nombre de usuario a renovar: " username
    if ! id "$username" &>/dev/null; then
        echo -e "$ROJO El usuario '$username' no existe.$FIN"
        return
    fi

    read -p "¿Cuántos días adicionales de validez? (ej: 30): " days_valid

    # Obtenemos la fecha de expiración actual para calcular la nueva
    current_expire_date=$(chage -l "$username" | grep 'Account expires' | awk -F': ' '{print $2}')
    if [[ "$current_expire_date" == "never" ]]; then
        # Si no tiene fecha de expiración, se calcula desde hoy
        new_expire_date=$(date -d "+$days_valid days" +"%Y-%m-%d")
    else
        # Si ya tiene fecha, se le suman los nuevos días
        new_expire_date=$(date -d "$current_expire_date + $days_valid days" +"%Y-%m-%d")
    fi

    chage -E "$new_expire_date" "$username"
    echo -e "$VERDE ¡Usuario '$username' renovado con éxito!$FIN"
    echo -e "$AMARILLO Nueva fecha de expiración: $new_expire_date$FIN"
}

# Función para listar todos los usuarios del túnel
list_users() {
    echo -e "$CYAN --- Lista de usuarios ---$FIN"
    echo -e "------------------------------------"
    printf "%-20s | %-15s\n" "Usuario" "Expira el"
    echo -e "------------------------------------"

    # Listamos usuarios con UID >= 1000 y shell /bin/false
    awk -F: '$3 >= 1000 && $7 == "/bin/false" {print $1}' /etc/passwd | while read -r user; do
        expire_date=$(chage -l "$user" | grep 'Account expires' | awk -F': ' '{print $2}')
        printf "%-20s | %-15s\n" "$user" "$expire_date"
    done
    echo -e "------------------------------------"
}


# Función para desinstalar el servidor
uninstall() {
    echo -e "$CYAN --- Desinstalar SlowDNS y Dropbear ---$FIN"
    read -p "¿Estás seguro de que quieres desinstalar todo? (s/n): " confirm
    if [[ "$confirm" != "s" ]]; then
        echo -e "$AMARILLO Desinstalación cancelada.$FIN"
        return
    fi

    # Detener y deshabilitar servicios
    systemctl stop slowdns
    systemctl disable slowdns
    systemctl stop dropbear

    # Eliminar archivos de configuración y servicios
    rm -f /etc/systemd/system/slowdns.service
    rm -rf /etc/slowdns
    rm -f /etc/default/dropbear
    mv /etc/default/dropbear.bak /etc/default/dropbear &>/dev/null
    systemctl daemon-reload

    # Desinstalar paquetes (opcional, se puede preguntar al usuario)
    # apt-get remove --purge -y dropbear dnsutils

    echo -e "$VERDE ¡Desinstalación completada!$FIN"
    echo -e "$AMARILLO Es posible que necesites reiniciar el servidor para finalizar la limpieza.$FIN"
}

# Flujo de instalación
install() {
    check_root
    check_distro
    install_dependencies
    configure_dnstt
    configure_dropbear
    echo -e "$VERDE ¡Instalación completada! Ahora puedes gestionar usuarios con este script.$FIN"
    echo -e "$AMARILLO ======================== NOTA IMPORTANTE ========================$FIN"
    echo -e "$CYAN No olvides abrir el puerto UDP 53 en tu firewall para permitir las$FIN"
    echo -e "$CYAN conexiones entrantes al servidor DNS.$FIN"
    echo -e "$AMARILLO ================================================================$FIN"
}

# Menú principal
show_menu() {
    echo -e "$CYAN --- Menú de gestión de SlowDNS ---$FIN"
    echo "1. Instalar/Reinstalar el servidor"
    echo "2. Crear usuario"
    echo "3. Eliminar usuario"
    echo "4. Renovar usuario"
    echo "5. Listar usuarios"
    echo "6. Desinstalar el servidor"
    echo "7. Salir"
    echo -e "------------------------------------"
    read -p "Elige una opción: " choice
}

# Lógica principal del script
main() {
    check_root
    while true; do
        show_menu
        case $choice in
            1) install ;;
            2) create_user ;;
            3) delete_user ;;
            4) renew_user ;;
            5) list_users ;;
            6) uninstall ;;
            7) echo -e "$VERDE ¡Hasta luego!$FIN"; exit 0 ;;
            *) echo -e "$ROJO Opción no válida. Inténtalo de nuevo.$FIN" ;;
        esac
        echo ""
        read -p "Presiona Enter para continuar..."
        clear
    done
}

# Iniciar el script
main
