#!/bin/bash
set -euo pipefail

source <(wget -qO- https://raw.githubusercontent.com/Lobzikfase2/ci-cd-scripts/main/base.sh)
set_user_info

TELEMT_DIR="$USER_HOME/telemt"
if [ ! -d "$TELEMT_DIR" ]; then
    echo "Ошибка: директория $TELEMT_DIR не найдена. Убедитесь, что Telemt установлен."
    exit 1
fi

# Текущий конфиг (предполагаем, что он один)
current_config=$(ls "$TELEMT_DIR"/telemt_*.toml 2>/dev/null | head -n1)
if [ -z "$current_config" ]; then
    echo "Не найден файл конфигурации telemt_*.toml в $TELEMT_DIR"
    exit 1
fi
current_version=$(basename "$current_config" | sed -n 's/telemt_\(.*\)\.toml/\1/p')
echo "Текущая версия Telemt: $current_version"

read -p "Введите новую версию Telemt" new_version
if [ -z "$new_version" ]; then
    echo "Версия не может быть пустой."
    exit 1
fi

new_config="$TELEMT_DIR/telemt_$new_version.toml"
if [ ! -f "$new_config" ]; then
    echo "Копируем текущий конфиг в $new_config"
    cp "$current_config" "$new_config"
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
  "$image_name"

echo "Контейнер Telemt версии $new_version запущен."
docker logs --tail 20 telemt
