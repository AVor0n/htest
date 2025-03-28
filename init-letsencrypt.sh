#!/bin/bash

# Проверка наличия docker-compose
if ! [ -x "$(command -v docker-compose)" ]; then
  echo 'Error: docker-compose is not installed.' >&2
  exit 1
fi

# Проверка аргументов командной строки
TEST_MODE=false
for arg in "$@"; do
  case $arg in
    --test)
      TEST_MODE=true
      shift
      ;;
  esac
done

# Вывод информации о режиме работы
if [ "$TEST_MODE" = true ]; then
  echo "Running in TEST mode. Certificates will be issued by Let's Encrypt staging server."
else
  echo "Running in PRODUCTION mode. Certificates will be issued by Let's Encrypt production server."
fi

read -p "Enter domain (e.g. example.com): " domains
read -p "Enter email for Let's Encrypt notifications: " email

mkdir -p ./certbot/conf
mkdir -p ./certbot/www
mkdir -p ./nginx/conf.d

# Создаем конфигурацию nginx для домена
cat > ./nginx/conf.d/default.conf << EOF
server {
    listen 80;
    server_name ${domains} www.${domains};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    # Временно отключаем редирект на HTTPS для получения сертификата
    location / {
        root /usr/share/nginx/html;
        index index.html;
    }
}
EOF

# Запускаем временный nginx для проверки домена
docker-compose down
docker-compose up -d app

echo "Waiting for Nginx to start..."
sleep 5

# Формируем команду для запроса сертификата
CERTBOT_CMD="docker run --rm \
  -v \"./certbot/conf:/etc/letsencrypt\" \
  -v \"./certbot/www:/var/www/certbot\" \
  --network host \
  certbot/certbot certonly --webroot -w /var/www/certbot \
  --email $email \
  -d $domains -d www.$domains \
  --agree-tos --no-eff-email --force-renewal --verbose"

# Добавляем флаг --staging для тестового режима
if [ "$TEST_MODE" = true ]; then
  CERTBOT_CMD="$CERTBOT_CMD --staging"
fi

# Запрашиваем сертификат
eval $CERTBOT_CMD

# Проверяем, были ли созданы сертификаты
if [ -d "./certbot/conf/live/${domains}" ]; then
    echo "Certificates successfully obtained!"

    # Восстанавливаем полную конфигурацию nginx
    cat > ./nginx/conf.d/default.conf << EOF
server {
    listen 80;
    server_name ${domains} www.${domains};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name ${domains} www.${domains};

    ssl_certificate /etc/letsencrypt/live/${domains}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domains}/privkey.pem;

    # Улучшенные настройки SSL
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_session_tickets off;

    # HSTS (15768000 секунд = 6 месяцев)
    add_header Strict-Transport-Security "max-age=15768000; includeSubDomains" always;

    root /usr/share/nginx/html;
    index index.html;

    # Сжатие
    gzip on;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    # Кэширование статических файлов
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg)\$ {
        expires 30d;
        add_header Cache-Control "public, no-transform";
    }
}
EOF

    # Перезапускаем nginx для применения сертификатов
    docker-compose restart app

    if [ "$TEST_MODE" = true ]; then
      echo "TEST certificates successfully installed. Your site is now available at https://$domains"
      echo "NOTE: Since these are TEST certificates, browsers will show a security warning."
    else
      echo "HTTPS setup completed! Your site is now available at https://$domains"
    fi
else
    echo "Failed to obtain certificates. Check the logs above for errors."
fi
