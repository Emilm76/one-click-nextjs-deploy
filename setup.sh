#!/usr/bin/env bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
  echo -e "${BLUE}==>${NC} $1"
}

ok() {
  echo -e "${GREEN}✔${NC} $1"
}

err() {
  echo -e "${RED}✘${NC} $1"
}

abort() {
  err "$1"
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || abort "Required command not found: $1"
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

read_prompt() {
  local prompt="$1"
  local var_name="$2"
  local value=""

  # When the script is piped into bash, stdin is occupied by the script itself,
  # so interactive prompts must read from the controlling terminal instead.
  if [[ -r /dev/tty ]]; then
    read -r -p "$prompt" value < /dev/tty || abort "Failed to read input for $var_name."
  else
    read -r -p "$prompt" value || abort "Failed to read input for $var_name."
  fi

  printf -v "$var_name" '%s' "$value"
}

read_prompt "OS user (admin): " OS_USER
read_prompt "Your IP (for ignore in fail2ban): " USER_IP
read_prompt "Domain (example.com): " DOMAIN
read_prompt "GitHub repository name: " GITHUB_REPO

OS_USER="$(trim "$OS_USER")"
USER_IP="$(trim "$USER_IP")"
DOMAIN="$(trim "$DOMAIN")"
GITHUB_REPO="$(trim "$GITHUB_REPO")"

if [ -z "$OS_USER" ] || [ -z "$USER_IP" ] || [ -z "$DOMAIN" ] || [ -z "$GITHUB_REPO" ]; then
  abort "All input values are required."
fi

if ! [[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]]; then
  abort "Domain contains unsupported characters."
fi

if ! [[ "$GITHUB_REPO" =~ ^[A-Za-z0-9._-]+$ ]]; then
  abort "GitHub repository name contains unsupported characters."
fi

if ! [[ "$USER_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  abort "IP address must be a valid IPv4 address."
fi

IFS='.' read -r ip1 ip2 ip3 ip4 <<< "$USER_IP"
for octet in "$ip1" "$ip2" "$ip3" "$ip4"; do
  if ((octet < 0 || octet > 255)); then
    abort "IP address must be a valid IPv4 address."
  fi
done

if [ "$(id -u)" -ne 0 ] && [ "$(id -un)" != "$OS_USER" ]; then
  abort "Run this script as root or $OS_USER."
fi

if ! id "$OS_USER" >/dev/null 2>&1; then
  abort "User '$OS_USER' does not exist."
fi

require_command apt
require_command curl
require_command git
require_command ssh

if [ "$(id -u)" -eq 0 ]; then
  require_command runuser
else
  require_command sudo
fi

# Добавляем swap
sudo dd if=/dev/zero of=/swap bs=1M count=1024
sudo chmod 600 /swap && sudo mkswap /swap
sudo swapon /swap

echo "/swap none swap sw 0 0"| sudo tee -a /etc/fstab
ok "Swap file enabled"

# Install nvm
sudo curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
# Load nvm without sourcing the interactive shell config.
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && . "$NVM_DIR/bash_completion"
# Install the latest LTS version of Node.js
nvm install --lts
ok "Node.js and NPM installed"

# Установка зависимостей
cd ~/$GITHUB_REPO
npm ci
npm run build
ok "App installed and built"

# Авто-запуск npm run start (в папке проекта)
npm install -g pm2
pm2 start npm --name next -- start
pm2 startup
pm2 save

sudo env PATH=$PATH:/home/$OS_USER/.nvm/versions/node/v24.14.0/bin /home/$OS_USER/.nvm/versions/node/v24.14.0/lib/node_modules/pm2/bin/pm2 startup systemd -u $OS_USER --hp /home/$OS_USER
ok "PM2 app started and startup configured"

# Настраеваем фаервол
sudo apt-get install ufw

sudo ufw allow ssh
sudo ufw allow http
sudo ufw allow https
sudo ufw allow 22/tcp
sudo ufw enable
sudo ufw reload
ok "Firewall configured"

# fail2ban
sudo apt install fail2ban
sudo tee /etc/fail2ban/jail.local > /dev/null <<EOF
[DEFAULT]
ignoreip = $USER_IP

[sshd]
enabled = true
findtime = 120
maxretry = 3
bantime = 43200
EOF
# Перезапустить
sudo systemctl restart fail2ban.service
ok "fail2ban enabled"

# nginx прокси сервер
sudo apt install nginx

sudo systemctl is-enabled nginx

sudo tee /etc/nginx/sites-available/$DOMAIN.conf > /dev/null <<EOF
server {
    server_name $DOMAIN;

    location / {
        include proxy_params;
        proxy_pass http://127.0.0.1:3000;
    }

    listen 80;
}
EOF

sudo ln -s /etc/nginx/sites-available/$DOMAIN.conf /etc/nginx/sites-enabled/
# Тестируем конфигурацию
sudo nginx -t
# Перезапускаем nginx
sudo nginx -s reload
ok "nginx config loaded"

# Настраиваем https
sudo apt install certbot python3-certbot-nginx
sudo certbot --nginx -d $DOMAIN
ok "SSL certificate installed"

# Создаем deploy.sh
tee ~/deploy.sh > /dev/null <<EOF
#!/usr/bin/env bash
set -e

cd ~/$GITHUB_REPO
git pull
npm ci
npm run build
pm2 reload next
EOF

# Дать права файлу:
chmod +x ./deploy.sh

ok "deploy.sh created"

echo
ok "Setup complete"
echo "Your site now available: https://$DOMAIN/"
