#!/bin/bash

# ==============================================================
#  🔐 Nginx + Let's Encrypt SSL Setup Script
#  Автоматическая выдача SSL сертификата через Certbot + Nginx
# ==============================================================

# --- Защита от запуска через пайп (curl | bash) ---
if [ ! -t 0 ]; then
  SCRIPT_URL="https://raw.githubusercontent.com/sickofme/ssl/main/setup-ssl.sh"
  TMPFILE=$(mktemp /tmp/setup-ssl-XXXXXX.sh)
  echo "⚠  Скрипт запущен через пайп — скачиваю во временный файл..."
  if command -v curl &>/dev/null; then
    curl -fsSL "$SCRIPT_URL" -o "$TMPFILE"
  else
    wget -qO "$TMPFILE" "$SCRIPT_URL"
  fi
  chmod +x "$TMPFILE"
  echo "✓  Запускаю: $TMPFILE"
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
  echo "║         🔐  Nginx SSL Certificate Setup             ║"
  echo "║              powered by Let's Encrypt               ║"
  echo "╚══════════════════════════════════════════════════════╝"
  echo -e "${NC}"
}

print_step() { echo -e "\n${BOLD}${GREEN}▶ $1${NC}"; }
print_warn()  { echo -e "${YELLOW}⚠  $1${NC}"; }
print_error() { echo -e "${RED}✗  $1${NC}"; }
print_ok()    { echo -e "${GREEN}✓  $1${NC}"; }

# --- Проверка root ---
check_root() {
  if [[ $EUID -ne 0 ]]; then
    print_error "Этот скрипт нужно запускать от root (или через sudo)."
    exit 1
  fi
}

# --- Определение пакетного менеджера ---


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
      print_warn "Некорректный формат домена. Попробуйте ещё раз (например: example.com)."
    fi
  done

  while true; do
    read -rp "🔌 Порт приложения для redirect (например: 3000, 8080): " APP_PORT
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
  echo -e "  Домен:           ${CYAN}${DOMAIN}${NC}"
  echo -e "  Порт приложения: ${CYAN}${APP_PORT}${NC}"
  echo -e "  Email:           ${CYAN}${LE_EMAIL}${NC}"
  echo "──────────────────────────────────────────────"
  read -rp "Всё верно? [y/N]: " CONFIRM
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Отменено. Запустите скрипт снова."
    exit 0
  fi
}

# --- Установка зависимостей ---
install_dependencies() {
  print_step "Обновление пакетов и установка зависимостей..."
  $PKG_UPDATE

  if ! command -v nginx &>/dev/null; then
    $PKG_INSTALL nginx
    print_ok "Nginx установлен"
  else
    print_ok "Nginx уже установлен"
  fi

  if ! command -v certbot &>/dev/null; then
    if [[ "$PKG_MANAGER" == "apt-get" ]]; then
      $PKG_INSTALL certbot python3-certbot-nginx
    else
      $PKG_INSTALL epel-release
      $PKG_INSTALL certbot python3-certbot-nginx
    fi
    print_ok "Certbot установлен"
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
    print_ok "UFW: открыты порты 80, 443, 22"
  elif command -v firewall-cmd &>/dev/null; then
    firewall-cmd --permanent --add-service=http &>/dev/null || true
    firewall-cmd --permanent --add-service=https &>/dev/null || true
    firewall-cmd --reload &>/dev/null || true
    print_ok "firewalld: открыты порты 80, 443"
  else
    print_warn "Файрвол не обнаружен. Убедитесь, что порты 80 и 443 открыты."
  fi
}

# --- Временный Nginx конфиг для certbot challenge ---
create_temp_nginx_config() {
  print_step "Создание временного Nginx конфига для получения сертификата..."
  mkdir -p /var/www/certbot

  if [[ "$PKG_MANAGER" == "apt-get" ]]; then
    NGINX_TEMP="/etc/nginx/sites-available/${DOMAIN}_temp"
    cat > "${NGINX_TEMP}" <<EOF
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
    rm -f /etc/nginx/sites-enabled/default
    ln -sf "${NGINX_TEMP}" "/etc/nginx/sites-enabled/${DOMAIN}_temp"
  else
    NGINX_TEMP="/etc/nginx/conf.d/${DOMAIN}_temp.conf"
    cat > "${NGINX_TEMP}" <<EOF
server {
    listen 80;
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
  fi

  nginx -t
  systemctl enable nginx
  systemctl restart nginx
  print_ok "Nginx запущен с временным конфигом"
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
    -d "${DOMAIN}"
  print_ok "Сертификат получен для ${DOMAIN}"
}

# --- Финальный Nginx конфиг ---
create_final_nginx_config() {
  print_step "Создание финального Nginx конфига..."

  if [[ "$PKG_MANAGER" == "apt-get" ]]; then
    rm -f "/etc/nginx/sites-enabled/${DOMAIN}_temp"
    rm -f "/etc/nginx/sites-available/${DOMAIN}_temp"
    NGINX_CONF="/etc/nginx/sites-available/${DOMAIN}"
    NGINX_LINK="/etc/nginx/sites-enabled/${DOMAIN}"
  else
    rm -f "/etc/nginx/conf.d/${DOMAIN}_temp.conf"
    NGINX_CONF="/etc/nginx/conf.d/${DOMAIN}.conf"
    NGINX_LINK=""
  fi

  cat > "${NGINX_CONF}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name ${DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;

    location / {
        proxy_pass         http://127.0.0.1:${APP_PORT};
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection 'upgrade';
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF

  [[ -n "$NGINX_LINK" ]] && ln -sf "${NGINX_CONF}" "${NGINX_LINK}"
  print_ok "Финальный конфиг создан"
}

# --- Автообновление ---
setup_auto_renew() {
  print_step "Настройка автоматического обновления сертификата..."
  echo "0 3 * * * root certbot renew --quiet --deploy-hook 'systemctl reload nginx'" \
    > /etc/cron.d/certbot-renew
  chmod 644 /etc/cron.d/certbot-renew
  print_ok "Автообновление настроено (каждый день в 03:00)"
}

# --- Финальный перезапуск ---
final_restart() {
  print_step "Финальная проверка и перезапуск Nginx..."
  nginx -t
  systemctl reload nginx

  echo ""
  echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║           ✅  Установка завершена успешно!           ║${NC}"
  echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  🌐 Сайт:      ${CYAN}https://${DOMAIN}${NC}"
  echo -e "  🔁 Порт:      ${CYAN}${APP_PORT}${NC}"
  echo -e "  📧 Email:     ${CYAN}${LE_EMAIL}${NC}"
  echo -e "  🔄 Обновление: каждый день в 03:00"
  echo ""
  echo -e "  Проверить сертификат: ${YELLOW}certbot certificates${NC}"
  echo -e "  Логи Nginx:           ${YELLOW}journalctl -u nginx -f${NC}"
  echo ""
}

# ==============================================================
#  MAIN
# ==============================================================
print_banner
check_root
detect_package_manager
collect_input
install_dependencies
configure_firewall
create_temp_nginx_config
obtain_certificate
create_final_nginx_config
setup_auto_renew
final_restart
