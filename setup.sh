#!/usr/bin/env bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
  echo -e "${BLUE}==>${NC} $1"
}

ok() {
  echo -e "${GREEN}✔${NC} $1"
}

warn() {
  echo -e "${YELLOW}⚠${NC} $1"
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

read -rp "Domain (example.com): " DOMAIN
read -rp "GitHub username: " GITHUB_USER
read -rp "GitHub repository name: " GITHUB_REPO

APP_USER="admin"
APP_HOME="/home/$APP_USER"
APP_DIR="$APP_HOME/repo"
DEPLOY_SCRIPT="$APP_HOME/deploy.sh"
BRANCH="main"
APP_PORT="3000"
PM2_NAME="next"
NVM_VERSION="v0.39.7"
REPO_SSH_URL="git@github.com:$GITHUB_USER/$GITHUB_REPO.git"

if [ -z "$DOMAIN" ] || [ -z "$GITHUB_USER" ] || [ -z "$GITHUB_REPO" ]; then
  abort "All input values are required."
fi

if ! id "$APP_USER" >/dev/null 2>&1; then
  abort "User '$APP_USER' does not exist."
fi

if [ "$(id -u)" -eq 0 ]; then
  RUN_USER="$APP_USER"
else
  RUN_USER="$(whoami)"
fi

RUN_HOME="$(eval echo "~$RUN_USER")"
NVM_DIR="$RUN_HOME/.nvm"

run_as_user() {
  if [ "$(id -u)" -eq 0 ]; then
    sudo -u "$RUN_USER" -H bash -lc "$1"
  else
    bash -lc "$1"
  fi
}

log "Checking required commands"
require_command sudo
require_command apt
require_command ssh
require_command git
require_command curl
ok "Base requirements are available"

log "Updating apt package index"
sudo apt update
ok "apt updated"

log "Installing system packages"
sudo apt install -y \
  curl \
  git \
  ufw \
  nginx \
  fail2ban \
  unattended-upgrades \
  certbot \
  python3-certbot-nginx
ok "System packages installed"

log "Installing NVM"
run_as_user "curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh | bash"
ok "NVM installed"

log "Installing Node.js LTS and PM2"
run_as_user "
  export NVM_DIR=\"$NVM_DIR\"
  [ -s \"$NVM_DIR/nvm.sh\" ] && . \"$NVM_DIR/nvm.sh\"
  [ -s \"$NVM_DIR/bash_completion\" ] && . \"$NVM_DIR/bash_completion\"
  nvm install --lts
  npm install -g pm2
"
ok "Node.js LTS and PM2 installed"

log "Checking GitHub SSH access"
if ! run_as_user "ssh -T -o StrictHostKeyChecking=accept-new git@github.com" >/tmp/github_ssh_check.txt 2>&1; then
  if grep -qi "successfully authenticated" /tmp/github_ssh_check.txt; then
    ok "GitHub SSH authentication works"
  else
    cat /tmp/github_ssh_check.txt
    abort "GitHub SSH authentication failed. Add this server SSH key to GitHub deploy keys first."
  fi
else
  ok "GitHub SSH authentication works"
fi

if [ -e "$APP_DIR" ]; then
  abort "Directory already exists: $APP_DIR"
fi

log "Preparing app directory"
sudo mkdir -p "$APP_HOME"
sudo chown -R "$APP_USER:$APP_USER" "$APP_HOME"
ok "App home is ready"

log "Cloning repository"
run_as_user "git clone \"$REPO_SSH_URL\" \"$APP_DIR\""
ok "Repository cloned into $APP_DIR"

log "Installing app dependencies and building"
run_as_user "
  cd \"$APP_DIR\"
  export NVM_DIR=\"$NVM_DIR\"
  [ -s \"$NVM_DIR/nvm.sh\" ] && . \"$NVM_DIR/nvm.sh\"
  [ -s \"$NVM_DIR/bash_completion\" ] && . \"$NVM_DIR/bash_completion\"
  npm install
  npm run build
"
ok "App installed and built"

log "Starting app with PM2"
run_as_user "
  cd \"$APP_DIR\"
  export NVM_DIR=\"$NVM_DIR\"
  [ -s \"$NVM_DIR/nvm.sh\" ] && . \"$NVM_DIR/nvm.sh\"
  [ -s \"$NVM_DIR/bash_completion\" ] && . \"$NVM_DIR/bash_completion\"
  pm2 start npm --name \"$PM2_NAME\" -- start
  pm2 save
"
ok "PM2 app started"

log "Configuring PM2 startup"
PM2_BIN="$(run_as_user "
  export NVM_DIR=\"$NVM_DIR\"
  [ -s \"$NVM_DIR/nvm.sh\" ] && . \"$NVM_DIR/nvm.sh\"
  command -v pm2
")"

PM2_BIN_DIR="$(dirname "$PM2_BIN")"

sudo su -c "env PATH=$PATH:$PM2_BIN_DIR pm2 startup systemd -u $RUN_USER --hp $RUN_HOME"
ok "PM2 startup configured"

log "Configuring firewall"
sudo ufw allow ssh
sudo ufw allow http
sudo ufw allow https
sudo ufw --force enable
ok "Firewall configured"

log "Enabling services"
sudo systemctl enable --now nginx
sudo systemctl enable --now fail2ban
ok "nginx and fail2ban enabled"

log "Writing temporary nginx config"
sudo tee "/etc/nginx/sites-available/$DOMAIN.conf" >/dev/null <<EOF
server {
    listen 80;
    server_name $DOMAIN www.$DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN www.$DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    server_tokens off;

    location / {
        proxy_pass http://127.0.0.1:$APP_PORT;
        proxy_http_version 1.1;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
    }
}
EOF

if [ ! -L "/etc/nginx/sites-enabled/$DOMAIN.conf" ]; then
  sudo ln -s "/etc/nginx/sites-available/$DOMAIN.conf" "/etc/nginx/sites-enabled/$DOMAIN.conf"
fi

sudo nginx -t
sudo systemctl reload nginx
ok "nginx config loaded"

log "Requesting SSL certificate"
sudo certbot --nginx -d "$DOMAIN" -d "www.$DOMAIN"
ok "SSL certificate installed"

log "Rewriting final deploy.sh"
sudo tee "$DEPLOY_SCRIPT" >/dev/null <<EOF
#!/usr/bin/env bash

set -euo pipefail

cd "$APP_DIR"

export NVM_DIR="$APP_HOME/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && . "\$NVM_DIR/nvm.sh"
[ -s "\$NVM_DIR/bash_completion" ] && . "\$NVM_DIR/bash_completion"

git fetch --all
git reset --hard origin/$BRANCH
npm ci
npm run build
pm2 reload all
EOF

sudo chmod +x "$DEPLOY_SCRIPT"
sudo chown "$APP_USER:$APP_USER" "$DEPLOY_SCRIPT"
ok "deploy.sh created at $DEPLOY_SCRIPT"

echo
ok "Setup complete"
echo "Domain: $DOMAIN"
echo "Repository: $REPO_SSH_URL"
echo "App directory: $APP_DIR"
echo "Deploy script: $DEPLOY_SCRIPT"