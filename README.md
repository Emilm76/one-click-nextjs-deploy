# Next.js VPS Deploy Script

Скрипт предназначен для **деплоя простого Next.js проекта на VPS** под **Ubuntu / Debian**.

Он автоматизирует:
- клонирование репозитория из GitHub по SSH
- установку **NVM**
- установку **Node.js LTS**
- установку зависимостей и сборку проекта
- запуск приложения через **PM2**
- настройку автозапуска **PM2**
- настройку **UFW**
- установку и настройку **Nginx**
- выпуск SSL-сертификата через **Certbot**
- создание файла `/home/admin/deploy.sh` для последующих деплоев

## Что должно быть сделано вручную заранее

Перед запуском скрипта нужно вручную выполнить базовую настройку сервера и SSH.

```bash
# На сервере
adduser admin
usermod -aG sudo admin

# Локально на пк (замените domain.com на домен или IP сервера)
ssh-keygen
ssh-copy-id admin@domain.com

# На сервере
sudo nano /etc/ssh/sshd_config
  # PermitRootLogin no
  # PasswordAuthentication no
sudo systemctl restart ssh

ssh-keygen
cat .ssh/id_ed25519.pub
  # Добавте ключ в github Deploy keys
````

## Как запустить

1. Скопируйте скрипт на сервер.

   ```bash
   cd ~
   git clone https://github.com/Emilm76/one-click-nextjs-deploy.git
   cd ./one-click-nextjs-deploy
   ```
2. Дайте права на выполнение:

   ```bash
   chmod +x setup.sh
   ```
3. Запустите:

   ```bash
   ./setup.sh
   ```

Во время запуска скрипт попросит ввести:

* домен
* GitHub username
* GitHub repository name

## Важно

Скрипт рассчитан на:

* пользователя `admin`
* путь проекта: `/home/admin/repo`
* файл деплоя: `/home/admin/deploy.sh`
* ветку: `main`

Скрипт можно запускать **от `admin` или `root`**.

## Повторный деплой

После первого запуска для обновления проекта используйте:

```bash
~/deploy.sh
```
