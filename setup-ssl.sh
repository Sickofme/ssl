#!/bin/bash
# ==============================================================
# 🔐 Nginx + Let's Encrypt SSL Setup Script
# Автоматическая выдача SSL сертификата через Certbot + Nginx
# ==============================================================

# --- Запуск через пайп (curl | bash): скачиваем в файл и перезапускаем с терминалом ---
if [ ! -t 0 ]; then
  SCRIPT_URL="https://raw.githubusercontent.com/sickofme/ssl/main/setup-ssl.sh"
  if ! { : </dev/tty; } 2>/dev/null; then
    echo "✗ Нет доступа к терминалу (/dev/tty). Скачайте скрипт и запустите: sudo bash setup-ssl.sh" >&2
    exit 1
  fi
  TMPFILE=$(mktemp /tmp/setup-ssl-XXXXXX.sh)
  echo "⚠ Скрипт запущен через пайп — скачиваю во временный файл..."
  if command -v curl &>/dev/null; then
    curl -fsSL "$SCRIPT_URL" -o "$TMPFILE" || { echo "✗ Не удалось скачать скрипт" >&2; exit 1; }
  else
    wget -qO "$TMPFILE" "$SCRIPT_URL" || { echo "✗ Не удалось скачать скрипт" >&2; exit 1; }
  fi
  echo "✓ Запускаю: $TMPFILE"
  # stdin переключаем на терминал, иначе проверка выше сработает снова (бесконечный цикл)
  exec bash "$TMPFILE" </dev/tty
fi

set -euo pipefail

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

DOMAIN_RE='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9-]{2,63}$'
EMAIL_RE='^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'

TEMP_CONF=""

# --- Уборка временного конфига, если что-то пошло не так ---
cleanup_on_error() {
  local rc=$?
  if [[ $rc -ne 0 && -n "$TEMP_CONF" && -f "$TEMP_CONF" ]]; then
    print_warn "Ошибка — удаляю временный конфиг ${TEMP_CONF}"
    rm -f "$TEMP_CONF"
    nginx -t &>/dev/null && systemctl reload nginx &>/dev/null || true
  fi
}
trap cleanup_on_error EXIT

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
  elif command -v dnf &>/dev/null; then
    PKG_MANAGER="dnf"
  elif command -v yum &>/dev/null; then
    PKG_MANAGER="yum"
  else
    print_error "Поддерживаются только apt-get, dnf и yum."
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
    if [[ "$DOMAIN" =~ $DOMAIN_RE ]]; then
      break
    else
      print_warn "Некорректный формат домена. Попробуйте ещё раз."
    fi
  done

  read -rp "➕ Добавить также www.${DOMAIN}? (нужна DNS-запись для www) [y/N]: " ADD_WWW
  if [[ "$ADD_WWW" =~ ^[Yy]$ ]]; then
    SERVER_NAMES="${DOMAIN} www.${DOMAIN}"
  else
    SERVER_NAMES="${DOMAIN}"
  fi

  while true; do
    read -rp "🔌 Порт приложения (например: 3000): " APP_PORT
    if [[ "$APP_PORT" =~ ^[0-9]+$ ]] && (( APP_PORT >= 1 && APP_PORT <= 65535 )); then
      break
    else
      print_warn "Некорректный порт. Введите число от 1 до 65535."
    fi
  done

  while true; do
    read -rp "📧 Email для Let's Encrypt: " LE_EMAIL
    if [[ "$LE_EMAIL" =~ $EMAIL_RE ]]; then
      break
    else
      print_warn "Некорректный email. Попробуйте ещё раз."
    fi
  done

  echo ""
  echo -e "${BOLD}Проверьте введённые данные:${NC}"
  echo "──────────────────────────────────────────────"
  echo -e " Домен(ы): ${CYAN}${SERVER_NAMES}${NC}"
  echo -e " Порт приложения: ${CYAN}${APP_PORT}${NC}"
  echo -e " Email: ${CYAN}${LE_EMAIL}${NC}"
  echo "──────────────────────────────────────────────"
  read -rp "Всё верно? [y/N]: " CONFIRM
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Отменено. Запустите скрипт снова."
    exit 0
  fi
}

# --- Official nginx.org repo (stable), so apt/dnf upgrade keeps nginx up to date ---
setup_nginx_repo() {
  local os_id="" codename="" key_url="https://nginx.org/keys/nginx_signing.key"
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    os_id="$(. /etc/os-release && echo "${ID:-}")"
    codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
  fi

  if [[ "${PKG_MANAGER}" == "apt-get" ]]; then
    if grep -rqs 'nginx.org/packages' /etc/apt/sources.list /etc/apt/sources.list.d/; then
      echo "   nginx.org repo already configured"
      return
    fi
    if [[ "${os_id}" != "ubuntu" && "${os_id}" != "debian" ]] || [[ -z "${codename}" ]]; then
      echo "   ${os_id:-unknown} is not supported by nginx.org - using distro nginx"
      return
    fi
    apt-get install -y curl gnupg2 ca-certificates >/dev/null
    curl -fsSL "${key_url}" | gpg --dearmor --yes -o /usr/share/keyrings/nginx-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/${os_id} ${codename} nginx" \
      > /etc/apt/sources.list.d/nginx.list
    # prefer nginx.org packages over the distro ones
    printf 'Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n' \
      > /etc/apt/preferences.d/99nginx
    if ! apt-get update -y >/dev/null 2>&1 || ! apt-cache policy nginx | grep -q 'nginx.org'; then
      echo "   nginx.org has no packages for ${os_id} ${codename} - reverting to distro nginx"
      rm -f /etc/apt/sources.list.d/nginx.list /etc/apt/preferences.d/99nginx
      apt-get update -y >/dev/null 2>&1 || true
      return
    fi
  else
    if ls /etc/yum.repos.d/ 2>/dev/null | grep -q '^nginx'; then
      echo "   nginx.org repo already configured"
      return
    fi
    local family="centos"
    [[ "${os_id}" == "rhel" ]] && family="rhel"
    if [[ "${os_id}" != "centos" && "${os_id}" != "rhel" && "${os_id}" != "rocky" && "${os_id}" != "almalinux" ]]; then
      echo "   ${os_id:-unknown} is not supported by nginx.org - using distro nginx"
      return
    fi
    cat > /etc/yum.repos.d/nginx.repo <<REPO
[nginx-stable]
name=nginx stable repo
baseurl=http://nginx.org/packages/${family}/\$releasever/\$basearch/
gpgcheck=1
enabled=1
gpgkey=${key_url}
module_hotfixes=true
REPO
  fi
  echo "   nginx.org stable repo added"
}

# --- Установка зависимостей ---
install_dependencies() {
  print_step "Проверка и установка зависимостей..."

  if [[ "$PKG_MANAGER" == "apt-get" ]]; then
    apt-get update -y >/dev/null 2>&1 || true
  fi

  if ! command -v nginx &>/dev/null; then
    setup_nginx_repo
    "$PKG_MANAGER" install -y nginx
    print_ok "Nginx установлен"
  else
    print_ok "Nginx уже установлен"
  fi

  if ! command -v certbot &>/dev/null; then
    if [[ "$PKG_MANAGER" != "apt-get" ]]; then
      "$PKG_MANAGER" install -y epel-release >/dev/null 2>&1 || true
    fi
    "$PKG_MANAGER" install -y certbot
    print_ok "Certbot установлен"
  else
    print_ok "Certbot уже установлен"
  fi

  systemctl enable nginx &>/dev/null || true
  systemctl start nginx &>/dev/null || true
}

# --- Настройка файрвола ---
configure_firewall() {
  print_step "Настройка файрвола..."
  if command -v ufw &>/dev/null; then
    ufw allow 22/tcp &>/dev/null || true
    ufw allow 80/tcp &>/dev/null || true
    ufw allow 443/tcp &>/dev/null || true
    print_ok "UFW: порты 22, 80 и 443 разрешены"
  elif command -v firewall-cmd &>/dev/null; then
    firewall-cmd --permanent --add-service=ssh &>/dev/null || true
    firewall-cmd --permanent --add-service=http &>/dev/null || true
    firewall-cmd --permanent --add-service=https &>/dev/null || true
    firewall-cmd --reload &>/dev/null || true
    print_ok "firewalld: ssh, http и https разрешены"
  else
    print_warn "Файрвол не обнаружен. Убедитесь, что порты 80 и 443 открыты."
  fi
}

# --- Синтаксис HTTP/2 зависит от версии nginx (1.25.1+: директива http2 on) ---
detect_http2_syntax() {
  local ver
  ver=$(nginx -v 2>&1 | sed -n 's|.*nginx/\([0-9.]*\).*|\1|p')
  if [[ -n "$ver" && "$(printf '%s\n' 1.25.1 "$ver" | sort -V | head -n1)" == "1.25.1" ]]; then
    LISTEN_HTTP2=""
    HTTP2_DIRECTIVE="    http2 on;"
  else
    LISTEN_HTTP2=" http2"
    HTTP2_DIRECTIVE=""
  fi
}

# --- Временный Nginx конфиг для certbot ---
create_temp_nginx_config() {
  print_step "Создание временного Nginx конфига для получения сертификата..."

  mkdir -p /var/www/certbot
  TEMP_CONF="/etc/nginx/conf.d/${DOMAIN}_temp.conf"

  cat > "$TEMP_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${SERVER_NAMES};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 200 'SSL setup in progress...';
        add_header Content-Type text/plain;
    }
}
EOF

  nginx -t
  systemctl reload nginx || systemctl restart nginx
  print_ok "Временный конфиг применён"
}

# --- Получение сертификата ---
obtain_certificate() {
  print_step "Получение SSL сертификата от Let's Encrypt..."
  local domain_args=()
  local d
  for d in $SERVER_NAMES; do domain_args+=(-d "$d"); done

  certbot certonly \
    --webroot \
    --webroot-path /var/www/certbot \
    --email "${LE_EMAIL}" \
    --agree-tos \
    --no-eff-email \
    --non-interactive \
    --cert-name "${DOMAIN}" \
    "${domain_args[@]}"

  print_ok "Сертификат успешно получен для ${SERVER_NAMES}"
}

# --- Финальный Nginx конфиг ---
create_final_nginx_config() {
  print_step "Создание финального Nginx конфига..."

  local final_conf="/etc/nginx/conf.d/${DOMAIN}.conf"
  if [[ -f "$final_conf" ]]; then
    cp -a "$final_conf" "${final_conf}.bak.$(date +%Y%m%d%H%M%S)"
    print_warn "Существующий конфиг сохранён в ${final_conf}.bak.*"
  fi

  # map для WebSocket (Connection: upgrade только когда клиент его запросил)
  cat > /etc/nginx/conf.d/00-ssl-setup-websocket-map.conf <<'EOF'
map $http_upgrade $ssl_setup_connection_upgrade {
    default upgrade;
    ''      close;
}
EOF

  cat > "$final_conf" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${SERVER_NAMES};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl${LISTEN_HTTP2};
    listen [::]:443 ssl${LISTEN_HTTP2};
${HTTP2_DIRECTIVE}
    server_name ${SERVER_NAMES};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;

    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    # HSTS только для этого домена (без includeSubDomains/preload, чтобы не сломать поддомены)
    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;

    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$ssl_setup_connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
}
EOF

  rm -f "$TEMP_CONF"
  TEMP_CONF=""
  print_ok "Финальный конфиг Nginx создан: ${final_conf}"
}

# --- Автообновление сертификатов ---
setup_auto_renew() {
  print_step "Настройка автоматического обновления сертификата..."

  # deploy-hook срабатывает при любом способе продления (systemd timer или cron)
  mkdir -p /etc/letsencrypt/renewal-hooks/deploy
  cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'EOF'
#!/bin/sh
systemctl reload nginx
EOF
  chmod 755 /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

  if systemctl list-timers --all 2>/dev/null | grep -q certbot || [[ -f /etc/cron.d/certbot ]]; then
    print_ok "Используется штатный таймер certbot; добавлен хук перезагрузки nginx"
  else
    cat > /etc/cron.d/certbot-renew <<'EOF'
0 3 * * * root certbot renew --quiet
EOF
    chmod 644 /etc/cron.d/certbot-renew
    print_ok "Автообновление настроено через cron (ежедневно в 03:00)"
  fi
}

# --- Финальный перезапуск ---
final_restart() {
  print_step "Финальная проверка и перезапуск Nginx..."
  nginx -t
  systemctl reload nginx

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
detect_package_manager
install_dependencies
collect_input
configure_firewall
detect_http2_syntax
create_temp_nginx_config
obtain_certificate
create_final_nginx_config
setup_auto_renew
final_restart
