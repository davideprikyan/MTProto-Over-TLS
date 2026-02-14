#!/bin/bash

set -euo pipefail

# Функция для получения информации о пользователе, который запустил скрипт
set_user_info() {
    if [ -n "$SUDO_USER" ]; then
        # Запущено через sudo
        USER_NAME="$SUDO_USER"
        USER_HOME=$(eval echo ~$SUDO_USER)
    else
        # Запущено напрямую
        USER_NAME="$USER"
        USER_HOME="$HOME"
    fi
}
set_user_info

log() {
    local text="$1"
    local char="${2:-=}"
    local width=78

    # Проверяем, что текст пустой или состоит только из пробелов
    if [[ -z "${text// }" ]]; then
        printf '%*s' $width '' | tr ' ' "$char"
        echo
    else
        text=$(echo "$text" | tr '[:lower:]' '[:upper:]')
        local text_part=" $text "
        local text_len=${#text_part}
        local symbols=$((width - text_len))
        local left=$((symbols / 2))
        local right=$((symbols - left))

        printf '%*s' $left '' | tr ' ' "$char"
        echo -n "$text_part"
        printf '%*s' $right '' | tr ' ' "$char"
        echo
    fi
}

# Функция для очистки предыдущих установок Docker
cleanup_docker() {
    log "Очистка предыдущих установок Docker..."
    sudo apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null
    sudo apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-compose 2>/dev/null
    sudo rm -rf /var/lib/docker
    sudo rm -rf /var/lib/containerd
    sudo rm -rf /etc/docker
    sudo rm -rf /etc/apt/sources.list.d/docker.list
    sudo rm -f /usr/share/keyrings/docker-archive-keyring.gpg
    sudo rm -f /usr/local/bin/docker-compose
    sudo rm -f /etc/bash_completion.d/docker-compose
    sudo groupdel docker 2>/dev/null
}

# Ставим докер
install_docker() {
    (
        umask 0022

        sudo apt-get update
        sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common gnupg

        # Добавляем официальный GPG ключ Docker
        sudo install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        sudo chmod a+r /etc/apt/keyrings/docker.gpg

        # Добавляем репозиторий Docker
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
        sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

        sudo apt-get update
        sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

        # Создаем группу docker и добавляем пользователя
        sudo groupadd docker 2>/dev/null
        sudo usermod -aG docker $USER_NAME

        # Запускаем и включаем демон Docker
        sudo systemctl enable docker
        sudo systemctl start docker
    )
}

# Проверяем, что докер установился
check_docker() {
    log "Проверка прав на запуск docker контейнеров..."
    sleep 3

    if ! docker run --rm hello-world; then
        echo "Ошибка при запуске контейнера 'hello-world'"
        echo "Попытка запуска с sudo..."
        sudo docker run --rm hello-world
    fi
}

# Настраиваем ufw
configure_ufw() {
    log "Настройка UFW"
    ssh_port=$(awk '/^Port / {print $2}' /etc/ssh/sshd_config)
    sudo ufw --force disable
    sudo ufw --force reset
    sudo ufw default deny incoming
    sudo ufw default allow outgoing
    sudo ufw allow $ssh_port/tcp
    sudo ufw allow 80/tcp
    sudo ufw allow 443/tcp
    sudo ufw --force enable
    sudo ufw status verbose
}

# Настраиваем ядро
configure_sysctl() {
  log "Конфигурация ядра"
  sudo tee /etc/sysctl.d/99-tuning.conf > /dev/null <<EOF
net.ipv4.tcp_fastopen = 0
# net.ipv4.tcp_timestamps -- Спорно
# 0 - дает меньше данных для анализа
# 1 - делает больше похожим на https
# GPT настаивает не выключать
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.ip_unprivileged_port_start = 443
EOF
  sudo sysctl --system
}

install_components() {
    log "Установка всех необходимых компонентов"
    sudo apt update
    sudo apt install -y git

    # Устанавливаем nginx и certbot только для режима vision
    if [[ $MODE == "vision" ]]; then
        echo "Установка nginx и certbot..."
        sudo apt install -y nginx-full certbot python3-certbot-nginx
    fi

    # Ставим докер
    if ! command -v docker &> /dev/null; then
        cleanup_docker
        install_docker
    fi
    check_docker
    echo "Установка всех необходимых компонентов успешно завершена"
}

configure_telemt() {
    log "Настройка telemt"
    if [[ $MODE == "reality" ]]; then
        MASK_PORT=443
    else
        MASK_PORT=8443
    fi
    SECRET="$(openssl rand -hex 16)"
    sed -i "s/__DOMAIN__/$DOMAIN/g" ./telemt.toml
    sed -i "s/__MASK_PORT__/$MASK_PORT/g" ./telemt.toml
    sed -i "s/__SECRET__/$SECRET/g" ./telemt.toml
    mv ./telemt.toml ../
}

start_telemt() {
    log "Запуск telemt"
    sudo docker rm -f telemt || true
    sudo docker run -d \
      --name telemt \
      --restart unless-stopped \
      --network host \
      --cap-drop=ALL \
      --security-opt no-new-privileges \
      --log-driver json-file \
      --log-opt max-size=50m \
      --log-opt max-file=3 \
      -v $USER_HOME/mtp_proxy/telemt.toml:/etc/telemt.toml:ro \
      whn0thacked/telemt-docker:latest
    sleep 3
}

show_proxy_link() {
    echo
    log "Ссылка на подключение прокси"
    PROXY_LINK=$(sudo docker logs telemt 2>&1 \
      | grep -oP 'secret=\K[0-9a-f]+' \
      | head -n1 \
      | xargs -I{} echo "tg://proxy?server=$DOMAIN&port=443&secret={}")

    echo "$PROXY_LINK"
    log ""
    echo "Установка успешно завершена! Выход..."
}

configure_and_start_nginx() {
    log "Первичная настройка nginx"
    sed -i "s/__DOMAIN__/$DOMAIN/g" ./nginx_before_certbot.conf
    sed -i "s/__DOMAIN__/$DOMAIN/g" ./nginx_after_certbot.conf

    rm ./dummy_site/main_raw.js
    sudo mkdir -p /var/www/dummy
    sudo mv ./dummy_site/* /var/www/dummy

    sudo mv ./nginx_before_certbot.conf /etc/nginx/nginx.conf
    sudo systemctl restart nginx
    sleep 1

    log "Выдача сертификатов"
    sudo certbot --nginx \
      -d $DOMAIN \
      -d www.$DOMAIN \
      --redirect \
      --agree-tos \
      -m game@admin.com \
      --non-interactive

    log "Финальная настройка nginx"
    sudo mv ./nginx_after_certbot.conf /etc/nginx/nginx.conf
    sudo systemctl restart nginx
    sleep 1
}

# -------------------------------------------------------------------------------------------------

DEFAULT_DOMAIN=play.dart-inter.net

main() {
    set_user_info
    log "Мастер установки telemt (MTProto-Over-TLS)"
    # Выбираем режим работы
    echo "Выберите режим установки"
    echo "1) Vision"
    echo "2) Reality"
    read -p "Введите 1 или 2: " mode_choice

        case $mode_choice in
        1)
            MODE="vision"
            # Спрашиваем использовать ли домен по умолчанию
            read -p "Использовать домен по умолчанию ($DEFAULT_DOMAIN)? (y/n): " use_default
            if [[ $use_default == "y" || $use_default == "Y" ]]; then
                DOMAIN=$DEFAULT_DOMAIN
            else
                read -p "Введите основной домен: " base_domain
                DOMAIN=$base_domain
            fi
            # Просим ввести субдомен
            read -p "Введите субдомен: " subdomain
            DOMAIN="${subdomain}.${DOMAIN}"
            ;;
        2)
            MODE="reality"
            # Просим ввести полный домен
            read -p "Введите полный домен: " DOMAIN
            ;;
        *)
            echo "Неверный выбор. Выход."
            exit 1
            ;;
    esac

    # Выводим полный домен и просим подтверждение
    echo ""
    log ""
    echo "Режим установки: $MODE"
    echo "Домен: $DOMAIN"
    log ""
    echo ""
    read -p "Все верно? Продолжить установку? (y/n): " confirm
    if [[ $confirm != "y" && $confirm != "Y" ]]; then
        echo "Установка отменена."
        exit 0
    fi

    install_components
    configure_ufw
    configure_sysctl

    log "Клонирование репозитория"
    rm -rf $USER_HOME/mtp_proxy && mkdir -p $USER_HOME/mtp_proxy && cd $USER_HOME/mtp_proxy
    git clone https://github.com/Lobzikfase2/MTProto-Over-TLS.git ./mtp && cd ./mtp

    configure_telemt

    if [[ $MODE == "vision" ]]; then
        configure_and_start_nginx
    fi

    cd $USER_HOME/mtp_proxy && rm -rf ./mtp && sudo chown -R $USER_NAME:$USER_NAME *

    start_telemt
    show_proxy_link
}

main
