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

as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
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

read_prompt "OS user (deploy): " OS_USER
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

USER_HOME="$(getent passwd "$OS_USER" | cut -d: -f6)"
REPO_DIR="$USER_HOME/$GITHUB_REPO"
NVM_DIR="$USER_HOME/.nvm"

if [ -z "$USER_HOME" ]; then
  abort "Could not determine home directory for '$OS_USER'."
fi

run_as_os_user() {
  local command="$1"

  if [ "$(id -un)" = "$OS_USER" ]; then
    HOME="$USER_HOME" bash -lc "$command"
  else
    runuser -u "$OS_USER" -- env HOME="$USER_HOME" bash -lc "$command"
  fi
}

if [ ! -d "$REPO_DIR" ]; then
  abort "Repository directory not found: $REPO_DIR"
fi

if [ ! -d "$REPO_DIR/.git" ]; then
  abort "Directory exists but is not a git repository: $REPO_DIR"
fi

log "Installing system packages"
as_root apt-get update
as_root apt-get install -y ufw fail2ban nginx certbot python3-certbot-nginx
ok "System packages installed"

# Добавляем swap
if swapon --show=NAME --noheadings 2>/dev/null | grep -Fxq "/swap"; then
  ok "Swap file already enabled"
else
  if [ ! -f /swap ]; then
    log "Creating swap file"
    as_root dd if=/dev/zero of=/swap bs=1M count=1024 status=none
  else
    log "Reusing existing /swap file"
  fi

  as_root chmod 600 /swap
  as_root mkswap /swap >/dev/null
  as_root swapon /swap

  if ! grep -Eq '^/swap[[:space:]]+none[[:space:]]+swap[[:space:]]+sw[[:space:]]+0[[:space:]]+0$' /etc/fstab; then
    echo "/swap none swap sw 0 0" | as_root tee -a /etc/fstab >/dev/null
  fi

  ok "Swap file enabled"
fi

# Install nvm
if [ ! -s "$NVM_DIR/nvm.sh" ]; then
  log "Installing nvm for $OS_USER"
  run_as_os_user "curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash"
else
  ok "nvm already installed"
fi

run_as_os_user "export NVM_DIR='$NVM_DIR'; . '$NVM_DIR/nvm.sh'; nvm install --lts >/dev/null"
ok "Node.js and NPM installed"

NODE_BIN_DIR="$(dirname "$(run_as_os_user "export NVM_DIR='$NVM_DIR'; . '$NVM_DIR/nvm.sh'; nvm which current")")"
PM2_BIN="$NODE_BIN_DIR/pm2"

# Установка зависимостей
log "Installing app dependencies and building project"
run_as_os_user "export NVM_DIR='$NVM_DIR'; . '$NVM_DIR/nvm.sh'; cd '$REPO_DIR'; npm ci; npm run build"
ok "App installed and built"

# Авто-запуск npm run start (в папке проекта)
run_as_os_user "export NVM_DIR='$NVM_DIR'; . '$NVM_DIR/nvm.sh'; npm install -g pm2"
if run_as_os_user "export NVM_DIR='$NVM_DIR'; . '$NVM_DIR/nvm.sh'; pm2 describe next >/dev/null 2>&1"; then
  run_as_os_user "export NVM_DIR='$NVM_DIR'; . '$NVM_DIR/nvm.sh'; cd '$REPO_DIR'; pm2 restart next --update-env"
else
  run_as_os_user "export NVM_DIR='$NVM_DIR'; . '$NVM_DIR/nvm.sh'; cd '$REPO_DIR'; pm2 start npm --name next -- start"
fi
run_as_os_user "export NVM_DIR='$NVM_DIR'; . '$NVM_DIR/nvm.sh'; pm2 save"
as_root env PATH="$PATH:$NODE_BIN_DIR" "$PM2_BIN" startup systemd -u "$OS_USER" --hp "$USER_HOME"
ok "PM2 app started and startup configured"

# Настраиваем фаервол
as_root ufw allow ssh
as_root ufw allow http
as_root ufw allow https
as_root ufw allow 22/tcp
as_root ufw --force enable
as_root ufw reload
ok "Firewall configured"

# fail2ban
as_root tee /etc/fail2ban/jail.local > /dev/null <<EOF
[DEFAULT]
ignoreip = $USER_IP

[sshd]
enabled = true
findtime = 120
maxretry = 3
bantime = 43200
EOF
as_root systemctl enable --now fail2ban.service
as_root systemctl restart fail2ban.service
ok "fail2ban enabled"

# nginx прокси сервер
as_root tee /etc/nginx/sites-available/$DOMAIN.conf > /dev/null <<EOF
server {
    server_name $DOMAIN;

    location / {
        include proxy_params;
        proxy_pass http://127.0.0.1:3000;
    }

    listen 80;
}
EOF

as_root ln -sfn /etc/nginx/sites-available/$DOMAIN.conf /etc/nginx/sites-enabled/$DOMAIN.conf
as_root systemctl enable --now nginx
as_root nginx -t
as_root systemctl reload nginx
ok "nginx config loaded"

# Настраиваем https
if [ -d "/etc/letsencrypt/live/$DOMAIN" ]; then
  ok "SSL certificate already installed"
else
  as_root certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email --redirect
  ok "SSL certificate installed"
fi

# Создаем deploy.sh
run_as_os_user "cat > '$USER_HOME/deploy.sh' <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

export NVM_DIR=\"$NVM_DIR\"
[ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"

cd \"$REPO_DIR\"
git pull
npm ci
npm run build
pm2 reload next
EOF
"

chmod +x "$USER_HOME/deploy.sh"

ok "deploy.sh created"

echo
ok "Setup complete"
echo "Your site now available: https://$DOMAIN/"
