#!/usr/bin/env bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

APP_USER="admin"
APP_HOME="/home/$APP_USER"
DEPLOY_SCRIPT="$APP_HOME/deploy.sh"
BRANCH="main"
APP_PORT="3000"
PM2_NAME="next"
NVM_VERSION="v0.39.7"
NVM_DIR="$APP_HOME/.nvm"
SSH_CHECK_LOG=""

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

run_as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

run_as_app_user() {
  local command="$1"

  if [ "$(id -u)" -eq 0 ]; then
    runuser -u "$APP_USER" -- env HOME="$APP_HOME" USER="$APP_USER" LOGNAME="$APP_USER" \
      bash -lc "set -euo pipefail; $command"
  else
    bash -lc "set -euo pipefail; $command"
  fi
}

run_with_node() {
  local command="$1"

  run_as_app_user "
    export NVM_DIR=\"$NVM_DIR\"
    [ -s \"$NVM_DIR/nvm.sh\" ] && . \"$NVM_DIR/nvm.sh\"
    [ -s \"$NVM_DIR/bash_completion\" ] && . \"$NVM_DIR/bash_completion\"
    $command
  "
}

cleanup() {
  if [ -n "${SSH_CHECK_LOG:-}" ] && [ -f "$SSH_CHECK_LOG" ]; then
    rm -f "$SSH_CHECK_LOG"
  fi
}

trap cleanup EXIT

read -rp "Domain (example.com): " DOMAIN
read -rp "GitHub username: " GITHUB_USER
read -rp "GitHub repository name: " GITHUB_REPO

DOMAIN="$(trim "$DOMAIN")"
GITHUB_USER="$(trim "$GITHUB_USER")"
GITHUB_REPO="$(trim "$GITHUB_REPO")"

if [ -z "$DOMAIN" ] || [ -z "$GITHUB_USER" ] || [ -z "$GITHUB_REPO" ]; then
  abort "All input values are required."
fi

if ! [[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]]; then
  abort "Domain contains unsupported characters."
fi

if ! [[ "$GITHUB_USER" =~ ^[A-Za-z0-9-]+$ ]]; then
  abort "GitHub username contains unsupported characters."
fi

if ! [[ "$GITHUB_REPO" =~ ^[A-Za-z0-9._-]+$ ]]; then
  abort "GitHub repository name contains unsupported characters."
fi

if [ "$(id -u)" -ne 0 ] && [ "$(id -un)" != "$APP_USER" ]; then
  abort "Run this script as root or $APP_USER."
fi

if ! id "$APP_USER" >/dev/null 2>&1; then
  abort "User '$APP_USER' does not exist."
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

APP_DIR="$APP_HOME/$GITHUB_REPO"
REPO_SSH_URL="git@github.com:$GITHUB_USER/$GITHUB_REPO.git"

log "Updating apt package index"
run_as_root apt update
ok "apt updated"

log "Installing system packages"
run_as_root apt install -y \
  curl \
  git \
  ufw \
  nginx \
  fail2ban \
  unattended-upgrades \
  certbot \
  python3-certbot-nginx
ok "System packages installed"

log "Preparing admin home"
run_as_root mkdir -p "$APP_HOME"
run_as_root chown "$APP_USER:$APP_USER" "$APP_HOME"
ok "Admin home is ready"

if [ -e "$APP_DIR" ]; then
  abort "Repository directory already exists: $APP_DIR"
fi

log "Installing NVM"
if run_as_app_user "[ -s \"$NVM_DIR/nvm.sh\" ]"; then
  ok "NVM already installed"
else
  run_as_app_user "curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh | bash"
  ok "NVM installed"
fi

log "Installing Node.js LTS and PM2"
run_with_node "
  nvm install --lts
  npm install -g pm2
"
ok "Node.js LTS and PM2 installed"

log "Checking GitHub SSH access"
SSH_CHECK_LOG="$(mktemp)"

if ! run_as_app_user "ssh -T -o StrictHostKeyChecking=accept-new git@github.com" >"$SSH_CHECK_LOG" 2>&1; then
  if grep -qi "successfully authenticated" "$SSH_CHECK_LOG"; then
    ok "GitHub SSH authentication works"
  else
    cat "$SSH_CHECK_LOG"
    abort "GitHub SSH authentication failed. Add this server SSH key to GitHub deploy keys first."
  fi
else
  ok "GitHub SSH authentication works"
fi

log "Cloning repository into $APP_HOME"
run_as_app_user "
  cd \"$APP_HOME\"
  git clone \"$REPO_SSH_URL\"
"
ok "Repository cloned into $APP_DIR"

log "Installing app dependencies and building"
run_with_node "
  cd \"$APP_DIR\"
  npm install
  npm run build
"
ok "App installed and built"

log "Starting app with PM2"
run_with_node "
  cd \"$APP_DIR\"
  pm2 start npm --name \"$PM2_NAME\" -- start
  pm2 save
"
ok "PM2 app started"

log "Configuring PM2 startup"
PM2_BIN="$(run_with_node "command -v pm2")"

if [ -z "$PM2_BIN" ]; then
  abort "Could not find the PM2 binary for $APP_USER."
fi

run_as_root env "PATH=$PATH:$(dirname "$PM2_BIN")" pm2 startup systemd -u "$APP_USER" --hp "$APP_HOME"
ok "PM2 startup configured"

log "Configuring firewall"
run_as_root ufw allow ssh
run_as_root ufw allow http
run_as_root ufw allow https
run_as_root ufw --force enable
ok "Firewall configured"

log "Enabling services"
run_as_root systemctl enable --now nginx
run_as_root systemctl enable --now fail2ban
ok "nginx and fail2ban enabled"

log "Writing nginx config"
run_as_root tee "/etc/nginx/sites-available/$DOMAIN.conf" >/dev/null <<EOF
server {
  server_name $DOMAIN www.$DOMAIN;
  location / {
    include proxy_params;
    proxy_pass http://127.0.0.1:$APP_PORT;
  }
  listen 80;
}
EOF

if [ ! -L "/etc/nginx/sites-enabled/$DOMAIN.conf" ]; then
  run_as_root ln -s "/etc/nginx/sites-available/$DOMAIN.conf" "/etc/nginx/sites-enabled/$DOMAIN.conf"
fi

run_as_root nginx -t
run_as_root systemctl reload nginx
ok "nginx config loaded"

log "Requesting SSL certificate"
run_as_root certbot --nginx -d "$DOMAIN" -d "www.$DOMAIN"
ok "SSL certificate installed"

log "Writing deploy.sh"
run_as_root tee "$DEPLOY_SCRIPT" >/dev/null <<EOF
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

run_as_root chmod +x "$DEPLOY_SCRIPT"
run_as_root chown "$APP_USER:$APP_USER" "$DEPLOY_SCRIPT"
ok "deploy.sh created at $DEPLOY_SCRIPT"

echo
ok "Setup complete"
echo "Domain: $DOMAIN"
echo "Repository: $REPO_SSH_URL"
echo "App directory: $APP_DIR"
echo "Deploy script: $DEPLOY_SCRIPT"
