#!/bin/bash
set -euo pipefail

source <(wget -qO- https://raw.githubusercontent.com/Lobzikfase2/ci-cd-scripts/main/base.sh)
set_user_info

TELEMT_DIR="$USER_HOME/telemt"
if [ ! -d "$TELEMT_DIR" ]; then
    echo "Ошибка: директория $TELEMT_DIR не найдена. Убедитесь, что Telemt установлен."
    exit 1
fi

# Функция для получения версии из образа запущенного контейнера
get_running_version() {
    local image
    image=$(docker inspect telemt --format='{{.Config.Image}}' 2>/dev/null || true)
    if [[ -n "$image" ]]; then
        echo "$image" | awk -F: '{print $2}'
    fi
}

# Определяем текущую версию (из запущенного контейнера или из самого свежего конфига)
current_version=""
running_version=$(get_running_version)
if [[ -n "$running_version" ]]; then
    current_version="$running_version"
    echo "Обнаружен контейнер версии: $current_version"
else
    # Берём самый свежий конфиг по времени модификации
    latest_config=$(ls -t "$TELEMT_DIR"/telemt_*.toml 2>/dev/null | head -n1)
    if [[ -z "$latest_config" ]]; then
        echo "Не найден ни один конфиг telemt_*.toml в $TELEMT_DIR"
        exit 1
    fi
    current_version=$(basename "$latest_config" | sed -n 's/telemt_\(.*\)\.toml/\1/p')
    echo "Контейнер telemt не найден. Использую последний изменённый конфиг версии $current_version"
fi

# Спрашиваем новую версию
read -p "Введите новую версию Telemt: " new_version
if [ -z "$new_version" ]; then
    echo "Версия не может быть пустой."
    exit 1
fi

# Путь к конфигу новой версии
new_config="$TELEMT_DIR/telemt_$new_version.toml"

# Если конфиг для новой версии уже существует — спросим, перезаписывать ли
if [ -f "$new_config" ]; then
    echo "Конфиг $new_config уже существует."
    read -p "Использовать его как есть (оставить) или заменить копией из версии $current_version? (o/з): " choice
    if [[ "$choice" == "з" || "$choice" == "З" ]]; then
        cp "$TELEMT_DIR/telemt_$current_version.toml" "$new_config"
        sudo chown "$USER_NAME:$USER_NAME" "$new_config"
        echo "Конфиг заменён копией из версии $current_version."
    else
        echo "Оставляем существующий конфиг."
    fi
else
    # Конфига нет — просто копируем из текущей версии
    cp "$TELEMT_DIR/telemt_$current_version.toml" "$new_config"
    sudo chown "$USER_NAME:$USER_NAME" "$new_config"
    echo "Создан конфиг для версии $new_version на основе версии $current_version."
fi

image_name="lobzikfase2/telemt:$new_version"


docker stop telemt 2>/dev/null || true
docker rm telemt 2>/dev/null || true

# Запускаем новый контейнер
docker run -d \
  --name telemt \
  --restart unless-stopped \
  --network host \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=16m \
  -v "$new_config:/etc/telemt.toml:ro" \
  -v telemt-data:/data:rw \
  --cap-drop=ALL \
  --cap-add=NET_BIND_SERVICE \
  --security-opt no-new-privileges \
  --log-driver json-file \
  --log-opt max-size=50m \
  --log-opt max-file=3 \
  --ulimit nofile=65536:65536 \
  "$image_name"

echo "Контейнер Telemt версии $new_version запущен."
docker logs --tail 20 telemt
