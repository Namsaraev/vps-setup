#!/bin/bash

set -e

# Отключаем интерактивные запросы debconf (КРИТИЧЕСКИ ВАЖНО для автоматизации)
export DEBIAN_FRONTEND=noninteractive

# ============================================
# НАСТРОЙКИ (меняйте здесь)
# ============================================
SSH_PORT=5829          # Ваш нестандартный порт SSH
NEW_USER="pin"         # Имя создаваемого пользователя

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_section() { echo -e "\n${CYAN}========== $1 ==========${NC}"; }

# Функция для интерактивного ввода (работает даже через pipe)
ask_input() {
    local prompt="$1"
    local var_name="$2"
    echo -n "$prompt" > /dev/tty
    read -r "$var_name" < /dev/tty
}

# Функция для скрытого ввода пароля
ask_password() {
    local prompt="$1"
    local var_name="$2"
    read -s -p "$prompt" "$var_name" < /dev/tty
    echo "" > /dev/tty
}

# Автоматический перезапуск через sudo
if [ "$EUID" -ne 0 ]; then
    print_info "Требуются права root. Перезапускаем скрипт через sudo..."
    exec sudo bash "$0" "$@"
fi

# ============================================
# ОПРЕДЕЛЕНИЕ ВЕРСИИ UBUNTU
# ============================================
if [ -f /etc/os-release ]; then
    . /etc/os-release
    UBUNTU_VERSION="$VERSION_ID"
    UBUNTU_CODENAME="$VERSION_CODENAME"
else
    print_error "Не удалось определить версию ОС. Скрипт поддерживает только Ubuntu."
    exit 1
fi

print_info "Скрипт запущен от имени root"
print_info "Обнаружена ОС: $PRETTY_NAME (версия: $UBUNTU_VERSION, кодовое имя: $UBUNTU_CODENAME)"

CURRENT_USER="${SUDO_USER:-root}"
if [ "$CURRENT_USER" = "root" ]; then
    USER_HOME="/root"
else
    USER_HOME="/home/$CURRENT_USER"
fi

print_info "Настройка будет выполнена для пользователя: $CURRENT_USER"
print_info "SSH порт: $SSH_PORT"
print_info "Новый пользователь: $NEW_USER"
echo ""

# ============================================
# 1. ОБНОВЛЕНИЕ СИСТЕМЫ
# ============================================
print_section "1. ОБНОВЛЕНИЕ СИСТЕМЫ"
print_info "Обновление системы..."
apt-get update -y
apt-get upgrade -y
apt-get autoremove -y
print_success "Система обновлена"

# ============================================
# 2. ЧАСОВОЙ ПОЯС
# ============================================
print_section "2. ЧАСОВОЙ ПОЯС"
print_info "Настройка часового пояса: Asia/Irkutsk"
timedatectl set-timezone Asia/Irkutsk
print_success "Часовой пояс установлен: $(timedatectl | grep 'Time zone')"

# ============================================
# 3. ЛОКАЛЬ
# ============================================
print_section "3. ЛОКАЛЬ"
print_info "Настройка русской локали..."
apt-get install -y language-pack-ru
locale-gen ru_RU.UTF-8
update-locale LANG=ru_RU.UTF-8
print_success "Русская локаль установлена"

# ============================================
# 4. БАЗОВЫЕ УТИЛИТЫ
# ============================================
print_section "4. БАЗОВЫЕ УТИЛИТЫ"
print_info "Установка базовых утилит..."
apt-get install -y \
    nano git curl wget unzip jq htop tmux net-tools dnsutils \
    bat eza fd-find ripgrep zoxide fzf \
    python3 python3-pip python3-venv build-essential \
    btop mtr iperf3 zsh
print_success "Базовые утилиты установлены"

# ============================================
# 5. СИМЛИНКИ
# ============================================
print_section "5. СИМЛИНКИ"
print_info "Создание симлинков для bat и fd..."
ln -sf /usr/bin/batcat /usr/local/bin/bat 2>/dev/null || true
ln -sf /usr/bin/fdfind /usr/local/bin/fd 2>/dev/null || true
print_success "Симлинки созданы"

# ============================================
# 6. SUDOERS (NOPASSWD)
# ============================================
print_section "6. SUDOERS"
print_info "Настройка sudoers для команд без пароля..."
SUDOERS_LINE="$CURRENT_USER ALL=(ALL) NOPASSWD: /usr/sbin/ufw, /usr/bin/journalctl"
if grep -q "$SUDOERS_LINE" /etc/sudoers 2>/dev/null; then
    print_warning "Правило sudoers уже существует"
else
    echo "$SUDOERS_LINE" | EDITOR='tee -a' visudo > /dev/null
    print_success "Sudoers настроен"
fi

# ============================================
# 7. СОЗДАНИЕ ПОЛЬЗОВАТЕЛЯ С ПАРОЛЕМ
# ============================================
print_section "7. СОЗДАНИЕ ПОЛЬЗОВАТЕЛЯ"
print_info "Проверка пользователя $NEW_USER..."

SET_PASSWORD=false

if id -u "$NEW_USER" &>/dev/null; then
    print_info "Пользователь $NEW_USER уже существует"
    
    PASS_STATUS=$(passwd -S "$NEW_USER" | awk '{print $2}')
    if [[ "$PASS_STATUS" == "P" ]]; then
        print_info "Пароль для $NEW_USER уже задан"
        ask_input "Заменить пароль для $NEW_USER? [y/N]: " CHANGE_PASS
        if [[ "$CHANGE_PASS" =~ ^[Yy]$ ]]; then
            SET_PASSWORD=true
        else
            print_info "Пароль оставляем без изменений"
        fi
    else
        print_warning "Пароль для $NEW_USER НЕ задан!"
        SET_PASSWORD=true
    fi
else
    print_warning "Пользователь $NEW_USER не найден в системе"
    ask_input "Создать пользователя $NEW_USER и добавить в группу sudo? [Y/n]: " CREATE_USER
    
    if [[ "$CREATE_USER" =~ ^[Yy]$ ]] || [[ -z "$CREATE_USER" ]]; then
        adduser --disabled-password --gecos "" "$NEW_USER"
        usermod -aG sudo "$NEW_USER"
        print_success "Пользователь $NEW_USER создан и добавлен в группу sudo"
        SET_PASSWORD=true
    else
        print_warning "Пропускаем создание пользователя $NEW_USER"
    fi
fi

# Установка/замена пароля
if [ "$SET_PASSWORD" = true ]; then
    echo ""
    print_info "Установка пароля для пользователя $NEW_USER"
    while true; do
        ask_password "Введите пароль для $NEW_USER: " USER_PASSWORD
        ask_password "Повторите пароль: " USER_PASSWORD_CONFIRM
        
        if [ -z "$USER_PASSWORD" ]; then
            print_error "Пароль не может быть пустым. Попробуйте снова."
        elif [ "$USER_PASSWORD" != "$USER_PASSWORD_CONFIRM" ]; then
            print_error "Пароли не совпадают. Попробуйте снова."
        else
            echo "$NEW_USER:$USER_PASSWORD" | chpasswd
            print_success "Пароль для $NEW_USER установлен"
            break
        fi
    done
fi

# ============================================
# 8. ДОБАВЛЕНИЕ SSH-КЛЮЧА ДЛЯ ПОЛЬЗОВАТЕЛЯ
# ============================================
print_section "8. SSH-КЛЮЧ ДЛЯ ПОЛЬЗОВАТЕЛЯ"
print_info "Проверка SSH-ключа для пользователя $NEW_USER..."

if [ ! -d "/home/$NEW_USER" ]; then
    print_warning "Пользователь $NEW_USER не существует. Пропускаем настройку SSH-ключа."
else
    PIN_SSH_DIR="/home/$NEW_USER/.ssh"
    PIN_AUTH_KEYS="$PIN_SSH_DIR/authorized_keys"
    SKIP_KEY=false
    
    if [ -f "$PIN_AUTH_KEYS" ] && [ -s "$PIN_AUTH_KEYS" ]; then
        KEY_COUNT=$(wc -l < "$PIN_AUTH_KEYS")
        print_info "SSH-ключ для $NEW_USER уже настроен ($KEY_COUNT шт.)"
        echo ""
        echo "Что сделать с SSH-ключом?"
        echo "  1) Добавить ещё один ключ (к существующим)"
        echo "  2) Удалить все ключи и добавить новый"
        echo "  3) Оставить как есть (пропустить)"
        ask_input "Ваш выбор [1/2/3]: " KEY_ACTION
        
        case "$KEY_ACTION" in
            1)
                print_info "Добавляем новый ключ к существующим"
                ;;
            2)
                print_warning "Удаляем все существующие ключи"
                rm -f "$PIN_AUTH_KEYS"
                ;;
            3)
                print_info "Пропускаем настройку SSH-ключа"
                SKIP_KEY=true
                ;;
            *)
                print_info "Пропускаем настройку SSH-ключа"
                SKIP_KEY=true
                ;;
        esac
    fi
    
    if [ "$SKIP_KEY" != "true" ]; then
        echo ""
        print_warning "⚠️  ВАЖНО: Добавьте SSH-ключ для $NEW_USER, чтобы не потерять доступ"
        echo ""
        echo "Выберите способ добавления ключа:"
        echo "  1) Вставить публичный ключ вручную (скопируйте содержимое id_ed25519.pub)"
        echo "  2) Указать путь к файлу ключа на сервере"
        echo "  3) Пропустить"
        ask_input "Ваш выбор [1/2/3]: " KEY_METHOD
        
        case "$KEY_METHOD" in
            1)
                echo ""
                print_info "Вставьте ваш публичный ключ одной строкой (начинается с ssh-ed25519 или ssh-rsa):"
                read -r PUBLIC_KEY < /dev/tty
                if [ -n "$PUBLIC_KEY" ]; then
                    mkdir -p "$PIN_SSH_DIR"
                    echo "$PUBLIC_KEY" >> "$PIN_AUTH_KEYS"
                    chown -R "$NEW_USER:$NEW_USER" "$PIN_SSH_DIR"
                    chmod 700 "$PIN_SSH_DIR"
                    chmod 600 "$PIN_AUTH_KEYS"
                    print_success "SSH-ключ добавлен для $NEW_USER"
                else
                    print_warning "Ключ не был добавлен (пустой ввод)"
                fi
                ;;
            2)
                ask_input "Введите путь к файлу публичного ключа: " KEY_PATH
                if [ -f "$KEY_PATH" ]; then
                    mkdir -p "$PIN_SSH_DIR"
                    cat "$KEY_PATH" >> "$PIN_AUTH_KEYS"
                    chown -R "$NEW_USER:$NEW_USER" "$PIN_SSH_DIR"
                    chmod 700 "$PIN_SSH_DIR"
                    chmod 600 "$PIN_AUTH_KEYS"
                    print_success "SSH-ключ добавлен из $KEY_PATH"
                else
                    print_error "Файл не найден: $KEY_PATH"
                fi
                ;;
            3)
                print_warning "Пропускаем добавление SSH-ключа"
                ;;
            *)
                print_warning "Неверный выбор. Пропускаем добавление SSH-ключа"
                ;;
        esac
    fi
fi

# ============================================
# 9. НАСТРОЙКА UFW ФАЕРВОЛА
# ============================================
print_section "9. НАСТРОЙКА UFW"
print_info "Проверка файрвола UFW..."

if ! command -v ufw &>/dev/null; then
    print_info "UFW не установлен. Устанавливаем..."
    apt-get install -y ufw
fi

if ufw status | grep -q "Status: active"; then
    print_info "UFW уже активен — пропускаем настройку"
    ufw status verbose
else
    print_warning "UFW не активен или не настроен"
    ask_input "Настроить UFW с базовыми правилами? [Y/n]: " SETUP_UFW
    
    if [[ "$SETUP_UFW" =~ ^[Yy]$ ]] || [[ -z "$SETUP_UFW" ]]; then
        print_info "Настройка политик по умолчанию..."
        ufw default deny incoming
        ufw default allow outgoing
        
        print_info "Открываем необходимые порты..."
        ufw allow 80/tcp comment 'HTTP & SSL'
        ufw allow 443/tcp comment 'HTTPS'
        ufw allow 8443/tcp comment 'HTTPS'
        ufw allow "$SSH_PORT/tcp" comment 'SSH'
        ufw allow 5201/tcp comment 'iperf3'
        ufw allow 5201/udp comment 'iperf3'
        
        print_info "Текущие правила UFW:"
        ufw status verbose 2>/dev/null || true
        
        echo ""
        print_warning "ВНИМАНИЕ: UFW будет активирован. Убедитесь, что ваш SSH порт ($SSH_PORT) открыт!"
        ask_input "Активировать UFW сейчас? [Y/n]: " ENABLE_UFW
        
        if [[ "$ENABLE_UFW" =~ ^[Yy]$ ]] || [[ -z "$ENABLE_UFW" ]]; then
            ufw --force enable
            print_success "UFW активирован"
            echo ""
            print_info "Финальный статус UFW:"
            ufw status verbose
        else
            print_warning "UFW настроен, но не активирован. Активируйте позже: sudo ufw enable"
        fi
    else
        print_warning "Пропускаем настройку UFW"
    fi
fi

# ============================================
# 10. НАСТРОЙКА SSH (МИНИМАЛЬНАЯ БЕЗОПАСНОСТЬ)
# ============================================
print_section "10. НАСТРОЙКА SSH"
print_info "Проверка настроек SSH..."
print_info "Версия Ubuntu: $UBUNTU_VERSION ($UBUNTU_CODENAME)"

SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_CONFIG_DIR="/etc/ssh/sshd_config.d"
BACKUP_FILE="/etc/ssh/sshd_config.backup.$(date +%Y%m%d_%H%M%S)"

# Проверяем, применены ли уже все нужные настройки
SSH_PORT_SET=$(grep -E "^Port $SSH_PORT$" "$SSHD_CONFIG" || true)
ROOT_LOGIN_SET=$(grep -E "^PermitRootLogin no$" "$SSHD_CONFIG" || true)
PASS_AUTH_SET=$(grep -E "^PasswordAuthentication no$" "$SSHD_CONFIG" || true)
EMPTY_PASS_SET=$(grep -E "^PermitEmptyPasswords no$" "$SSHD_CONFIG" || true)
PUBKEY_SET=$(grep -E "^PubkeyAuthentication yes$" "$SSHD_CONFIG" || true)

if [[ -n "$SSH_PORT_SET" && -n "$ROOT_LOGIN_SET" && -n "$PASS_AUTH_SET" && -n "$EMPTY_PASS_SET" && -n "$PUBKEY_SET" ]]; then
    print_info "SSH уже настроен правильно — пропускаем"
else
    print_warning "SSH требует настройки безопасности"
    echo ""
    print_warning "⚠️  БУДУТ ПРИМЕНЕНЫ СЛЕДУЮЩИЕ ИЗМЕНЕНИЯ (минимальный набор):"
    echo "    - Port $SSH_PORT (смена стандартного порта 22)"
    echo "    - PermitRootLogin no (запрет входа под root)"
    echo "    - PasswordAuthentication no (ВХОД ТОЛЬКО ПО КЛЮЧУ!)"
    echo "    - PermitEmptyPasswords no (запрет пустых паролей)"
    echo "    - PubkeyAuthentication yes (аутентификация по ключам)"
    echo "    - ChallengeResponseAuthentication no"
    echo "    - KbdInteractiveAuthentication no"
    echo "    - MaxAuthTries 3 (лимит попыток входа)"
    echo "    - LogLevel VERBOSE (подробные логи для fail2ban)"
    echo "    - PermitUserEnvironment no (безопасность)"
    echo ""
    print_info "SSH-туннели остаются разрешёнными (AllowTcpForwarding yes)"
    print_info "Сессии НЕ будут разрываться по таймауту"
    echo ""
    print_error "❗ После применения вы НЕ СМОЖЕТЕ зайти под root по SSH!"
    print_error "❗ Вход будет возможен ТОЛЬКО по SSH-ключу для пользователя $NEW_USER"
    echo ""
    
    # Проверка наличия ключа у pin
    KEEP_PASSWORD_AUTH=false
    if [ -f "/home/$NEW_USER/.ssh/authorized_keys" ] && [ -s "/home/$NEW_USER/.ssh/authorized_keys" ]; then
        KEY_COUNT=$(wc -l < "/home/$NEW_USER/.ssh/authorized_keys")
        print_success "SSH-ключ для $NEW_USER обнаружен ($KEY_COUNT шт.). Можно безопасно отключать пароли."
    else
        print_error "⚠️⚠️⚠️  У пользователя $NEW_USER НЕТ SSH-ключа!"
        print_error "Если отключить PasswordAuthentication, вы ПОЛНОСТЬЮ ПОТЕРЯЕТЕ доступ!"
        echo ""
        ask_input "Всё равно отключить вход по паролю? (НЕ РЕКОМЕНДУЕТСЯ) [y/N]: " FORCE_NO_PASS
        if [[ ! "$FORCE_NO_PASS" =~ ^[Yy]$ ]]; then
            print_warning "PasswordAuthentication останется включённым. Добавьте ключ и запустите скрипт снова."
            KEEP_PASSWORD_AUTH=true
        fi
    fi
    
    echo ""
    ask_input "Применить настройки SSH? [Y/n]: " APPLY_SSH
    
    if [[ "$APPLY_SSH" =~ ^[Yy]$ ]] || [[ -z "$APPLY_SSH" ]]; then
        # Создаём резервную копию
        cp "$SSHD_CONFIG" "$BACKUP_FILE"
        print_info "Резервная копия создана: $BACKUP_FILE"
        
        # ============================================
        # 10.1. ОБРАБОТКА ФАЙЛОВ В sshd_config.d
        # ============================================
        # В Ubuntu 24.04+ cloud-init может создавать файлы, переопределяющие настройки
        if [ -d "$SSHD_CONFIG_DIR" ]; then
            print_info "Проверка файлов в $SSHD_CONFIG_DIR..."
            
            for conf_file in "$SSHD_CONFIG_DIR"/*.conf; do
                if [ -f "$conf_file" ]; then
                    if grep -qE "^PasswordAuthentication yes" "$conf_file" 2>/dev/null; then
                        print_warning "Найден файл с PasswordAuthentication yes: $conf_file"
                        cp "$conf_file" "$conf_file.backup.$(date +%Y%m%d_%H%M%S)"
                        sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' "$conf_file"
                        print_success "Исправлено: $conf_file"
                    fi
                fi
            done
            
            # Создаём наш override файл с приоритетом
            CUSTOM_SSH_CONF="$SSHD_CONFIG_DIR/99-hardening.conf"
            print_info "Создание override файла: $CUSTOM_SSH_CONF"
            cat > "$CUSTOM_SSH_CONF" << HARDENING_EOF
# Hardening settings (создано скриптом tunevps.sh)
# Минимальный набор для безопасности, не мешающий работе
PasswordAuthentication no
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
HARDENING_EOF
            print_success "Override файл создан"
        fi
        
        # ============================================
        # 10.2. ПРИМЕНЕНИЕ НАСТРОЕК В sshd_config
        # ============================================
        print_info "Применяем настройки SSH в sshd_config..."
        
        # Функция для безопасной установки параметра
        set_ssh_param() {
            local param="$1"
            local value="$2"
            if grep -qE "^#?$param " "$SSHD_CONFIG"; then
                sed -i "s/^#\?$param .*/$param $value/" "$SSHD_CONFIG"
            else
                echo "$param $value" >> "$SSHD_CONFIG"
            fi
        }
        
        # === МИНИМАЛЬНЫЙ НАБОР НАСТРОЕК БЕЗОПАСНОСТИ ===
        
        # Основные настройки
        set_ssh_param "Port" "$SSH_PORT"
        set_ssh_param "PermitRootLogin" "no"
        set_ssh_param "PermitEmptyPasswords" "no"
        set_ssh_param "PubkeyAuthentication" "yes"
        
        # Отключение паролей (если не решили оставить)
        if [ "$KEEP_PASSWORD_AUTH" != "true" ]; then
            set_ssh_param "PasswordAuthentication" "no"
        fi
        
        # Отключение лишних методов аутентификации
        set_ssh_param "ChallengeResponseAuthentication" "no"
        set_ssh_param "KbdInteractiveAuthentication" "no"
        
        # Защита от brute-force
        set_ssh_param "MaxAuthTries" "3"
        
        # Подробные логи для fail2ban
        set_ssh_param "LogLevel" "VERBOSE"
        
        # Безопасность (не мешает работе)
        set_ssh_param "PermitUserEnvironment" "no"
        
        # === ЧТО МЫ НЕ ТРОГАЕМ (оставляем по умолчанию) ===
        # AllowTcpForwarding - разрешены SSH-туннели (нужны вам)
        # PermitTunnel - разрешены туннели
        # AllowAgentForwarding - разрешён agent forwarding
        # X11Forwarding - оставляем как есть
        # ClientAliveInterval - НЕ устанавливаем (сессии не рвутся)
        # ClientAliveCountMax - НЕ устанавливаем
        # LoginGraceTime - оставляем по умолчанию
        # MaxSessions - оставляем по умолчанию
        
        print_success "Настройки SSH применены (минимальный набор)"
        
        # ============================================
        # 10.3. НАСТРОЙКА ПОРТА ЧЕРЕЗ SYSTEMD SOCKET (Ubuntu 24.04+)
        # ============================================
        print_info "Проверка systemd socket activation..."
        
        if systemctl is-active --quiet ssh.socket 2>/dev/null || systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
            print_info "Обнаружен systemd socket activation (Ubuntu 24.04+)"
            
            SSH_SOCKET_OVERRIDE="/etc/systemd/system/ssh.socket.d/override.conf"
            
            if [ -f "$SSH_SOCKET_OVERRIDE" ] && grep -q "ListenStream=$SSH_PORT" "$SSH_SOCKET_OVERRIDE"; then
                print_info "Порт $SSH_PORT уже настроен в ssh.socket"
            else
                print_info "Настраиваем порт $SSH_PORT в ssh.socket..."
                
                mkdir -p /etc/systemd/system/ssh.socket.d
                
                cat > "$SSH_SOCKET_OVERRIDE" << SOCKET_EOF
[Socket]
ListenStream=
ListenStream=$SSH_PORT
SOCKET_EOF
                
                print_success "Создан override: $SSH_SOCKET_OVERRIDE"
                
                systemctl daemon-reload
                print_info "systemd daemon перезагружен"
                
                systemctl restart ssh.socket
                print_success "ssh.socket перезапущен"
                
                sleep 2
                if ss -tuln | grep -q ":$SSH_PORT "; then
                    print_success "SSH слушает порт $SSH_PORT"
                else
                    print_error "SSH НЕ слушает порт $SSH_PORT! Проверьте: ss -tulnp | grep ssh"
                fi
            fi
        else
            print_info "Socket activation не используется, порт берётся из sshd_config"
        fi
        
        # ============================================
        # 10.4. ПРОВЕРКА СИНТАКСИСА И ПЕРЕЗАПУСК
        # ============================================
        print_info "Проверка синтаксиса sshd_config..."
        if sshd -t; then
            print_success "Синтаксис корректен. Перезапускаем SSH..."
            systemctl restart ssh
            print_success "SSH перезапущен с новыми настройками"
            
            sleep 2
            if ss -tuln | grep -q ":$SSH_PORT "; then
                print_success "ИТОГОВАЯ ПРОВЕРКА: SSH слушает порт $SSH_PORT ✓"
            else
                print_error "ИТОГОВАЯ ПРОВЕРКА: SSH НЕ слушает порт $SSH_PORT!"
                print_error "Проверьте: sudo ss -tulnp | grep ssh"
            fi
        else
            print_error "ОШИБКА СИНТАКСИСА! Откатываем изменения..."
            cp "$BACKUP_FILE" "$SSHD_CONFIG"
            print_warning "Восстановлен оригинальный конфиг из: $BACKUP_FILE"
            print_error "SSH НЕ был перезапущен. Проверьте конфиг вручную."
        fi
    else
        print_warning "Пропускаем настройку SSH"
    fi
fi

# ============================================
# 11. УСТАНОВКА И НАСТРОЙКА FAIL2BAN
# ============================================
print_section "11. FAIL2BAN (защита от brute-force)"
print_info "Проверка fail2ban..."

if ! command -v fail2ban-client &>/dev/null; then
    print_info "fail2ban не установлен. Устанавливаем..."
    apt-get install -y fail2ban
    print_success "fail2ban установлен"
else
    print_info "fail2ban уже установлен"
fi

FAIL2BAN_JAIL="/etc/fail2ban/jail.local"

if [ -f "$FAIL2BAN_JAIL" ] && grep -q "port = $SSH_PORT" "$FAIL2BAN_JAIL"; then
    print_info "fail2ban уже настроен для порта $SSH_PORT"
    ask_input "Перенастроить fail2ban? [y/N]: " RECONFIGURE_F2B
    if [[ ! "$RECONFIGURE_F2B" =~ ^[Yy]$ ]]; then
        print_info "Пропускаем настройку fail2ban"
        SKIP_F2B=true
    fi
else
    SKIP_F2B=false
fi

if [ "$SKIP_F2B" != "true" ]; then
    print_info "Создание конфигурации fail2ban..."
    
    if [ -f "$FAIL2BAN_JAIL" ]; then
        cp "$FAIL2BAN_JAIL" "$FAIL2BAN_JAIL.backup.$(date +%Y%m%d_%H%M%S)"
        print_info "Резервная копия старого jail.local создана"
    fi
    
    cat > "$FAIL2BAN_JAIL" << F2B_EOF
# ============================================
# Fail2ban конфигурация для защиты от brute-force
# Создано автоматически скриптом tunevps.sh
# ============================================

[DEFAULT]
# Игнорировать локальные IP (никогда не блокировать себя)
# Добавьте свой статический IP, если он есть:
# ignoreip = 127.0.0.1/8 ::1 YOUR_STATIC_IP/32
ignoreip = 127.0.0.1/8 ::1

# Время блокировки (в секундах): 3600 = 1 час
bantime = 3600

# Временное окно для подсчёта попыток (в секундах): 600 = 10 минут
findtime = 600

# Максимум попыток перед блокировкой
maxretry = 3

# Увеличивать время блокировки при повторных атаках
bantime.increment = true
bantime.factor = 2
bantime.maxtime = 86400

# ============================================
# Защита SSH
# ============================================
[sshd]
enabled = true
port = $SSH_PORT
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
findtime = 600

# Агрессивный режим для повторных нарушителей
mode = aggressive
F2B_EOF
    
    print_success "Конфигурация fail2ban создана: $FAIL2BAN_JAIL"
    
    print_info "Активация fail2ban..."
    systemctl enable fail2ban
    systemctl restart fail2ban
    
    sleep 3
    if systemctl is-active --quiet fail2ban; then
        print_success "fail2ban запущен и активен"
        echo ""
        print_info "Статус fail2ban:"
        fail2ban-client status
        echo ""
        print_info "Статус jail sshd:"
        fail2ban-client status sshd || true
    else
        print_error "fail2ban не запустился! Проверьте: sudo journalctl -u fail2ban -n 30"
    fi
fi

# ============================================
# 12. ZSH
# ============================================
print_section "12. ZSH"
print_info "Проверка Zsh..."
CURRENT_SHELL=$(getent passwd "$CURRENT_USER" | cut -d: -f7)
if [[ "$CURRENT_SHELL" == *"zsh"* ]]; then
    print_info "Zsh уже является оболочкой по умолчанию для $CURRENT_USER"
else
    print_info "Установка Zsh как оболочки по умолчанию..."
    chsh -s $(which zsh) "$CURRENT_USER"
    print_success "Zsh установлен как оболочка по умолчанию"
fi

# ============================================
# 13. OH MY ZSH
# ============================================
print_section "13. OH MY ZSH"
print_info "Проверка Oh My Zsh..."
if [ ! -d "$USER_HOME/.oh-my-zsh" ]; then
    print_info "Установка Oh My Zsh..."
    export RUNZSH=no
    export KEEP_ZSHRC=no
    if [ "$CURRENT_USER" = "root" ]; then
        sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
    else
        sudo -u "$CURRENT_USER" sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
    fi
    print_success "Oh My Zsh установлен"
else
    print_info "Oh My Zsh уже установлен"
fi

# ============================================
# 14. POWERLEVEL10K
# ============================================
print_section "14. POWERLEVEL10K"
print_info "Проверка Powerlevel10k..."
ZSH_CUSTOM_DIR="$USER_HOME/.oh-my-zsh/custom"
if [ ! -d "$ZSH_CUSTOM_DIR/themes/powerlevel10k" ]; then
    print_info "Установка Powerlevel10k..."
    if [ "$CURRENT_USER" = "root" ]; then
        git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$ZSH_CUSTOM_DIR/themes/powerlevel10k"
    else
        sudo -u "$CURRENT_USER" git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$ZSH_CUSTOM_DIR/themes/powerlevel10k"
    fi
    print_success "Powerlevel10k установлен"
else
    print_info "Powerlevel10k уже установлен"
fi

# ============================================
# 15. ПЛАГИНЫ OMZ
# ============================================
print_section "15. ПЛАГИНЫ OMZ"
print_info "Проверка плагинов Oh My Zsh..."
clone_plugin() {
    local name=$1
    local url=$2
    if [ ! -d "$ZSH_CUSTOM_DIR/plugins/$name" ]; then
        print_info "Установка плагина: $name"
        if [ "$CURRENT_USER" = "root" ]; then
            git clone "$url" "$ZSH_CUSTOM_DIR/plugins/$name"
        else
            sudo -u "$CURRENT_USER" git clone "$url" "$ZSH_CUSTOM_DIR/plugins/$name"
        fi
    else
        print_info "Плагин $name уже установлен"
    fi
}

clone_plugin "zsh-autosuggestions" "https://github.com/zsh-users/zsh-autosuggestions"
clone_plugin "zsh-syntax-highlighting" "https://github.com/zsh-users/zsh-syntax-highlighting.git"
clone_plugin "zsh-completions" "https://github.com/zsh-users/zsh-completions"
print_success "Плагины проверены"

# ============================================
# 16. .zshrc
# ============================================
print_section "16. КОНФИГУРАЦИЯ .zshrc"
print_info "Создание конфигурации .zshrc..."
cat > "$USER_HOME/.zshrc" << 'EOF'
# Enable Powerlevel10k instant prompt
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="powerlevel10k/powerlevel10k"

plugins=(
    git
    zsh-autosuggestions
    zsh-syntax-highlighting
    zsh-completions
    zoxide
    fzf
    sudo
    extract
    docker
)

source $ZSH/oh-my-zsh.sh

# === Алиасы на современные утилиты ===
alias cat="bat --paging=never"
alias ls="eza --icons"
alias ll="eza -la --icons --git"
alias lt="eza --tree --icons --level=2"
alias grep="rg"
alias fd="fd"
alias cd="z"
alias top="btop"

# === Удобные алиасы ===
alias ..="cd .."
alias ...="cd ../.."
alias ports="ss -tulnp"
alias myip="curl -s ifconfig.me"
alias h="history"
alias hg="history | grep"
alias reload="source ~/.zshrc"

# === UFW (Firewall) ===
alias ufwv="sudo ufw status verbose"
alias ufwn="sudo ufw status numbered"
alias ufwl="sudo journalctl -u ufw -n 50 --no-pager"

# === Fail2ban ===
alias f2bs="sudo fail2ban-client status"
alias f2bssh="sudo fail2ban-client status sshd"

# === SSH безопасность ===
alias sshlog="sudo journalctl -u ssh -n 50 --no-pager"
alias sshcheck="sudo sshd -t && echo 'SSH config OK'"

# === FZF (универсальный способ для всех Ubuntu 22/24/26) ===
source <(fzf --zsh)

# === Zoxide (умный cd) ===
eval "$(zoxide init zsh)"

# === Powerlevel10k config ===
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh
EOF
print_success "Файл .zshrc создан"

# ============================================
# 17. ПРАВА ДОСТУПА
# ============================================
print_section "17. ПРАВА ДОСТУПА"
if [ "$CURRENT_USER" != "root" ]; then
    chown -R "$CURRENT_USER:$CURRENT_USER" "$USER_HOME/.oh-my-zsh"
    chown "$CURRENT_USER:$CURRENT_USER" "$USER_HOME/.zshrc"
fi
print_success "Права доступа настроены"

# ============================================
# 18. ФИНАЛЬНАЯ ПРОВЕРКА
# ============================================
print_section "18. ФИНАЛЬНАЯ ПРОВЕРКА"

print_info "Проверка SSH порта..."
if ss -tuln | grep -q ":$SSH_PORT "; then
    print_success "SSH слушает порт $SSH_PORT ✓"
else
    print_error "SSH НЕ слушает порт $SSH_PORT! ⚠️"
fi

print_info "Проверка статуса SSH..."
if systemctl is-active --quiet ssh; then
    print_success "SSH сервис активен ✓"
else
    print_error "SSH сервис НЕ активен! ⚠️"
fi

print_info "Проверка настроек SSH..."
PASS_AUTH_FINAL=$(grep -E "^PasswordAuthentication" "$SSHD_CONFIG" | tail -1 || true)
if [[ "$PASS_AUTH_FINAL" == *"no"* ]]; then
    print_success "PasswordAuthentication отключён ✓"
else
    print_warning "PasswordAuthentication всё ещё включён ⚠️"
fi

print_info "Проверка fail2ban..."
if systemctl is-active --quiet fail2ban; then
    print_success "fail2ban активен ✓"
else
    print_warning "fail2ban НЕ активен"
fi

print_info "Проверка UFW..."
if ufw status | grep -q "Status: active"; then
    print_success "UFW активен ✓"
else
    print_warning "UFW НЕ активен"
fi

# ============================================
# ФИНАЛ
# ============================================
echo ""
echo "=========================================="
print_success "Настройка завершена!"
echo "=========================================="
echo ""
print_info "ВАЖНО: Для применения всех изменений:"
echo ""
echo "  1. Выйдите из текущей SSH-сессии: exit"
echo "  2. Зайдите снова на сервер через порт $SSH_PORT:"
echo "     ssh -p $SSH_PORT $NEW_USER@YOUR_SERVER_IP"
echo "  3. При первом входе запустите настройку Powerlevel10k: p10k configure"
echo "  4. Установите шрифт MesloLGS NF на ваш локальный компьютер:"
echo "     https://github.com/romkatv/powerlevel10k#fonts"
echo ""
echo "Полезные алиасы для управления безопасностью:"
echo "  f2bs      - статус fail2ban"
echo "  f2bssh    - статус jail sshd (заблокированные IP)"
echo "  ufwv      - статус файрвола"
echo "  ufwn      - правила файрвола с номерами"
echo "  sshlog    - последние логи SSH"
echo "  sshcheck  - проверка синтаксиса sshd_config"
echo ""
echo "Что разрешено на сервере:"
echo "  ✅ SSH-туннели (AllowTcpForwarding yes)"
echo "  ✅ Сессии живут бесконечно (нет таймаутов)"
echo "  ✅ tmux/screen для долгоживущих задач"
echo "  ✅ Agent forwarding"
echo ""
if [[ -f "$BACKUP_FILE" ]] 2>/dev/null; then
    print_warning "Резервная копия sshd_config: $BACKUP_FILE"
fi
print_error "⚠️  ВХОД ПО ПАРОЛЮ ОТКЛЮЧЁН! Только по SSH-ключу!"
print_error "⚠️  Вход под root по SSH ЗАПРЕЩЁН!"
print_warning "fail2ban автоматически блокирует атакующих после 3 неудачных попыток"
echo ""
