# Remnawave Self-Steal Nginx

**Development version. Do not use on a production VPS until the Ubuntu 24.04
integration checks have passed.**

This installer prepares an HTTP webroot for Let's Encrypt and an nginx TLS
endpoint at `127.0.0.1:9443` with HTTP/2 and TLS 1.3 support.
Remnawave Node configuration remains manual.
It does not edit Docker, Remnawave, Xray or the firewall.

## Supported host

- Ubuntu 24.04 LTS on x86_64, run as root.
- A domain with exactly one A record pointing to the VPS's public IPv4 and
  no AAAA record.
- Ports 80 and 9443 free before the first installation.
- No pre-existing nginx installation. The package-provided default site is
  left in place after nginx is installed.
- No pre-existing Let's Encrypt lineage for the chosen domain.
- If Remnawave Node is present, its Docker network mode must be `host`.
- `curl` with HTTP/2 support, `resolvectl` and `ss` available for the
  read-only preflight. Ubuntu's packaged curl supports HTTP/2.

Less than 1 GiB RAM or no swap produces a warning. Less than 2 GiB free disk
space stops installation. This installer does not perform a full system
upgrade or reboot.

## Пошаговая установка и настройка Remnawave

Все команды ниже, кроме отправки коммита, выполняются на VPS. Сначала
проверь установку на тестовом сервере. При ошибке остановись на текущем
этапе и сохрани вывод.

В примерах:

| Значение | Назначение |
| --- | --- |
| `node.example.com` | Твой домен, на который установщик выпустит сертификат |
| `8443` | Пример публичного порта существующего REALITY inbound; подставь свой |
| `127.0.0.1:9443` | Локальный TLS endpoint nginx, к которому обращается Xray |

Сначала подготовь домен и установи nginx. Профиль и Hosts в панели меняй
только после успешной проверки self-steal.

### 1. Подготовь DNS, сеть и Node

1. Создай одну DNS A-запись `node.example.com`, указывающую на публичный IPv4
   нужной VPS. Домен вводится без `https://`, порта и пути.
2. Удали AAAA-запись этого имени. Если используешь Cloudflare, отключи
   проксирование для этой записи: режим **DNS only**.
3. Разреши входящий TCP/80 в firewall VPS и в сетевых правилах хостинга.
   Он нужен для выпуска и последующих продлений сертификата.
4. Сохрани доступность текущего публичного порта REALITY — например,
   TCP/8443. Локальный TCP/9443 наружу не открывай. Правила SSH и порта API
   Node на этом этапе не меняй.
5. В Docker Compose своего Remnawave Node должен быть `network_mode: host`.
   Если режим другой, сначала приведи Node к поддерживаемой схеме по
   [документации Remnawave Node](https://docs.rw/install/remnawave-node/).
   Изменение сети контейнера может прервать действующие подключения.

Если Node ещё не установлен, self-steal можно подготовить заранее. Позже
установи Node с host networking на эту же VPS.

### 2. Склонируй актуальную версию

Сначала отправь коммит с компьютера на GitHub:

```powershell
git push origin main
```

На VPS перейди в root-сессию и установи необходимые инструменты:

```bash
sudo -i
apt-get update
apt-get install -y git curl ca-certificates openssl iproute2 python3-configobj
```

Склонируй репозиторий:

```bash
git clone https://github.com/Inch1337/Remnawave-Selfsteal-Nginx.git /opt/remnawave-selfsteal
cd /opt/remnawave-selfsteal
git log -1 --oneline
```

Если он уже склонирован и в нём нет несохранённых правок:

```bash
cd /opt/remnawave-selfsteal
git pull --ff-only
git log -1 --oneline
```

Убедись, что показан нужный коммит. Файлы `install.sh`, `check.sh` и
`uninstall.sh` должны оставаться в одной папке. Отдельный старый
`/root/install.sh` не обновляется при клонировании — запускай скрипты
именно из `/opt/remnawave-selfsteal`.

### 3. Выполни предварительные проверки

Сначала синтаксис и локальные проверки вспомогательных функций:

```bash
bash -n install.sh &&
bash -n check.sh &&
bash -n uninstall.sh &&
bash -n tests/test_helpers.sh &&
bash tests/test_helpers.sh
```

Ожидается `Helper checks passed.` Эти проверки не устанавливают nginx и
не выпускают сертификат.

Затем проверь саму VPS:

```bash
bash install.sh --check
```

Введи свой домен, например `node.example.com`. Ожидается сообщение об
успешном preflight. Этот режим не меняет систему. Если отсутствует
`resolvectl`, сначала выясни, как настроен DNS на VPS; не заменяй работающую
настройку DNS вслепую.

**Пока не меняй target, SNI и Hosts в Remnawave:** нового TLS endpoint
на этом этапе ещё нет.

### 4. Установи и проверь nginx

```bash
set -o pipefail
bash install.sh --install 2>&1 | tee install.log
```

Введи тот же домен и контактный email для Let's Encrypt. Установщик
подготовит nginx, получит сертификат и выполнит пробное продление с deploy
hook. Дождись `Installation complete.` Затем:

```bash
bash check.sh 2>&1 | tee check.log
```

Продолжай только после `[OK]` у всех пунктов и `SELF-STEAL READY`.
Теперь на VPS подготовлен локальный nginx для self-steal; подключение
через сам Remnawave проверяется после следующих шагов.

### 5. Измени серверный Config Profile

Сохрани прежние значения профиля и карточки Host, чтобы можно было вернуть
рабочее подключение. Если профиль общий для нескольких нод с разными
доменами, создай отдельную копию для этой ноды и назначь ей нужный inbound.

В панели открой **Config Profiles**, выбери профиль нужной ноды и её
REALITY inbound. В `streamSettings.realitySettings` измени только эти поля:

```json
{
  "target": "127.0.0.1:9443",
  "serverNames": ["node.example.com"],
  "xver": 0
}
```

Это фрагмент настроек, а не полный профиль. Подставь домен, использованный
при установке. Сохрани остальные параметры REALITY, включая `privateKey`
и `shortIds`, а также существующие параметры протокола и транспорта.
В конфигурации, использующей старое имя `dest`, замени соответствующий
target-параметр, не оставляя противоречащие друг другу `dest` и `target`.

Публичный `port` inbound оставь прежним — например, `8443`. Значение
`9443` здесь используется только внутри `target`. `xver: 0` соответствует
созданному nginx без PROXY protocol.

Сохрани профиль и примени его к нужной ноде. Убедись, что нода приняла
конфигурацию без ошибок. Ручное редактирование генерируемого Xray-конфига
в контейнере не заменяет изменение профиля в панели.

### 6. Обнови Hosts и SNI в панели

Открой **Hosts** и отредактируй карточку для этой ноды:

| Поле | Что указать |
| --- | --- |
| Inbound | REALITY inbound из профиля, изменённого на предыдущем шаге |
| Address | `node.example.com` либо публичный IP этой VPS; подходящий существующий адрес можно сохранить |
| Port | Публичный порт inbound, например `8443` |
| Advanced Options → SNI | `node.example.com` — тот же домен, что в сертификате и `serverNames` |

**Удали прежний сторонний SNI из карточки Host.** Явно заданный SNI
переопределяет унаследованное значение. Вместо явного нового SNI можно
оставить поле пустым, чтобы наследовать `serverNames` из выбранного inbound.
Сохрани карточку. Подробнее о наследовании — в
[документации Remnawave Hosts](https://docs.rw/learn-en/hosts/).

Здесь Hosts — раздел панели Remnawave. Файл `/etc/hosts` на VPS менять
не требуется. Поле HTTP `Host` в транспортных настройках также не нужно
заполнять только ради self-steal для обычного TCP/REALITY.

В итоге адрес подключения ведёт на VPS, порт — на публичный REALITY inbound,
а SNI совпадает с доменом self-steal. В Address нельзя указывать
`127.0.0.1`, а в Port — локальный `9443`.

### 7. Обнови подписку и проверь клиент

Обнови подписку в клиентском приложении. Если используешь отдельно
импортированную ссылку, импортируй её актуальную версию. Проверь, что
в выбранном подключении указан новый SNI и правильный публичный порт.
Подключись к ноде и открой сайт через VPN.

Для обычной проверки сайта через публичный REALITY listener можно выполнить
с другого компьютера, подставив свой домен и порт:

```bash
curl -I --http2 https://node.example.com:8443/
```

В Windows PowerShell используй `curl.exe` вместо `curl`. Этот запрос
проверяет HTTPS-маскировку через публичный listener, но не авторизацию
VPN-клиента. Успешное подключение клиента проверяй отдельно.

### 8. Проверь повторный запуск

На VPS из папки проекта:

```bash
bash install.sh --install 2>&1 | tee install-repeat.log
bash check.sh
```

Установщик должен повторно использовать подходящий сертификат и свои
файлы. При ошибке сохрани лог текущего этапа. Не запускай `uninstall.sh`
для диагностики: он удалит сайт и локальный TLS endpoint, на который
уже может быть направлен REALITY target.

## Installer behavior

`--check` performs preflight checks without changing the system. `--install`
may install the `nginx`, `certbot`, `openssl` and `ca-certificates` Ubuntu
packages, create files under
`/etc/remnawave-selfsteal`, `/etc/nginx`, `/var/www/remnawave-selfsteal`
and `/etc/letsencrypt`, and start or reload nginx. It uses Certbot's webroot
mode; Certbot does not rewrite nginx configuration.
The first certificate request asks for a Let's Encrypt contact email.

The installer records its domain in
`/etc/remnawave-selfsteal/state.conf`. Repeating `--install` reuses an
existing valid certificate and expected files. It stops if a managed file
has different contents rather than overwriting it. If a package operation
was interrupted and `dpkg` reports an incomplete transaction, repair that
transaction manually before retrying.

After starting or reloading nginx, the installer waits up to 30 seconds
(plus the final probe timeout) for the expected HTTP challenge or TLS
endpoint to respond. It verifies both TLS 1.3 and negotiated HTTP/2.
Temporary marker files left by an interrupted write are cleaned only while
holding the installation lock, inside the root-owned mode-700 state
directory. Unexpected file types, owners or permissions stop cleanup.

`check.sh` reads installation state and checks DNS, nginx, HTTP, the
certificate, local TLS 1.3/HTTP/2, the renewal hook and the record of a
successful renewal dry run without making changes. Certbot's effective
webroot for the chosen domain is read from its configuration, including
the per-domain `webroot_map`. The successful dry-run record includes hashes
of the renewal configuration and deploy hook. A changed configuration
requires a new dry run on the next `--install`. Dry runs execute the deploy
hook as well. A failed dry run exits with an error and leaves installation
incomplete; repeat `--install` to retry.
`uninstall.sh` removes only verified installer-managed files. It leaves
the nginx and certbot packages installed and asks separately whether to
delete the Let's Encrypt certificate. Keeping the certificate after removal
requires a working HTTP-01 webroot for future renewals.
Uninstall refuses symbolic links in parent directories of managed paths
before removing installed files. Retained nginx packages mean a subsequent
fresh installation still falls under the existing-nginx restriction;
uninstall does not automatically purge packages or unrelated nginx sites.

These changes have not been tested in this editing pass. Live certificate
issuance/renewal, systemd behavior and the real Remnawave connection still
need verification on the test VPS before release.

## Release status

Version `v0.1.0` will be tagged after a clean Ubuntu 24.04 installation,
repeat run, interrupted-run recovery and uninstall have been exercised on
the test VPS. Until then, commands that download from `main` are not a
stable installation method.
