# 🔐 Nginx SSL Setup

Bash-скрипт для автоматической настройки Nginx и выдачи SSL сертификата через Let's Encrypt (Certbot).

## ✨ Что делает скрипт

- Устанавливает **Nginx** и **Certbot** (если не установлены)
- Открывает порты **80, 443, 22** в файрволе (UFW / firewalld)
- Создаёт конфиг Nginx с редиректом HTTP → HTTPS
- Получает SSL сертификат от **Let's Encrypt**
- Настраивает **проксирование** запросов на порт твоего приложения
- Настраивает **автообновление** сертификата каждую ночь в 03:00

## 📋 Требования

- Ubuntu / Debian / CentOS / RHEL
- Запуск от **root** или через **sudo**
- Домен должен иметь **A-запись в DNS**, указывающую на IP сервера
- Порты **80 и 443** должны быть доступны из интернета

## 🚀 Установка

```bash
curl -fsSL https://raw.githubusercontent.com/sickofme/ssl/main/setup-ssl.sh -o setup-ssl.sh && sudo bash setup-ssl.sh
```

Скрипт задаст три вопроса:

| Параметр | Пример | Описание |
|---|---|---|
| Домен | `example.com` | Домен для которого выпускается сертификат |
| Порт | `3000` | Порт локального приложения для проксирования |
| Email | `you@example.com` | Email для уведомлений о продлении сертификата |

## 📁 Что создаётся

```
/etc/nginx/sites-available/<домен>   — конфиг Nginx
/etc/letsencrypt/live/<домен>/       — SSL сертификат
/var/www/certbot/                    — директория для ACME challenge
/etc/cron.d/certbot-renew            — задача автообновления
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
