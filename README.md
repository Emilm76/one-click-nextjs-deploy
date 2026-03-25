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

`setup.sh` можно запускать повторно с теми же значениями: он переиспользует уже созданные ресурсы и обновляет конфигурацию без дублирования ключевых сущностей.

## Что должно быть сделано вручную заранее

Перед запуском скрипта нужно вручную выполнить базовую настройку сервера, SSH и склонировать репозиторий.

```bash
# Подключение
ssh root@<DOMAIN>

# Создать пользователя deploy
adduser deploy
usermod -aG sudo deploy
exit

# (Локально на пк) генерируем ssh, если еще нет
ssh-keygen
# Добавляем ssh на сервер
ssh-copy-id deploy@<DOMAIN>

# (На сервере) Запрещаем подключаться через root и паролю
ssh deploy@<DOMAIN>
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

# Подключаться теперь так: ssh deploy@<DOMAIN>

# Генерируем ssh (для клонирования репо git)
ssh-keygen
cat .ssh/id_ed25519.pub
# добавляем ключ в Deploy keys на github

# Клонируем репо через ssh
sudo apt update && sudo apt upgrade -y && sudo apt install git -y
git clone <SSH_ссылка_на_репозиторий>

# Если нужно:
	# - создать .env
	# - создать БД
```

## Как запустить

```bash
cd ~
curl -fsSL https://raw.githubusercontent.com/Emilm76/one-click-nextjs-deploy/refs/heads/main/setup.sh -o setup.sh
bash ./setup.sh
```

Во время запуска скрипт попросит ввести:

* имя пользователя linux (deploy)
* ваш IP
* домен
* GitHub repository name

Если запуск прервался на середине или вы хотите повторно применить конфигурацию, просто запустите `setup.sh` еще раз и введите те же значения.

## Повторный деплой

После первого запуска для обновления проекта используйте:

```bash
~/deploy.sh
```
