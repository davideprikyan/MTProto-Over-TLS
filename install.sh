#!/bin/bash

set -euo pipefail


# Функция сбора параметров установки
get_installation_params() {
   # 1. Выбор режима
    echo "Выберите режим установки:"
    echo "1) Vision"
    echo "2) Reality"
    read -p "Введите 1 или 2: " mode_choice
    case $mode_choice in
        1) MODE="vision" ;;
        2) MODE="reality" ;;
        *) echo "Неверный выбор. Выход."; exit 1 ;;
    esac

    # 2. Использовать IP или домен в ссылке
    read -p "Использовать IP в ссылке или домен? (ip/domain): " addr_type

    # 3. Если в ссылке домен ИЛИ режим Vision → запрашиваем домен по частям
    if [[ $addr_type == "domain" || $MODE == "vision" ]]; then
        read -p "Использовать домен по умолчанию ($DEFAULT_DOMAIN)? (y/n): " use_default
        if [[ $use_default == "y" || $use_default == "Y" ]]; then
            base_domain="$DEFAULT_DOMAIN"
        else
            read -p "Введите основной домен: " base_domain
        fi
        read -p "Введите субдомен: " subdomain
        DOMAIN="${subdomain}.${base_domain}"
    fi

    # 4. Определяем PUBLIC_HOST (то, что пойдёт в ссылку)
    if [[ $addr_type == "domain" ]]; then
        PUBLIC_HOST="$DOMAIN"
    else
        PUBLIC_HOST=$(curl -s4 ident.me || curl -s4 ifconfig.me || curl -s4 icanhazip.com)
    fi

    # 5. Настройки в зависимости от режима
    if [[ $MODE == "vision" ]]; then
        TLS_DOMAIN="$DOMAIN"
        MASK_HOST="127.0.0.1"
        MASK_PORT="8443"
    else
        read -p "Введите домен для SNI (чужой сайт, например www.amazon.com): " TLS_DOMAIN
        TLS_DOMAIN=${TLS_DOMAIN:-www.amazon.com}
        MASK_HOST="$TLS_DOMAIN"
        MASK_PORT="443"
    fi

    # 6. Версия Telemt
    read -p "Введите версию Telemt (по умолчанию $DEFAULT_TELEMT_VERSION): " TELEMT_VERSION
    TELEMT_VERSION=${TELEMT_VERSION:-$DEFAULT_TELEMT_VERSION}

    # 7. Генерация секрета
    SECRET=$(openssl rand -hex 16)

    # 8. Вывод итогов и подтверждение
    echo ""
    log ""
    echo "Режим: $MODE"
    echo "Версия Telemt: $TELEMT_VERSION"
    echo "Публичный адрес (в ссылке): $PUBLIC_HOST"
    echo "SNI: $TLS_DOMAIN"
    echo "Fallback: $MASK_HOST:$MASK_PORT"
    echo "Секрет: $SECRET"
    echo ""
    read -p "Все верно? Продолжить установку? (y/n): " confirm
    if [[ $confirm != "y" && $confirm != "Y" ]]; then
        echo "Установка отменена."
        exit 1
    fi
}

install_components() {
    log "Установка всех необходимых компонентов"
    sudo apt update
    sudo apt install -y git xxd

    if [[ $MODE == "vision" ]]; then
        echo "Установка nginx и certbot..."
        sudo apt install -y nginx-full certbot python3-certbot-nginx
    fi
    echo "Установка всех необходимых компонентов успешно завершена"
    ensure_docker
}

configure_and_start_nginx() {
    log "Первичная настройка nginx"
    sed -i "s/__DOMAIN__/$DOMAIN/g" ./nginx_before_certbot.conf
    sed -i "s/__DOMAIN__/$DOMAIN/g" ./nginx_after_certbot.conf

    rm -f ./dummy_site/main_raw.js
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


# ------------------------------------------------------------------------------------------


configure_telemt() {
    log "Настройка telemt"
    sed -i \
      -e "s/__TLS_DOMAIN__/$TLS_DOMAIN/g" \
      -e "s/__MASK_HOST__/$MASK_HOST/g" \
      -e "s/__MASK_PORT__/$MASK_PORT/g" \
      -e "s/__PUBLIC_HOST__/$PUBLIC_HOST/g" \
      -e "s/__SECRET__/$SECRET/g" \
       ./telemt_$TELEMT_VERSION.toml
    mv ./telemt_$TELEMT_VERSION.toml ../
}

start_telemt() {
    log "Запуск telemt"
    # Очистка старого контейнера и образа
    sudo docker rm -f telemt 2>/dev/null || true
    sudo docker rmi "lobzikfase2/telemt:$TELEMT_VERSION" 2>/dev/null || true
    sudo docker volume rm telemt-data 2>/dev/null || true
    sudo docker volume create telemt-data
    sudo docker run --rm -v telemt-data:/data alpine chown 65532:65532 /data

    sudo docker run -d \
      --name telemt \
      --restart unless-stopped \
      --network host \
      --read-only \
      --tmpfs /tmp:rw,noexec,nosuid,size=16m \
      -v "$USER_HOME/telemt/telemt_$TELEMT_VERSION.toml:/etc/telemt.toml:ro" \
      -v telemt-data:/data:rw \
      --cap-drop=ALL \
      --cap-add=NET_BIND_SERVICE \
      --security-opt no-new-privileges \
      --log-driver json-file \
      --log-opt max-size=50m \
      --log-opt max-file=3 \
      --ulimit nofile=65536:65536 \
      "lobzikfase2/telemt:$TELEMT_VERSION"
}

# Не используем, так как она может очень долго не появляться в логах (до минуты)!
show_proxy_link_from_logs() {
    echo
    log "Ссылка на подключение прокси"
    PROXY_LINK=$(sudo docker logs telemt 2>&1 \
      | grep -oP 'secret=\K[0-9a-f]+' \
      | head -n1 \
      | xargs -I{} echo "tg://proxy?server=$PUBLIC_HOST&port=443&secret={}")

    echo "$PROXY_LINK"
}

show_proxy_link() {
    echo
    log "Ссылка на подключение прокси"
    # Формируем ee-секрет: "ee" + SECRET + hex(domain)
    DOMAIN_HEX=$(echo -n "$TLS_DOMAIN" | xxd -p | tr -d '\n')
    EE_SECRET="ee${SECRET}${DOMAIN_HEX}"
    echo "tg://proxy?server=$PUBLIC_HOST&port=443&secret=$EE_SECRET"
}


# ------------------------------------------------------------------------------------------


DEFAULT_DOMAIN="geogame.play.dart-inter.net"
DEFAULT_TELEMT_VERSION="3.0.6"

# Локальная сборка на основе последнего релиза telemt: https://github.com/telemt/telemt -- смотрим номер версии
_build_and_push_not_for_use() {
  local version=$1
  git clone https://github.com/An0nX/telemt-docker.git
  cd telemt-docker
  docker build --build-arg TELEMT_REF=$version -t lobzikfase2/telemt:$version .
  docker push lobzikfase2/telemt:$version
  rm -rf telemt-docker
}
# _build_and_push_not_for_use 3.0.4
# Install:
# sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/Lobzikfase2/MTProto-Over-TLS/refs/heads/main/install.sh)"
# Update:
# sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/Lobzikfase2/MTProto-Over-TLS/refs/heads/main/update.sh)"
# Очистить все логи:
# sudo truncate -s 0 $(docker inspect --format='{{.LogPath}}' telemt)

main() {
    # Загружаем внешние функции
    source <(wget -qO- https://raw.githubusercontent.com/Lobzikfase2/ci-cd-scripts/main/base.sh)
    set_user_info

    log "Мастер установки telemt (MTProto-Over-TLS)"

    # Запрашиваем параметры установки
    get_installation_params

    # Установка необходимых компонентов
    install_components
    # Настройка UFW
    configure_ufw
    # Настройка sysctl
    backup_sysctl
    configure_sysctl
    echo "net.ipv4.ip_unprivileged_port_start = 443" | sudo tee /etc/sysctl.d/99-telemt.conf > /dev/null
    sudo sysctl --system || true

    log "Клонирование репозитория"
    rm -rf "$USER_HOME/telemt" && mkdir -p "$USER_HOME/telemt" && cd "$USER_HOME/telemt"
    git clone https://github.com/Lobzikfase2/MTProto-Over-TLS.git ./repo && cd ./repo

    configure_telemt

    if [[ $MODE == "vision" ]]; then
        configure_and_start_nginx
    fi

    cd $USER_HOME && sudo chown -R $USER_NAME:$USER_NAME telemt
    cd $USER_HOME/telemt && rm -rf ./repo

    start_telemt
    show_proxy_link

    log ""
    echo "Установка успешно завершена! Выход..."
}

main
