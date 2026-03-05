#!/bin/bash

# ==============================================================
#  🔐 Nginx + Let's Encrypt SSL Setup Script
#  Автоматическая выдача SSL сертификата через Certbot + Nginx
# ==============================================================

set -e

# --- Цвета для вывода ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

print_banner() {
  echo -e "${CYAN}"
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║         🔐  Nginx SSL Certificate Setup             ║"
  echo "║              powered by Let's Encrypt               ║"
  echo "╚══════════════════════════════════════════════════════╝"
  echo -e "${NC}"
}

print_step() {
  echo -e "\n${BOLD}${GREEN}▶ $1${NC}"
}

print_warn() {
  echo -e "${YELLOW}⚠  $1${NC}"
}

print_error() {
  echo -e "${RED}✗  $1${NC}"
}

print_ok() {
  echo -e "${GREEN}✓  $1${NC}"
}

# --- Проверка root ---
check_root() {
  if [[ $EUID -ne 0 ]]; then
    print_error "Этот скрипт нужно запускать от root (или через sudo)."
    exit 1
  fi
}

# --- Определение пакетного менеджера ---
detect_package_manager() {
  if command -v apt-get &>/dev/null; then
    PKG_MANAGER="apt-get"
    PKG_UPDATE="apt-get update -y"
    PKG_INSTALL="apt-get install -y"
  elif command -v dnf &>/dev/null; then
    PKG_MANAGER="dnf"
    PKG_UPDATE="dnf check-update || true"
    PKG_INSTALL="dnf install -y"
  elif command -v yum &>/dev/null; then
    PKG_MANAGER="yum"
    PKG_UPDATE="yum check-update || true"
    PKG_INSTALL="yum install -y"
  else
    print_error "Неподдерживаемый дистрибутив. Требуется apt, dnf или yum."
    exit 1
  fi
  print_ok "Пакетный менеджер: ${PKG_MANAGER}"
}

# --- Сбор данных от пользователя ---
collect_input() {
  # Фикс для запуска через curl | bash — переподключаем stdin к терминалу
  exec < /dev/tty

  echo ""
  echo -e "${BOLD}Введите параметры для настройки SSL:${NC}"
  echo "──────────────────────────────────────────────"

  # Домен
  while true; do
    read -rp "🌐 Домен (например: example.com): " DOMAIN
    DOMAIN=$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]' | xargs)
    # Простая проверка: есть хотя бы одна точка и нет пробелов
    if [[ -n "$DOMAIN" && "$DOMAIN" == *.* && "$DOMAIN" != *" "* ]]; then
      break
    else
      print_warn "Некорректный формат домена. Попробуйте ещё раз (например: example.com)."
    fi
  done

  # Порт для проксирования
  while true; do
    read -rp "🔌 Порт приложения для redirect (например: 3000, 8080): " APP_PORT
    if [[ "$APP_PORT" =~ ^[0-9]+$ ]] && [ "$APP_PORT" -ge 1 ] && [ "$APP_PORT" -le 65535 ]; then
      break
    else
      print_warn "Некорректный порт. Введите число от 1 до 65535."
    fi
  done

  # Email для Let's Encrypt
  while true; do
    read -rp "📧 Email для Let's Encrypt (уведомления о продлении): " LE_EMAIL
    if [[ -n "$LE_EMAIL" && "$LE_EMAIL" == *@*.* ]]; then
      break
    else
      print_warn "Некорректный email. Попробуйте ещё раз."
    fi
  done

  # Подтверждение
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

  # Nginx
  if ! command -v nginx &>/dev/null; then
    $PKG_INSTALL nginx
    print_ok "Nginx установлен"
  else
    print_ok "Nginx уже установлен"
  fi

  # Certbot
  if ! command -v certbot &>/dev/null; then
    if [[ "$PKG_MANAGER" == "apt-get" ]]; then
      $PKG_INSTALL certbot python3-certbot-nginx
    else
      $PKG_INSTALL certbot python3-certbot-nginx || \
      $PKG_INSTALL epel-release && $PKG_INSTALL certbot python3-certbot-nginx
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
    print_warn "Файрвол не обнаружен. Убедитесь, что порты 80 и 443 открыты вручную."
  fi
}

# --- Создание конфига Nginx ---
create_nginx_config() {
  print_step "Создание конфигурации Nginx для ${DOMAIN}..."

  NGINX_CONF="/etc/nginx/sites-available/${DOMAIN}"
  NGINX_ENABLED="/etc/nginx/sites-enabled/${DOMAIN}"

  # Для RHEL/CentOS используем conf.d
  if [[ "$PKG_MANAGER" != "apt-get" ]]; then
    NGINX_CONF="/etc/nginx/conf.d/${DOMAIN}.conf"
    NGINX_ENABLED=""
  fi

  cat > "${NGINX_CONF}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN} www.${DOMAIN};

    # Let's Encrypt challenge
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    # Редирект HTTP → HTTPS
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name ${DOMAIN} www.${DOMAIN};

    # SSL сертификаты (будут заменены Certbot)
    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    include             /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam         /etc/letsencrypt/ssl-dhparams.pem;

    # Безопасные заголовки
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer-when-downgrade" always;

    # Проксирование на локальное приложение
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

  # Активация конфига (только Debian/Ubuntu)
  if [[ "$PKG_MANAGER" == "apt-get" ]] && [[ ! -L "${NGINX_ENABLED}" ]]; then
    ln -s "${NGINX_CONF}" "${NGINX_ENABLED}"
  fi

  # Удаление default конфига если мешает
  if [[ -L "/etc/nginx/sites-enabled/default" ]]; then
    rm -f /etc/nginx/sites-enabled/default
    print_warn "Удалён default Nginx конфиг"
  fi

  print_ok "Конфиг Nginx создан: ${NGINX_CONF}"
}

# --- Запуск Nginx ---
start_nginx() {
  print_step "Запуск и проверка Nginx..."

  # Временный конфиг только с HTTP для прохождения certbot challenge
  # Убираем блок ssl если сертификатов ещё нет
  TEMP_CONF="/etc/nginx/sites-available/${DOMAIN}_temp"
  if [[ "$PKG_MANAGER" != "apt-get" ]]; then
    TEMP_CONF="/etc/nginx/conf.d/${DOMAIN}_temp.conf"
  fi

  cat > "${TEMP_CONF}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN} www.${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 200 'SSL setup in progress...';
        add_header Content-Type text/plain;
    }
}
EOF

  # Временно используем temp конфиг
  if [[ "$PKG_MANAGER" == "apt-get" ]]; then
    [[ -L "/etc/nginx/sites-enabled/${DOMAIN}" ]] && rm -f "/etc/nginx/sites-enabled/${DOMAIN}"
    ln -s "${TEMP_CONF}" "/etc/nginx/sites-enabled/${DOMAIN}_temp"
  fi

  mkdir -p /var/www/certbot

  nginx -t
  systemctl enable nginx
  systemctl restart nginx
  print_ok "Nginx запущен"
}

# --- Получение SSL сертификата ---
obtain_certificate() {
  print_step "Получение SSL сертификата от Let's Encrypt..."

  certbot certonly \
    --webroot \
    --webroot-path=/var/www/certbot \
    --email "${LE_EMAIL}" \
    --agree-tos \
    --no-eff-email \
    -d "${DOMAIN}" \
    -d "www.${DOMAIN}"

  print_ok "Сертификат получен для ${DOMAIN}"

  # Восстанавливаем основной конфиг
  if [[ "$PKG_MANAGER" == "apt-get" ]]; then
    rm -f "/etc/nginx/sites-enabled/${DOMAIN}_temp"
    rm -f "${TEMP_CONF}"
    [[ ! -L "/etc/nginx/sites-enabled/${DOMAIN}" ]] && \
      ln -s "/etc/nginx/sites-available/${DOMAIN}" "/etc/nginx/sites-enabled/${DOMAIN}"
  else
    rm -f "${TEMP_CONF}"
  fi
}

# --- Настройка автообновления ---
setup_auto_renew() {
  print_step "Настройка автоматического обновления сертификата..."

  CRON_JOB="0 3 * * * certbot renew --quiet --deploy-hook 'systemctl reload nginx'"
  CRON_FILE="/etc/cron.d/certbot-renew"

  echo "${CRON_JOB}" > "${CRON_FILE}"
  chmod 644 "${CRON_FILE}"

  print_ok "Автообновление настроено (ежедневно в 03:00)"
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
  echo -e "  🌐 Сайт доступен по адресу:  ${CYAN}https://${DOMAIN}${NC}"
  echo -e "  🔁 Редирект на порт:          ${CYAN}${APP_PORT}${NC}"
  echo -e "  📧 Email для уведомлений:     ${CYAN}${LE_EMAIL}${NC}"
  echo -e "  🔄 Автообновление:            ${CYAN}каждый день в 03:00${NC}"
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
create_nginx_config
start_nginx
obtain_certificate
setup_auto_renew
final_restart
