#!/bin/bash
# ==============================================================
# 🔐 Nginx + Let's Encrypt SSL Setup Script
# Автоматическая выдача SSL сертификата через Certbot + Nginx
# ==============================================================

# --- Защита от запуска через пайп (curl | bash) ---
if [ ! -t 0 ]; then
  SCRIPT_URL="https://raw.githubusercontent.com/sickofme/ssl/main/setup-ssl.sh"
  TMPFILE=$(mktemp /tmp/setup-ssl-XXXXXX.sh)
  echo "⚠ Скрипт запущен через пайп — скачиваю во временный файл..."
  if command -v curl &>/dev/null; then
    curl -fsSL "$SCRIPT_URL" -o "$TMPFILE"
  else
    wget -qO "$TMPFILE" "$SCRIPT_URL"
  fi
  chmod +x "$TMPFILE"
  echo "✓ Запускаю: $TMPFILE"
  exec bash "$TMPFILE"
fi

set -e

# --- Цвета для вывода ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

print_banner() {
  echo -e "${CYAN}"
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║       Nginx + Let's Encrypt SSL Setup Script        ║"
  echo "╚══════════════════════════════════════════════════════╝"
  echo -e "${NC}"
}

print_step() { echo -e "\n${BOLD}${GREEN}▶ $1${NC}"; }
print_warn() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_error() { echo -e "${RED}✗ $1${NC}"; }
print_ok() { echo -e "${GREEN}✓ $1${NC}"; }

# --- Проверка root ---
check_root() {
  if [[ $EUID -ne 0 ]]; then
    print_error "Этот скрипт нужно запускать от root (или через sudo)."
    exit 1
  fi
}

# --- Сбор данных от пользователя ---
collect_input() {
  echo ""
  echo -e "${BOLD}Введите параметры для настройки SSL:${NC}"
  echo "──────────────────────────────────────────────"

  while true; do
    read -rp "🌐 Домен (например: example.com): " DOMAIN
    DOMAIN=$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]' | xargs)
    if [[ -n "$DOMAIN" && "$DOMAIN" == *.* && "$DOMAIN" != *" "* ]]; then
      break
    else
      print_warn "Некорректный формат домена. Попробуйте ещё раз."
    fi
  done

  while true; do
    read -rp "🔌 Порт приложения (например: 3000): " APP_PORT
    if [[ "$APP_PORT" =~ ^[0-9]+$ ]] && [ "$APP_PORT" -ge 1 ] && [ "$APP_PORT" -le 65535 ]; then
      break
    else
      print_warn "Некорректный порт. Введите число от 1 до 65535."
    fi
  done

  while true; do
    read -rp "📧 Email для Let's Encrypt: " LE_EMAIL
    if [[ -n "$LE_EMAIL" && "$LE_EMAIL" == *@*.* ]]; then
      break
    else
      print_warn "Некорректный email. Попробуйте ещё раз."
    fi
  done

  echo ""
  echo -e "${BOLD}Проверьте введённые данные:${NC}"
  echo "──────────────────────────────────────────────"
  echo -e " Домен: ${CYAN}${DOMAIN}${NC}"
  echo -e " Порт приложения: ${CYAN}${APP_PORT}${NC}"
  echo -e " Email: ${CYAN}${LE_EMAIL}${NC}"
  echo "──────────────────────────────────────────────"
  read -rp "Всё верно? [y/N]: " CONFIRM
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Отменено. Запустите скрипт снова."
    exit 0
  fi
}

# --- Установка зависимостей (упрощённая) ---
install_dependencies() {
  print_step "Проверка зависимостей..."

  if ! command -v nginx &>/dev/null; then
    print_error "Nginx не найден. Установите его вручную командой:"
    echo "   apt install nginx    или    dnf install nginx    или    yum install nginx"
    exit 1
  else
    print_ok "Nginx уже установлен"
  fi

  if ! command -v certbot &>/dev/null; then
    print_error "Certbot не найден. Установите его вручную:"
    echo "   apt install certbot python3-certbot-nginx"
    echo "   или"
    echo "   dnf install certbot python3-certbot-nginx"
    exit 1
  else
    print_ok "Certbot уже установлен"
  fi
}

# --- Настройка файрвола ---
configure_firewall() {
  print_step "Настройка файрвола..."
  if command -v ufw &>/dev/null; then
    ufw allow 'Nginx Full' &>/dev/null || true
    ufw allow 22/tcp &>/dev/null || true
    print_ok "UFW: порты 80, 443 и 22 открыты"
  elif command -v firewall-cmd &>/dev/null; then
    firewall-cmd --permanent --add-service=http &>/dev/null || true
    firewall-cmd --permanent --add-service=https &>/dev/null || true
    firewall-cmd --reload &>/dev/null || true
    print_ok "firewalld: порты 80 и 443 открыты"
  else
    print_warn "Файрвол не обнаружен. Убедитесь, что порты 80 и 443 открыты вручную."
  fi
}

# --- Временный Nginx конфиг для certbot ---
create_temp_nginx_config() {
  print_step "Создание временного Nginx конфига для получения сертификата..."

  mkdir -p /var/www/certbot

  # Универсальный временный конфиг (работает и для Debian, и для RHEL)
  cat > /etc/nginx/conf.d/${DOMAIN}_temp.conf <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 200 'SSL setup in progress...';
        add_header Content-Type text/plain;
    }
}
EOF

  # Удаляем default, если он мешает
  rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

  nginx -t && systemctl restart nginx
  print_ok "Временный конфиг применён"
}

# --- Получение сертификата ---
obtain_certificate() {
  print_step "Получение SSL сертификата от Let's Encrypt..."
  certbot certonly \
    --webroot \
    --webroot-path=/var/www/certbot \
    --email "${LE_EMAIL}" \
    --agree-tos \
    --no-eff-email \
    -d "${DOMAIN}" \
    --non-interactive

  print_ok "Сертификат успешно получен для ${DOMAIN}"
}

# --- Финальный Nginx конфиг ---
create_final_nginx_config() {
  print_step "Создание финального Nginx конфига..."

  rm -f /etc/nginx/conf.d/${DOMAIN}_temp.conf

  cat > /etc/nginx/conf.d/${DOMAIN}.conf <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers on;

    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    ssl_stapling on;
    ssl_stapling_verify on;
    resolver 1.1.1.1 8.8.8.8 valid=300s;
    resolver_timeout 5s;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;

    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_read_timeout 300;
        proxy_send_timeout 300;
    }
}
EOF

  print_ok "Финальный конфиг Nginx создан"
}

# --- Автообновление сертификатов ---
setup_auto_renew() {
  print_step "Настройка автоматического обновления сертификата..."
  cat > /etc/cron.d/certbot-renew <<EOF
0 3 * * * root certbot renew --quiet --deploy-hook 'systemctl reload nginx'
EOF
  chmod 644 /etc/cron.d/certbot-renew
  print_ok "Автообновление настроено (ежедневно в 03:00)"
}

# --- Финальный перезапуск ---
final_restart() {
  print_step "Финальная проверка и перезапуск Nginx..."
  nginx -t && systemctl reload nginx

  echo ""
  echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║          ✅ Установка завершена успешно!            ║${NC}"
  echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e " 🌐 Сайт: ${CYAN}https://${DOMAIN}${NC}"
  echo -e " 🔌 Порт приложения: ${CYAN}${APP_PORT}${NC}"
  echo -e " 📧 Email: ${CYAN}${LE_EMAIL}${NC}"
  echo ""
  echo -e " Проверить сертификат: ${YELLOW}certbot certificates${NC}"
  echo -e " Логи Nginx: ${YELLOW}journalctl -u nginx -f${NC}"
}

# ==============================================================
# MAIN
# ==============================================================
print_banner
check_root
collect_input
install_dependencies
configure_firewall
create_temp_nginx_config
obtain_certificate
create_final_nginx_config
setup_auto_renew
final_restart
