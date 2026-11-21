# 🔐 Nginx SSL Setup

Bash-скрипт для автоматической настройки Nginx и выдачи SSL сертификата через Let's Encrypt (Certbot).

## ✨ Что делает скрипт

- Устанавливает **Nginx** из официального репозитория **nginx.org** (stable) и **Certbot**, если они не установлены — дальше nginx обновляется обычным `apt upgrade` / `dnf upgrade`
- Открывает порты **80, 443, 22** в файрволе (UFW / firewalld)
- Создаёт конфиг Nginx с редиректом HTTP → HTTPS (опционально добавляет `www.`)
- Получает SSL сертификат от **Let's Encrypt**
- Настраивает **проксирование** запросов на порт твоего приложения
- Настраивает **автообновление**: использует штатный таймер certbot (или cron в 03:00) и хук перезагрузки nginx

## 📋 Требования

- Ubuntu / Debian / CentOS / RHEL
- Запуск от **root** или через **sudo**
- Домен должен иметь **A-запись в DNS**, указывающую на IP сервера
- Порты **80 и 443** должны быть доступны из интернета

## 🚀 Установка

```bash
curl -fsSL https://raw.githubusercontent.com/sickofme/ssl/main/setup-ssl.sh -o setup-ssl.sh && sudo bash setup-ssl.sh
```

```bash
curl -fsSL https://raw.githubusercontent.com/sickofme/ssl/main/setup-ssl-tcp.sh -o setup-ssl-tcp.sh && sudo bash setup-ssl-tcp.sh
```

`setup-ssl-tcp.sh` — вариант, когда публичный 443 занят другим сервисом (xray/Reality, haproxy и т.п.): nginx слушает TLS только на `127.0.0.1:<порт>` (по умолчанию 8443), опционально с PROXY protocol, и умеет проксировать на приложение или отдавать статику.

`setup-ssl.sh` задаст вопросы:

| Параметр | Пример | Описание |
|---|---|---|
| Домен | `example.com` | Домен для которого выпускается сертификат |
| www | `y/N` | Добавить ли `www.<домен>` в сертификат |
| Порт | `3000` | Порт локального приложения для проксирования |
| Email | `you@example.com` | Email для уведомлений о продлении сертификата |

## 📁 Что создаётся

```
setup-ssl.sh:
/etc/nginx/conf.d/<домен>.conf                      — конфиг Nginx
setup-ssl-tcp.sh:
/etc/nginx/sites-available/<домен>_loopback_tls     — Debian/Ubuntu
/etc/nginx/conf.d/<домен>_loopback_tls.conf         — CentOS/RHEL
общее:
/etc/nginx/conf.d/00-ssl-setup-websocket-map.conf   — map для WebSocket
/etc/letsencrypt/live/<домен>/                      — SSL сертификат
/var/www/certbot/                                   — директория для ACME challenge
/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh — reload nginx после продления
/etc/cron.d/certbot-renew                           — только если нет штатного таймера certbot
```

## 🔄 Схема работы

```
Интернет
   │
   ├── HTTP  :80  ──→  редирект на HTTPS
   │
   └── HTTPS :443 ──→  Nginx (SSL termination)
                           │
                           └── proxy_pass → 127.0.0.1:<порт>
                                               │
                                            Твоё приложение
```

## 🛠 Полезные команды

```bash
# Проверить статус сертификата
sudo certbot certificates

# Проверить автообновление
sudo certbot renew --dry-run

# Логи Nginx
sudo journalctl -u nginx -f

# Перезапустить Nginx
sudo systemctl reload nginx
```

## 🐧 Поддерживаемые дистрибутивы

| Дистрибутив | Пакетный менеджер | Статус |
|---|---|---|
| Ubuntu 20.04+ | apt | ✅ |
| Debian 11+ | apt | ✅ |
| CentOS 8+ | dnf | ✅ |
| RHEL 8+ | dnf | ✅ |
| CentOS 7 | yum | ✅ |
