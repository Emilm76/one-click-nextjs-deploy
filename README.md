# Next.js VPS Deploy Script

Скрипт предназначен для **деплоя простого Next.js проекта на VPS** под **Ubuntu / Debian**.

Он автоматизирует:
- добавление swap
- установку **Node.js** через **NVM**
- установку зависимостей и сборку проекта
- запуск через **PM2**
- настройку **UFW** и **fail2ban**
- установку и настройку **Nginx**
- выпуск SSL-сертификата через **Certbot**
- создание файла `deploy.sh` для последующих деплоев

## Что должно быть сделано вручную заранее

Перед запуском скрипта нужно вручную выполнить базовую настройку сервера, SSH и склонировать репозиторий.

```bash
# Подключение
ssh root@<DOMAIN>

# Создать пользователя admin
adduser admin
usermod -aG sudo admin
exit

# (Локально на пк) генерируем ssh, если еще нет
ssh-keygen
# Добавляем ssh на сервер
ssh-copy-id admin@<DOMAIN>

# (На сервере) Запрещаем подключаться через root и паролю
ssh admin@<DOMAIN>
sudo nano /etc/ssh/sshd_config
```

Изменить следующее:
```text
PermitRootLogin no
PasswordAuthentication no
```

```bash
# Перезапускаем ssh
sudo systemctl restart ssh

# Подключаться теперь так: ssh admin@teroks.ru

# Генерируем ssh (для клонирования репо git)
ssh-keygen
cat .ssh/id_ed25519.pub
# добавляем ключ в Deploy keys на github

# Клонируем репо через ssh
sudo apt update && sudo apt upgrade -y && sudo apt install git -y
git clone <SSH_ссылка>

# Если нужно:
	# - создать .env
	# - создать БД
```

## Как запустить

```bash
sudo apt update && sudo apt upgrade -y && sudo apt install git -y
cd ~
sudo curl -o- https://raw.githubusercontent.com/Emilm76/one-click-nextjs-deploy/refs/heads/main/setup.sh | bash
```

Во время запуска скрипт попросит ввести:

* имя пользователя linux (admin)
* ваш IP
* домен
* GitHub repository name

## Повторный деплой

После первого запуска для обновления проекта используйте:

```bash
~/deploy.sh
```
