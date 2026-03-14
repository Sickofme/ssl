#!/bin/bash

# ==============================================================
#  Nginx + Let's Encrypt loopback TLS backend setup
#  Creates a local HTTPS nginx listener (127.0.0.1:<port>)
#  while leaving public :443 free for another frontend service.
# ==============================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

print_banner() {
  echo -e "${CYAN}"
  echo "============================================================"
  echo "  Nginx local TLS backend setup"
  echo "  Let's Encrypt + loopback HTTPS listener"
  echo "============================================================"
  echo -e "${NC}"
}

print_step()  { echo -e "\n${BOLD}${GREEN}>> $1${NC}"; }
print_warn()  { echo -e "${YELLOW}!! $1${NC}"; }
print_error() { echo -e "${RED}XX $1${NC}"; }
print_ok()    { echo -e "${GREEN}OK $1${NC}"; }

check_root() {
  if [[ ${EUID:-0} -ne 0 ]]; then
    print_error "Run this script as root or with sudo."
    exit 1
  fi
}

detect_package_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt-get"
    PKG_UPDATE=(apt-get update -y)
    PKG_INSTALL=(apt-get install -y)
    NGINX_STYLE="debian"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
    PKG_UPDATE=(dnf -y check-update)
    PKG_INSTALL=(dnf install -y)
    NGINX_STYLE="rhel"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
    PKG_UPDATE=(yum -y check-update)
    PKG_INSTALL=(yum install -y)
    NGINX_STYLE="rhel"
  else
    print_error "Supported package managers: apt-get, dnf, yum."
    exit 1
  fi
  print_ok "Package manager: ${PKG_MANAGER}"
}

prompt_domain() {
  while true; do
    read -rp "Domain (example.com): " DOMAIN
    DOMAIN="$(echo "${DOMAIN}" | tr '[:upper:]' '[:lower:]' | xargs)"
    if [[ -n "${DOMAIN}" && "${DOMAIN}" == *.* && "${DOMAIN}" != *" "* ]]; then
      break
    fi
    print_warn "Invalid domain."
  done
}

prompt_email() {
  while true; do
    read -rp "Let's Encrypt email: " LE_EMAIL
    if [[ -n "${LE_EMAIL}" && "${LE_EMAIL}" == *@*.* ]]; then
      break
    fi
    print_warn "Invalid email."
  done
}

prompt_loopback_port() {
  while true; do
    read -rp "Local HTTPS nginx port [8443]: " LOCAL_TLS_PORT
    LOCAL_TLS_PORT="${LOCAL_TLS_PORT:-8443}"
    if [[ "${LOCAL_TLS_PORT}" =~ ^[0-9]+$ ]] && (( LOCAL_TLS_PORT >= 1 && LOCAL_TLS_PORT <= 65535 )); then
      break
    fi
    print_warn "Port must be between 1 and 65535."
  done
}

prompt_site_mode() {
  while true; do
    read -rp "Mode: proxy to local app or static files? [proxy/static]: " SITE_MODE
    SITE_MODE="$(echo "${SITE_MODE}" | tr '[:upper:]' '[:lower:]' | xargs)"
    if [[ "${SITE_MODE}" == "proxy" || "${SITE_MODE}" == "static" ]]; then
      break
    fi
    print_warn "Enter proxy or static."
  done
}

prompt_proxy_target() {
  if [[ "${SITE_MODE}" != "proxy" ]]; then
    return
  fi

  while true; do
    read -rp "Local upstream host [127.0.0.1]: " APP_HOST
    APP_HOST="${APP_HOST:-127.0.0.1}"
    if [[ -n "${APP_HOST}" && "${APP_HOST}" != *" "* ]]; then
      break
    fi
    print_warn "Invalid host."
  done

  while true; do
    read -rp "Local upstream port [3000]: " APP_PORT
    APP_PORT="${APP_PORT:-3000}"
    if [[ "${APP_PORT}" =~ ^[0-9]+$ ]] && (( APP_PORT >= 1 && APP_PORT <= 65535 )); then
      break
    fi
    print_warn "Port must be between 1 and 65535."
  done
}

prompt_static_root() {
  if [[ "${SITE_MODE}" != "static" ]]; then
    return
  fi

  while true; do
    read -rp "Static root [/var/www/html]: " STATIC_ROOT
    STATIC_ROOT="${STATIC_ROOT:-/var/www/html}"
    if [[ -d "${STATIC_ROOT}" ]]; then
      break
    fi
    print_warn "Directory does not exist."
  done
}

confirm_settings() {
  echo ""
  echo -e "${BOLD}Review:${NC}"
  echo "  Domain:           ${DOMAIN}"
  echo "  Email:            ${LE_EMAIL}"
  echo "  Local TLS port:   ${LOCAL_TLS_PORT}"
  echo "  Mode:             ${SITE_MODE}"
  if [[ "${SITE_MODE}" == "proxy" ]]; then
    echo "  Upstream:         ${APP_HOST}:${APP_PORT}"
  else
    echo "  Static root:      ${STATIC_ROOT}"
  fi
  echo ""
  read -rp "Continue? [y/N]: " CONFIRM
  if [[ ! "${CONFIRM}" =~ ^[Yy]$ ]]; then
    print_warn "Cancelled."
    exit 0
  fi
}

install_dependencies() {
  print_step "Installing dependencies"
  "${PKG_UPDATE[@]}" >/dev/null 2>&1 || true

  if ! command -v nginx >/dev/null 2>&1; then
    "${PKG_INSTALL[@]}" nginx
    print_ok "nginx installed"
  else
    print_ok "nginx already installed"
  fi

  if ! command -v certbot >/dev/null 2>&1; then
    if [[ "${PKG_MANAGER}" == "apt-get" ]]; then
      "${PKG_INSTALL[@]}" certbot python3-certbot-nginx
    else
      "${PKG_INSTALL[@]}" epel-release || true
      "${PKG_INSTALL[@]}" certbot python3-certbot-nginx
    fi
    print_ok "certbot installed"
  else
    print_ok "certbot already installed"
  fi
}

configure_firewall() {
  print_step "Opening firewall for HTTP challenge"
  if command -v ufw >/dev/null 2>&1; then
    ufw allow 80/tcp >/dev/null 2>&1 || true
    print_ok "ufw: opened 80/tcp"
  elif command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --permanent --add-service=http >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    print_ok "firewalld: opened HTTP"
  else
    print_warn "No supported firewall tool detected. Ensure port 80 is reachable."
  fi
}

set_nginx_paths() {
  if [[ "${NGINX_STYLE}" == "debian" ]]; then
    TEMP_CONF="/etc/nginx/sites-available/${DOMAIN}_acme"
    TEMP_LINK="/etc/nginx/sites-enabled/${DOMAIN}_acme"
    FINAL_CONF="/etc/nginx/sites-available/${DOMAIN}_loopback_tls"
    FINAL_LINK="/etc/nginx/sites-enabled/${DOMAIN}_loopback_tls"
  else
    TEMP_CONF="/etc/nginx/conf.d/${DOMAIN}_acme.conf"
    TEMP_LINK=""
    FINAL_CONF="/etc/nginx/conf.d/${DOMAIN}_loopback_tls.conf"
    FINAL_LINK=""
  fi
}

create_temp_nginx_config() {
  print_step "Creating temporary nginx config for ACME"
  mkdir -p /var/www/certbot
  set_nginx_paths

  cat > "${TEMP_CONF}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 200 'Certificate setup in progress';
        add_header Content-Type text/plain;
    }
}
EOF

  if [[ -n "${TEMP_LINK}" ]]; then
    rm -f /etc/nginx/sites-enabled/default
    ln -sf "${TEMP_CONF}" "${TEMP_LINK}"
  fi

  nginx -t
  systemctl enable nginx >/dev/null 2>&1 || true
  systemctl restart nginx
  print_ok "Temporary nginx config enabled"
}

obtain_certificate() {
  print_step "Obtaining Let's Encrypt certificate"
  certbot certonly \
    --webroot \
    --webroot-path /var/www/certbot \
    --email "${LE_EMAIL}" \
    --agree-tos \
    --no-eff-email \
    -d "${DOMAIN}"
  print_ok "Certificate issued for ${DOMAIN}"
}

build_proxy_location() {
  cat <<EOF
    location / {
        proxy_pass http://${APP_HOST}:${APP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 300s;
    }
EOF
}

build_static_location() {
  cat <<EOF
    root ${STATIC_ROOT};
    index index.html index.htm;

    location / {
        try_files \$uri \$uri/ =404;
    }
EOF
}

create_final_nginx_config() {
  print_step "Creating final nginx config"

  rm -f "${TEMP_CONF}"
  if [[ -n "${TEMP_LINK}" ]]; then
    rm -f "${TEMP_LINK}"
  fi

  if [[ "${SITE_MODE}" == "proxy" ]]; then
    SITE_BLOCK="$(build_proxy_location)"
  else
    SITE_BLOCK="$(build_static_location)"
  fi

  cat > "${FINAL_CONF}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 127.0.0.1:${LOCAL_TLS_PORT} ssl http2;
    server_name ${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_prefer_server_ciphers off;

${SITE_BLOCK}
}
EOF

  if [[ -n "${FINAL_LINK}" ]]; then
    ln -sf "${FINAL_CONF}" "${FINAL_LINK}"
  fi

  nginx -t
  systemctl reload nginx
  print_ok "Final nginx config enabled"
}

setup_auto_renew() {
  print_step "Configuring automatic renewal"
  cat > /etc/cron.d/certbot-renew <<'EOF'
0 3 * * * root certbot renew --quiet --deploy-hook 'systemctl reload nginx'
EOF
  chmod 644 /etc/cron.d/certbot-renew
  print_ok "Auto-renew configured"
}

print_summary() {
  echo ""
  echo -e "${GREEN}Setup completed.${NC}"
  echo "  Domain:          ${DOMAIN}"
  echo "  Public HTTP:     80 (ACME + redirect)"
  echo "  Local HTTPS:     127.0.0.1:${LOCAL_TLS_PORT}"
  if [[ "${SITE_MODE}" == "proxy" ]]; then
    echo "  Upstream:        ${APP_HOST}:${APP_PORT}"
  else
    echo "  Static root:     ${STATIC_ROOT}"
  fi
  echo "  nginx config:    ${FINAL_CONF}"
  echo ""
  echo "Notes:"
  echo "  - Public :443 remains free for your frontend service."
  echo "  - This script only prepares nginx and certificates."
  echo "  - If your frontend forwards HTTPS traffic to nginx, use 127.0.0.1:${LOCAL_TLS_PORT} as the local TLS backend."
}

print_banner
check_root
detect_package_manager
prompt_domain
prompt_email
prompt_loopback_port
prompt_site_mode
prompt_proxy_target
prompt_static_root
confirm_settings
install_dependencies
configure_firewall
create_temp_nginx_config
obtain_certificate
create_final_nginx_config
setup_auto_renew
print_summary
