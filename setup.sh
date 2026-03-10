#!/usr/bin/env bash

set -e

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

if [ "$(id -u)" -eq 0 ]; then
  RUN_USER="$APP_USER"
else
  RUN_USER="$(whoami)"
fi

RUN_HOME="$(eval echo "~$RUN_USER")"
NVM_DIR="$RUN_HOME/.nvm"
GIT_SSH_URL="git@github.com:$GITHUB_USER/$GITHUB_REPO.git"

run_as_user() {
  if [ "$(id -u)" -eq 0 ]; then
    sudo -u "$RUN_USER" -H bash -lc "$1"
  else
    bash -lc "$1"
  fi
}

echo "==> Updating apt"
sudo apt update

echo "==> Installing system packages"
sudo apt install -y curl git ufw nginx fail2ban unattended-upgrades certbot python3-certbot-nginx

echo "==> Installing NVM"
run_as_user "curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh | bash"

echo "==> Installing Node.js LTS with NVM"
run_as_user "
  export NVM_DIR=\"$NVM_DIR\"
  [ -s \"$NVM_DIR/nvm.sh\" ] && . \"$NVM_DIR/nvm.sh\"
  [ -s \"$NVM_DIR/bash_completion\" ] && . \"$NVM_DIR/bash_completion\"
  nvm install --lts
  npm install -g pm2
"

echo "==> Cloning repository"
if [ -d "$APP_DIR" ]; then
  echo "Directory $APP_DIR already exists"
  exit 1
fi

sudo mkdir -p "$APP_HOME"
sudo chown -R "$RUN_USER:$RUN_USER" "$APP_HOME"

run_as_user "git clone \"$GIT_SSH_URL\" \"$APP_DIR\""

echo "==> Installing dependencies and building app"
run_as_user "
  cd \"$APP_DIR\"
  export NVM_DIR=\"$NVM_DIR\"
  [ -s \"$NVM_DIR/nvm.sh\" ] && . \"$NVM_DIR/nvm.sh\"
  [ -s \"$NVM_DIR/bash_completion\" ] && . \"$NVM_DIR/bash_completion\"
  npm install
  npm run build
"

echo "==> Starting app with PM2"
run_as_user "
  cd \"$APP_DIR\"
  export NVM_DIR=\"$NVM_DIR\"
  [ -s \"$NVM_DIR/nvm.sh\" ] && . \"$NVM_DIR/nvm.sh\"
  [ -s \"$NVM_DIR/bash_completion\" ] && . \"$NVM_DIR/bash_completion\"
  pm2 start npm --name \"$PM2_NAME\" -- start
  pm2 save
"

echo "==> Enabling PM2 startup"
NODE_BIN_PATH="$(sudo -u "$RUN_USER" -H bash -lc "
  export NVM_DIR=\"$NVM_DIR\"
  [ -s \"$NVM_DIR/nvm.sh\" ] && . \"$NVM_DIR/nvm.sh\"
  command -v pm2
")"

sudo su -c "env PATH=$PATH:$(dirname "$NODE_BIN_PATH") pm2 startup systemd -u $RUN_USER --hp $RUN_HOME"

echo "==> Configuring firewall"
sudo ufw allow ssh
sudo ufw allow http
sudo ufw allow https
sudo ufw --force enable

echo "==> Enabling services"
sudo systemctl enable --now nginx
sudo systemctl enable --now fail2ban

echo "==> Writing Nginx config"
sudo tee "/etc/nginx/sites-available/$DOMAIN.conf" > /dev/null <<EOF
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

echo "==> Requesting SSL certificate"
sudo certbot --nginx -d "$DOMAIN" -d "www.$DOMAIN"

echo "==> Rewriting Nginx config after certbot"
sudo tee "/etc/nginx/sites-available/$DOMAIN.conf" > /dev/null <<EOF
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

sudo nginx -t
sudo systemctl reload nginx

echo "==> Creating deploy.sh"
sudo tee "$DEPLOY_SCRIPT" > /dev/null <<EOF
#!/usr/bin/env bash

set -e

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

echo "==> Done"
echo "App directory: $APP_DIR"
echo "Deploy script: $DEPLOY_SCRIPT"