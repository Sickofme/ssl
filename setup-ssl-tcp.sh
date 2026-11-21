#!/bin/bash

# ==============================================================
#  Nginx + Let's Encrypt loopback TLS backend setup
#  Creates a local HTTPS nginx listener (127.0.0.1:<port>)
#  while leaving public :443 free for another frontend service.
# ==============================================================

# --- Started via pipe (curl | bash): download to a file and re-run with a terminal ---
if [ ! -t 0 ]; then
  SCRIPT_URL="https://raw.githubusercontent.com/sickofme/ssl/main/setup-ssl-tcp.sh"
  if ! { : </dev/tty; } 2>/dev/null; then
    echo "XX No terminal (/dev/tty). Download the script and run: sudo bash setup-ssl-tcp.sh" >&2
    exit 1
  fi
  TMPFILE=$(mktemp /tmp/setup-ssl-tcp-XXXXXX.sh)
  echo "!! Started via pipe - downloading to a temp file..."
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$SCRIPT_URL" -o "$TMPFILE" || { echo "XX Download failed" >&2; exit 1; }
  else
    wget -qO "$TMPFILE" "$SCRIPT_URL" || { echo "XX Download failed" >&2; exit 1; }
  fi
  exec bash "$TMPFILE" </dev/tty
fi

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

DOMAIN_RE='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9-]{2,63}$'
EMAIL_RE='^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
HOST_RE='^([A-Za-z0-9.-]+|\[[0-9A-Fa-f:]+\])$'
PATH_RE='^/[A-Za-z0-9._/-]*$'

DOMAIN="" LE_EMAIL="" LOCAL_TLS_PORT="" SITE_MODE=""
APP_HOST="" APP_PORT="" STATIC_ROOT="" USE_PROXY_PROTOCOL="no"
TEMP_CONF="" TEMP_LINK=""

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

cleanup_on_error() {
  local rc=$?
  if [[ $rc -ne 0 && -n "${TEMP_CONF}" && -f "${TEMP_CONF}" ]]; then
    print_warn "Failed - removing temporary config ${TEMP_CONF}"
    rm -f "${TEMP_CONF}"
    [[ -n "${TEMP_LINK}" ]] && rm -f "${TEMP_LINK}"
    nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
  fi
}
trap cleanup_on_error EXIT

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
    PKG_UPDATE=(dnf -y makecache)
    PKG_INSTALL=(dnf install -y)
    NGINX_STYLE="rhel"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
    PKG_UPDATE=(yum -y makecache)
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
    if [[ "${DOMAIN}" =~ ${DOMAIN_RE} ]]; then
      break
    fi
    print_warn "Invalid domain."
  done
}

prompt_email() {
  while true; do
    read -rp "Let's Encrypt email: " LE_EMAIL
    if [[ "${LE_EMAIL}" =~ ${EMAIL_RE} ]]; then
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

prompt_proxy_protocol() {
  echo "  If your frontend (xray/haproxy/...) sends PROXY protocol, nginx can see real client IPs."
  read -rp "Frontend sends PROXY protocol? [y/N]: " ans
  if [[ "${ans}" =~ ^[Yy]$ ]]; then
    USE_PROXY_PROTOCOL="yes"
  fi
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
    if [[ "${APP_HOST}" =~ ${HOST_RE} ]]; then
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
    if [[ ! "${STATIC_ROOT}" =~ ${PATH_RE} ]]; then
      print_warn "Use an absolute path with letters, digits, . _ - / only."
    elif [[ ! -d "${STATIC_ROOT}" ]]; then
      print_warn "Directory does not exist."
    else
      break
    fi
  done
}

confirm_settings() {
  echo ""
  echo -e "${BOLD}Review:${NC}"
  echo "  Domain:           ${DOMAIN}"
  echo "  Email:            ${LE_EMAIL}"
  echo "  Local TLS port:   ${LOCAL_TLS_PORT}"
  echo "  PROXY protocol:   ${USE_PROXY_PROTOCOL}"
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

install_dependencies() {
  print_step "Installing dependencies"
  "${PKG_UPDATE[@]}" >/dev/null 2>&1 || true

  if ! command -v nginx >/dev/null 2>&1; then
    setup_nginx_repo
    "${PKG_INSTALL[@]}" nginx
    print_ok "nginx installed"
  else
    print_ok "nginx already installed"
  fi

  if ! command -v certbot >/dev/null 2>&1; then
    if [[ "${PKG_MANAGER}" != "apt-get" ]]; then
      "${PKG_INSTALL[@]}" epel-release >/dev/null 2>&1 || true
    fi
    # webroot mode only - the certbot nginx plugin is not needed
    "${PKG_INSTALL[@]}" certbot
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

# nginx 1.25.1+ uses "http2 on;", older versions use "listen ... http2"
detect_http2_syntax() {
  local ver
  ver="$(nginx -v 2>&1 | sed -n 's|.*nginx/\([0-9.]*\).*|\1|p')"
  if [[ -n "${ver}" && "$(printf '%s\n' 1.25.1 "${ver}" | sort -V | head -n1)" == "1.25.1" ]]; then
    LISTEN_HTTP2=""
    HTTP2_DIRECTIVE="    http2 on;"
  else
    LISTEN_HTTP2=" http2"
    HTTP2_DIRECTIVE=""
  fi
}

set_nginx_paths() {
  if [[ "${NGINX_STYLE}" == "debian" && -d /etc/nginx/sites-enabled ]]; then
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
    --non-interactive \
    --cert-name "${DOMAIN}" \
    -d "${DOMAIN}"
  print_ok "Certificate issued for ${DOMAIN}"
}

build_proxy_location() {
  local real_ip_var='$remote_addr'
  local xff_var='$proxy_add_x_forwarded_for'
  if [[ "${USE_PROXY_PROTOCOL}" == "yes" ]]; then
    real_ip_var='$proxy_protocol_addr'
    xff_var='$proxy_protocol_addr'
  fi
  cat <<EOF
    location / {
        proxy_pass http://${APP_HOST}:${APP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP ${real_ip_var};
        proxy_set_header X-Forwarded-For ${xff_var};
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$ssl_setup_connection_upgrade;
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

  local listen_opts="ssl${LISTEN_HTTP2}"
  local real_ip_block=""
  if [[ "${USE_PROXY_PROTOCOL}" == "yes" ]]; then
    listen_opts="${listen_opts} proxy_protocol"
    real_ip_block="    set_real_ip_from 127.0.0.1;
    real_ip_header proxy_protocol;"
  fi

  if [[ "${SITE_MODE}" == "proxy" ]]; then
    SITE_BLOCK="$(build_proxy_location)"
  else
    SITE_BLOCK="$(build_static_location)"
  fi

  if [[ -f "${FINAL_CONF}" ]]; then
    cp -a "${FINAL_CONF}" "${FINAL_CONF}.bak.$(date +%Y%m%d%H%M%S)"
    print_warn "Existing config backed up to ${FINAL_CONF}.bak.*"
  fi

  # WebSocket-aware Connection header (map must live in http context -> conf.d)
  cat > /etc/nginx/conf.d/00-ssl-setup-websocket-map.conf <<'EOF'
map $http_upgrade $ssl_setup_connection_upgrade {
    default upgrade;
    ''      close;
}
EOF

  cat > "${FINAL_CONF}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    # Redirects to public :443, which is served by your frontend service
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 127.0.0.1:${LOCAL_TLS_PORT} ${listen_opts};
${HTTP2_DIRECTIVE}
    server_name ${DOMAIN};
${real_ip_block}

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_prefer_server_ciphers off;

${SITE_BLOCK}
}
EOF

  rm -f "${TEMP_CONF}"
  if [[ -n "${TEMP_LINK}" ]]; then
    rm -f "${TEMP_LINK}"
  fi
  TEMP_CONF="" TEMP_LINK=""

  if [[ -n "${FINAL_LINK}" ]]; then
    ln -sf "${FINAL_CONF}" "${FINAL_LINK}"
  fi

  nginx -t
  systemctl reload nginx
  print_ok "Final nginx config enabled"
}

setup_auto_renew() {
  print_step "Configuring automatic renewal"

  # deploy hook runs for every renewal method (systemd timer or cron)
  mkdir -p /etc/letsencrypt/renewal-hooks/deploy
  cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'EOF'
#!/bin/sh
systemctl reload nginx
EOF
  chmod 755 /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

  if systemctl list-timers --all 2>/dev/null | grep -q certbot || [[ -f /etc/cron.d/certbot ]]; then
    print_ok "Using the distro certbot timer; nginx reload hook installed"
  else
    cat > /etc/cron.d/certbot-renew <<'EOF'
0 3 * * * root certbot renew --quiet
EOF
    chmod 644 /etc/cron.d/certbot-renew
    print_ok "Auto-renew configured via cron (daily 03:00)"
  fi
}

print_summary() {
  echo ""
  echo -e "${GREEN}Setup completed.${NC}"
  echo "  Domain:          ${DOMAIN}"
  echo "  Public HTTP:     80 (ACME + redirect to https://)"
  echo "  Local HTTPS:     127.0.0.1:${LOCAL_TLS_PORT}"
  echo "  PROXY protocol:  ${USE_PROXY_PROTOCOL}"
  if [[ "${SITE_MODE}" == "proxy" ]]; then
    echo "  Upstream:        ${APP_HOST}:${APP_PORT}"
  else
    echo "  Static root:     ${STATIC_ROOT}"
  fi
  echo "  nginx config:    ${FINAL_CONF}"
  echo ""
  echo "Notes:"
  echo "  - Public :443 remains free for your frontend service."
  echo "  - HTTP :80 redirects to https://${DOMAIN} - your frontend on :443 must serve or forward it."
  echo "  - Point your frontend to 127.0.0.1:${LOCAL_TLS_PORT} as the local TLS backend."
  if [[ "${USE_PROXY_PROTOCOL}" == "yes" ]]; then
    echo "  - nginx now REQUIRES PROXY protocol on 127.0.0.1:${LOCAL_TLS_PORT}; plain TLS connections will fail."
  fi
}

print_banner
check_root
detect_package_manager
install_dependencies
prompt_domain
prompt_email
prompt_loopback_port
prompt_proxy_protocol
prompt_site_mode
prompt_proxy_target
prompt_static_root
confirm_settings
configure_firewall
detect_http2_syntax
create_temp_nginx_config
obtain_certificate
create_final_nginx_config
setup_auto_renew
print_summary
