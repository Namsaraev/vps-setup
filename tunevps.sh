#!/bin/bash
export DEBIAN_FRONTEND=noninteractive

# ============================================
# НАСТРОЙКИ
# ============================================
SSH_PORT=5829
NEW_USER="pin"
SWAP_RAM_THRESHOLD_MB=2048
SWAP_SIZE="2G"

# ============================================
# ЦВЕТА И УТИЛИТЫ
# ============================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_section() { echo -e "\n${CYAN}========== $1 ==========${NC}"; }

ask_input() {
    local prompt="$1"
    local var_name="$2"
    echo -n "$prompt" > /dev/tty
    read -r "$var_name" < /dev/tty
}

ask_password() {
    local prompt="$1"
    local var_name="$2"
    read -s -p "$prompt" "$var_name" < /dev/tty
    echo "" > /dev/tty
}

pause() {
    local prompt="${1:-Нажмите Enter для продолжения...}"
    echo -n "$prompt" > /dev/tty
    read -r < /dev/tty
}

# ============================================
# АВТО-ПОВЫШЕНИЕ ДО ROOT
# ============================================
if [ "$EUID" -ne 0 ]; then
    print_info "Требуются права root. Перезапускаем через sudo..."
    exec sudo bash "$0" "$@"
fi

# ============================================
# ОПРЕДЕЛЕНИЕ ОС
# ============================================
if [ -f /etc/os-release ]; then
    . /etc/os-release
    UBUNTU_VERSION="$VERSION_ID"
    UBUNTU_CODENAME="$VERSION_CODENAME"
else
    print_error "Не удалось определить ОС"
    exit 1
fi

# Определение minimized системы
IS_MINIMIZED=false
if command -v dpkg-query >/dev/null 2>&1; then
    if dpkg-query -W -f='${Status}' ubuntu-minimal 2>/dev/null | grep -q "install ok installed"; then
        if ! dpkg-query -W -f='${Status}' ubuntu-standard 2>/dev/null | grep -q "install ok installed"; then
            IS_MINIMIZED=true
        fi
    fi
fi

ARCH=$(uname -m)

print_info "ОС: $PRETTY_NAME"
print_info "Версия: $UBUNTU_VERSION ($UBUNTU_CODENAME)"
print_info "Архитектура: $ARCH"
print_info "Вариант: $([ "$IS_MINIMIZED" = true ] && echo "MINIMIZED ⚠️" || echo "Standard ✓")"

CURRENT_USER="${SUDO_USER:-root}"
if [ "$CURRENT_USER" = "root" ]; then
    USER_HOME="/root"
else
    USER_HOME="/home/$CURRENT_USER"
fi

# ============================================
# ГЛАВНОЕ МЕНЮ
# ============================================
show_menu() {
    clear
    echo -e "${MAGENTA}"
    cat << 'EOF'
╔══════════════════════════════════════════════════════╗
║           🚀 VPS SETUP - Меню действий 🚀            ║
╠══════════════════════════════════════════════════════╣
║                                                      ║
║  1) Первое обновление системы                         ║
║     └─ unminimize (если нужно) + apt update/upgrade  ║
║                                                      ║
║  2) Настройка рабочего пространства                  ║
║     └─ Утилиты, Zsh, SSH, UFW, пользователь pin      ║
║                                                      ║
║  3) Тесты и диагностика                              ║
║     └─ iPerf, YABS, Speedtest, IP-check, etc.        ║
║                                                      ║
║  4) Полный цикл (1 → reboot → 2)                     ║
║                                                      ║
║  0) Выход                                            ║
║                                                      ║
╚══════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
    if [ "$IS_MINIMIZED" = true ]; then
        print_warning "⚠️  ОБНАРУЖЕНА MINIMIZED СИСТЕМА — начните с пункта 1!"
    fi
}

# ============================================
# ЧАСТЬ 1: ПЕРВОЕ ОБНОВЛЕНИЕ + UNMINIMIZE
# ============================================
part1_update() {
    print_section "ЧАСТЬ 1: ПЕРВОЕ ОБНОВЛЕНИЕ СИСТЕМЫ"

    # === ПРОВЕРКА MINIMIZED ===
    if [ "$IS_MINIMIZED" = true ]; then
        print_warning "⚠️  ОБНАРУЖЕНА MINIMIZED ВЕРСИЯ UBUNTU!"
        print_warning "    Эта версия содержит минимальный набор пакетов"
        print_warning "    и может вызывать проблемы с работой скрипта."
        echo ""
        print_info "Рекомендуется восстановить полную версию Ubuntu"
        print_info "Это установит ~100 базовых пакетов (man, less, wget, etc.)"
        print_info "Займёт 2-5 минут и ~400 МБ дискового пространства"
        echo ""
        ask_input "Выполнить unminimize для восстановления полной Ubuntu? [Y/n]: " DO_UNMINIMIZE

        if [[ "$DO_UNMINIMIZE" =~ ^[Nn]$ ]]; then
            print_warning "Пропускаем unminimize"
            print_error "ВНИМАНИЕ: Скрипт может работать некорректно на minimized системе!"
            print_error "Рекомендуется запустить 'sudo unminimize' вручную"
        else
            print_info "Обновление apt для получения пакета unminimize..."
            apt-get update -y

            if ! command -v unminimize >/dev/null 2>&1; then
                print_info "Установка пакета unminimize..."
                apt-get install -y unminimize || {
                    print_error "Не удалось установить unminimize"
                    return 1
                }
            fi

            print_info "Восстановление полной Ubuntu (это займёт 2-5 минут)..."
            set +e
            yes | unminimize 2>&1 | tee /tmp/unminimize.log
            UNMINIMIZE_EXIT=${PIPESTATUS[1]}
            set -e

            if [ "$UNMINIMIZE_EXIT" -eq 0 ]; then
                print_success "Система восстановлена до полной Ubuntu ✓"
                IS_MINIMIZED=false
            else
                print_error "unminimize завершился с кодом $UNMINIMIZE_EXIT"
                print_warning "Проверьте лог: cat /tmp/unminimize.log"
            fi
        fi
    else
        print_success "Система уже является полной Ubuntu ✓"
    fi

    # === ОБНОВЛЕНИЕ ПАКЕТОВ ===
    print_info "Обновление списков пакетов..."
    apt-get update -y

    print_info "Обновление системы (это может занять время)..."
    apt-get upgrade -y

    print_info "Удаление ненужных пакетов..."
    apt-get autoremove -y

    print_success "Система обновлена!"

    echo ""
    print_warning "Рекомендуется перезагрузить сервер для применения всех обновлений"
    ask_input "Перезагрузить сервер сейчас? [Y/n]: " REBOOT_NOW

    if [[ "$REBOOT_NOW" =~ ^[Nn]$ ]]; then
        print_info "Перезагрузка отменена. Не забудьте перезагрузить позже!"
    else
        print_warning "Перезагрузка через 5 секунд..."
        sleep 5
        reboot
    fi
}

# ============================================
# ЧАСТЬ 2: НАСТРОЙКА РАБОЧЕГО ПРОСТРАНСТВА
# ============================================
part2_setup() {
    print_section "ЧАСТЬ 2: НАСТРОЙКА РАБОЧЕГО ПРОСТРАНСТВА"

    # === ПРОВЕРКА MINIMIZED ===
    if [ "$IS_MINIMIZED" = true ]; then
        print_error "⚠️  ОБНАРУЖЕНА MINIMIZED ВЕРСИЯ UBUNTU!"
        print_error "    Скрипт может работать некорректно."
        echo ""
        print_warning "Рекомендуется:"
        print_warning "  1. Выйти из скрипта"
        print_warning "  2. Запустить пункт 1 (Первое обновление)"
        print_warning "  3. Выполнить unminimize"
        print_warning "  4. Перезагрузить сервер"
        print_warning "  5. Запустить скрипт снова"
        echo ""
        ask_input "Продолжить настройку на minimized системе? (НЕ РЕКОМЕНДУЕТСЯ) [y/N]: " CONTINUE_MINIMIZED

        if [[ ! "$CONTINUE_MINIMIZED" =~ ^[Yy]$ ]]; then
            print_info "Отмена. Вернитесь в меню и выберите пункт 1"
            return 1
        fi

        print_warning "Продолжаем на minimized системе (могут быть ошибки)..."
    fi

    # --- 2.1 Часовой пояс ---
    print_section "2.1 ЧАСОВОЙ ПОЯС"
    timedatectl set-timezone Asia/Irkutsk
    print_success "Часовой пояс: $(LC_ALL=C timedatectl | grep 'Time zone')"

    # --- 2.2 Локаль ---
    print_section "2.2 ЛОКАЛЬ"
    apt-get install -y language-pack-ru locales 2>/dev/null || apt-get install -y locales
    locale-gen ru_RU.UTF-8
    locale-gen en_US.UTF-8

    sed -i '/^LC_ALL/d' /etc/default/locale 2>/dev/null || true
    sed -i '/^LC_ALL/d' /etc/environment 2>/dev/null || true

    update-locale LANG=ru_RU.UTF-8
    update-locale LC_MESSAGES=ru_RU.UTF-8
    update-locale LC_TIME=ru_RU.UTF-8
    print_success "Русская локаль установлена"

    # --- 2.3 Восстановление minimized ---
    if [ "$IS_MINIMIZED" = true ]; then
        print_warning "Установка базовых пакетов для minimized..."
        apt-get install -y ubuntu-standard man-db bsdmainutils || true
        print_success "Базовые пакеты установлены"
    fi

    # --- 2.4 Базовые утилиты ---
    print_section "2.4 БАЗОВЫЕ УТИЛИТЫ"
    apt-get install -y \
        nano git curl wget unzip jq htop tmux net-tools dnsutils \
        bat eza fd-find ripgrep \
        python3 python3-pip python3-venv build-essential \
        btop mtr iperf3 zsh sysbench \
        software-properties-common apt-transport-https ca-certificates gnupg \
        bsdmainutils ncdu iotop

    print_success "Базовые утилиты установлены"

    # --- 2.5 Установка FZF ---
    print_section "2.5 УСТАНОВКА FZF"
    apt-get install -y fzf || true
    print_success "FZF установлен"

    # --- 2.6 Установка Zoxide ---
    print_section "2.6 УСТАНОВКА ZOXIDE"
    if ! command -v zoxide >/dev/null 2>&1; then
        print_info "Установка zoxide через официальный установщик..."
        curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | bash -s -- --install-dir /usr/local/bin
        print_success "zoxide установлен в /usr/local/bin"
    else
        print_info "zoxide уже установлен"
    fi

    # --- 2.7 Системные улучшения ---
    print_section "2.7 СИСТЕМНЫЕ УЛУЧШЕНИЯ"

    # Энтропия для VPS
    apt-get install -y haveged 2>/dev/null || apt-get install -y rng-tools5 2>/dev/null || true
    print_success "Энтропия настроена"

    # Авто-обновления безопасности
    apt-get install -y unattended-upgrades
    cat > /etc/apt/apt.conf.d/20auto-upgrades << 'AUTOUPGRADE'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
AUTOUPGRADE
    print_success "Авто-обновления безопасности включены"

    # needrestart
    apt-get install -y needrestart
    sed -i 's/#\$nrconf{restart} =.*/\$nrconf{restart} = "a";/' /etc/needrestart/needrestart.conf 2>/dev/null || true
    print_success "needrestart настроен"

    # --- 2.8 Системные лимиты и сетевые оптимизации ---
    print_section "2.8 СИСТЕМНЫЕ ЛИМИТЫ И СЕТЬ"

    cat > /etc/sysctl.d/99-vps-tuning.conf << 'SYSCTL'
# === Сетевая безопасность ===
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# === BBR — быстрый TCP-контроль ===
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# === Сетевая производительность ===
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_window_scaling = 1
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# === Высокие лимиты для нагруженных серверов (nginx, xray) ===
fs.file-max = 1048576
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535

# === Защита от fork bomb ===
kernel.pid_max = 65536
SYSCTL
    sysctl --system > /dev/null 2>&1
    print_success "sysctl настроен (BBR + безопасность + лимиты)"

    # Лимиты открытых файлов для пользователей
    cat > /etc/security/limits.d/99-vps.conf << 'LIMITS'
*    soft nofile 524288
*    hard nofile 1048576
root soft nofile 524288
root hard nofile 1048576
LIMITS
    print_success "Файловые лимиты настроены"

    # --- 2.9 Swap ---
    print_section "2.9 SWAP"
    if [ "$(swapon --show | wc -l)" -eq 0 ]; then
        RAM_MB=$(free -m | awk '/Mem:/ {print $2}')
        if [ "$RAM_MB" -lt "$SWAP_RAM_THRESHOLD_MB" ]; then
            print_info "RAM < ${SWAP_RAM_THRESHOLD_MB}MB, создаём swap ${SWAP_SIZE}..."
            fallocate -l "$SWAP_SIZE" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048
            chmod 600 /swapfile
            mkswap /swapfile
            swapon /swapfile
            echo '/swapfile none swap sw 0 0' >> /etc/fstab
            print_success "Swap ${SWAP_SIZE} создан"
        else
            print_info "RAM >= ${SWAP_RAM_THRESHOLD_MB}MB, swap не создаётся"
        fi
    else
        print_info "Swap уже настроен"
    fi

    # --- 2.10 Симлинки ---
    print_section "2.10 СИМЛИНКИ"
    ln -sf /usr/bin/batcat /usr/local/bin/bat 2>/dev/null || true
    ln -sf /usr/bin/fdfind /usr/local/bin/fd 2>/dev/null || true
    print_success "Симлинки bat/fd созданы"

    # --- 2.11 Sudoers ---
    print_section "2.11 SUDOERS"
    SUDOERS_LINE="$CURRENT_USER ALL=(ALL) NOPASSWD: /usr/sbin/ufw, /usr/bin/journalctl, /usr/bin/systemctl"
    if ! grep -qF "$SUDOERS_LINE" /etc/sudoers 2>/dev/null; then
        echo "$SUDOERS_LINE" | EDITOR='tee -a' visudo > /dev/null
        print_success "Sudoers настроен"
    else
        print_info "Sudoers уже настроен"
    fi

    # --- 2.12 Создание пользователя pin ---
    print_section "2.12 СОЗДАНИЕ ПОЛЬЗОВАТЕЛЯ $NEW_USER"
    SET_PASSWORD=false
    if id -u "$NEW_USER" &>/dev/null; then
        print_info "Пользователь $NEW_USER уже существует"
        PASS_STATUS=$(passwd -S "$NEW_USER" | awk '{print $2}')
        if [[ "$PASS_STATUS" == "P" ]]; then
            print_info "Пароль для $NEW_USER уже задан"
            ask_input "Заменить пароль для $NEW_USER? [y/N]: " CHANGE_PASS
            if [[ "$CHANGE_PASS" =~ ^[Yy]$ ]]; then
                SET_PASSWORD=true
            fi
        else
            print_warning "Пароль для $NEW_USER НЕ задан!"
            SET_PASSWORD=true
        fi
    else
        print_warning "Пользователь $NEW_USER не найден"
        ask_input "Создать пользователя $NEW_USER и добавить в sudo? [Y/n]: " CREATE_USER
        if [[ "$CREATE_USER" =~ ^[Yy]$ ]] || [[ -z "$CREATE_USER" ]]; then
            adduser --disabled-password --gecos "" "$NEW_USER"
            usermod -aG sudo "$NEW_USER"
            print_success "Пользователь $NEW_USER создан"
            SET_PASSWORD=true
        else
            print_warning "Пропускаем создание пользователя"
        fi
    fi

    if [ "$SET_PASSWORD" = true ]; then
        echo ""
        print_info "Установка пароля для $NEW_USER"
        while true; do
            ask_password "Введите пароль для $NEW_USER: " USER_PASSWORD
            ask_password "Повторите пароль: " USER_PASSWORD_CONFIRM
            if [ -z "$USER_PASSWORD" ]; then
                print_error "Пароль не может быть пустым"
            elif [ "$USER_PASSWORD" != "$USER_PASSWORD_CONFIRM" ]; then
                print_error "Пароли не совпадают"
            else
                echo "$NEW_USER:$USER_PASSWORD" | chpasswd
                print_success "Пароль установлен"
                break
            fi
        done
    fi

    # --- 2.13 SSH-ключ ---
    print_section "2.13 SSH-КЛЮЧ"
    if [ -d "/home/$NEW_USER" ]; then
        PIN_SSH_DIR="/home/$NEW_USER/.ssh"
        PIN_AUTH_KEYS="$PIN_SSH_DIR/authorized_keys"
        SKIP_KEY=false

        if [ -f "$PIN_AUTH_KEYS" ] && [ -s "$PIN_AUTH_KEYS" ]; then
            KEY_COUNT=$(wc -l < "$PIN_AUTH_KEYS")
            print_info "SSH-ключ уже настроен ($KEY_COUNT шт.)"
            echo ""
            echo "Что сделать с SSH-ключом?"
            echo "  1) Добавить ещё один ключ"
            echo "  2) Удалить все и добавить новый"
            echo "  3) Пропустить"
            ask_input "Ваш выбор [1/2/3]: " KEY_ACTION
            case "$KEY_ACTION" in
                1) print_info "Добавляем новый ключ" ;;
                2) rm -f "$PIN_AUTH_KEYS" ;;
                3) SKIP_KEY=true ;;
                *) SKIP_KEY=true ;;
            esac
        fi

        if [ "$SKIP_KEY" != "true" ]; then
            echo ""
            print_warning "⚠️  ВАЖНО: Добавьте SSH-ключ для $NEW_USER"
            echo ""
            echo "Выберите способ добавления ключа:"
            echo "  1) Вставить публичный ключ вручную"
            echo "  2) Путь к файлу ключа на сервере"
            echo "  3) Пропустить"
            ask_input "Ваш выбор [1/2/3]: " KEY_METHOD

            case "$KEY_METHOD" in
                1)
                    echo ""
                    print_info "Вставьте ваш публичный ключ одной строкой:"
                    read -r PUBLIC_KEY < /dev/tty
                    if [ -n "$PUBLIC_KEY" ]; then
                        mkdir -p "$PIN_SSH_DIR"
                        echo "$PUBLIC_KEY" >> "$PIN_AUTH_KEYS"
                        chown -R "$NEW_USER:$NEW_USER" "$PIN_SSH_DIR"
                        chmod 700 "$PIN_SSH_DIR"
                        chmod 600 "$PIN_AUTH_KEYS"
                        print_success "SSH-ключ добавлен"
                    else
                        print_warning "Ключ не был добавлен (пустой ввод)"
                    fi
                    ;;
                2)
                    ask_input "Введите путь к файлу ключа: " KEY_PATH
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
                    print_warning "Неверный выбор. Пропускаем"
                    ;;
            esac
        fi
    else
        print_warning "Пользователь $NEW_USER не существует. Пропускаем настройку ключа."
    fi

    # --- 2.14 UFW ---
    print_section "2.14 UFW FIREWALL"
    if ! command -v ufw >/dev/null 2>&1; then
        print_info "UFW не установлен. Устанавливаем..."
        apt-get install -y ufw
    fi

    if LC_ALL=C ufw status 2>/dev/null | grep -q "Status: active"; then
        print_info "UFW уже активен — пропускаем настройку"
        LC_ALL=C ufw status verbose
    else
        print_warning "UFW не активен"
        ask_input "Настроить UFW с базовыми правилами? [Y/n]: " SETUP_UFW
        if [[ "$SETUP_UFW" =~ ^[Yy]$ ]] || [[ -z "$SETUP_UFW" ]]; then
            ufw default deny incoming
            ufw default allow outgoing
            ufw allow 80/tcp comment 'HTTP & SSL'
            ufw allow 443/tcp comment 'HTTPS'
            ufw allow 8443/tcp comment 'HTTPS'
            ufw allow "$SSH_PORT/tcp" comment 'SSH'
            ufw allow 5201/tcp comment 'iperf3'
            ufw allow 5201/udp comment 'iperf3'

            print_info "Текущие правила UFW:"
            LC_ALL=C ufw status verbose 2>/dev/null || true

            echo ""
            print_warning "ВНИМАНИЕ: UFW будет активирован. Убедитесь, что порт $SSH_PORT открыт!"
            ask_input "Активировать UFW сейчас? [Y/n]: " ENABLE_UFW
            if [[ "$ENABLE_UFW" =~ ^[Yy]$ ]] || [[ -z "$ENABLE_UFW" ]]; then
                ufw --force enable
                print_success "UFW активирован"
            else
                print_warning "UFW настроен, но не активирован"
            fi
        else
            print_warning "Пропускаем настройку UFW"
        fi
    fi

    # --- 2.15 SSH hardening ---
    print_section "2.15 SSH НАСТРОЙКИ"
    SSHD_CONFIG="/etc/ssh/sshd_config"
    SSHD_CONFIG_DIR="/etc/ssh/sshd_config.d"
    BACKUP_FILE="/etc/ssh/sshd_config.backup.$(date +%Y%m%d_%H%M%S)"

    SSH_PORT_SET=$(grep -E "^Port $SSH_PORT$" "$SSHD_CONFIG" || true)
    ROOT_LOGIN_SET=$(grep -E "^PermitRootLogin no$" "$SSHD_CONFIG" || true)
    PASS_AUTH_SET=$(grep -E "^PasswordAuthentication no$" "$SSHD_CONFIG" || true)
    EMPTY_PASS_SET=$(grep -E "^PermitEmptyPasswords no$" "$SSHD_CONFIG" || true)
    PUBKEY_SET=$(grep -E "^PubkeyAuthentication yes$" "$SSHD_CONFIG" || true)

    SSH_LISTENING_IPV4=false
    if ss -tuln | grep -q "0.0.0.0:$SSH_PORT "; then
        SSH_LISTENING_IPV4=true
    fi

    if [[ -n "$SSH_PORT_SET" && -n "$ROOT_LOGIN_SET" && -n "$PASS_AUTH_SET" && -n "$EMPTY_PASS_SET" && -n "$PUBKEY_SET" && "$SSH_LISTENING_IPV4" = true ]]; then
        print_info "SSH уже настроен правильно — пропускаем"
    else
        print_warning "SSH требует настройки"
        echo ""
        echo "Будут применены:"
        echo "  - Port $SSH_PORT"
        echo "  - PermitRootLogin no"
        echo "  - PasswordAuthentication no (ВХОД ТОЛЬКО ПО КЛЮЧУ!)"
        echo "  - PermitEmptyPasswords no"
        echo "  - PubkeyAuthentication yes"
        echo "  - KbdInteractiveAuthentication no"
        echo "  - MaxAuthTries 3"
        echo "  - LogLevel VERBOSE"
        echo "  - PermitUserEnvironment no"
        echo ""
        print_info "SSH-туннели остаются разрешёнными"
        print_info "Сессии НЕ будут разрываться по таймауту"
        echo ""
        print_error "❗ После применения вы НЕ СМОЖЕТЕ зайти под root по SSH!"
        print_error "❗ Вход будет возможен ТОЛЬКО по SSH-ключу для $NEW_USER"
        echo ""

        KEEP_PASSWORD_AUTH=false
        if [ -f "/home/$NEW_USER/.ssh/authorized_keys" ] && [ -s "/home/$NEW_USER/.ssh/authorized_keys" ]; then
            KEY_COUNT=$(wc -l < "/home/$NEW_USER/.ssh/authorized_keys")
            print_success "SSH-ключ для $NEW_USER обнаружен ($KEY_COUNT шт.)"
        else
            print_error "⚠️ У $NEW_USER НЕТ SSH-ключа!"
            print_error "Если отключить пароли, вы ПОТЕРЯЕТЕ доступ!"
            echo ""
            ask_input "Всё равно отключить вход по паролю? (НЕ РЕКОМЕНДУЕТСЯ) [y/N]: " FORCE_NO_PASS
            if [[ ! "$FORCE_NO_PASS" =~ ^[Yy]$ ]]; then
                print_warning "PasswordAuthentication останется включённым"
                KEEP_PASSWORD_AUTH=true
            fi
        fi

        echo ""
        ask_input "Применить настройки SSH? [Y/n]: " APPLY_SSH
        if [[ "$APPLY_SSH" =~ ^[Yy]$ ]] || [[ -z "$APPLY_SSH" ]]; then
            cp "$SSHD_CONFIG" "$BACKUP_FILE"
            print_info "Резервная копия: $BACKUP_FILE"

            # Обработка файлов в sshd_config.d
            if [ -d "$SSHD_CONFIG_DIR" ]; then
                print_info "Проверка файлов в $SSHD_CONFIG_DIR..."
                for conf_file in "$SSHD_CONFIG_DIR"/*.conf; do
                    if [ -f "$conf_file" ] && grep -qE "^PasswordAuthentication yes" "$conf_file" 2>/dev/null; then
                        print_warning "Найден файл с PasswordAuthentication yes: $conf_file"
                        cp "$conf_file" "$conf_file.backup.$(date +%Y%m%d_%H%M%S)"
                        sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' "$conf_file"
                        print_success "Исправлено: $conf_file"
                    fi
                done

                CUSTOM_SSH_CONF="$SSHD_CONFIG_DIR/99-hardening.conf"
                cat > "$CUSTOM_SSH_CONF" << HARDENING_EOF
PasswordAuthentication no
KbdInteractiveAuthentication no
HARDENING_EOF
                print_success "Override файл создан: $CUSTOM_SSH_CONF"
            fi

            # Функция для установки параметра
            set_ssh_param() {
                local param="$1"
                local value="$2"
                if grep -qE "^#?$param " "$SSHD_CONFIG"; then
                    sed -i "s/^#\?$param .*/$param $value/" "$SSHD_CONFIG"
                else
                    echo "$param $value" >> "$SSHD_CONFIG"
                fi
            }

            # Применяем настройки
            set_ssh_param "Port" "$SSH_PORT"
            set_ssh_param "PermitRootLogin" "no"
            set_ssh_param "PermitEmptyPasswords" "no"
            set_ssh_param "PubkeyAuthentication" "yes"
            set_ssh_param "KbdInteractiveAuthentication" "no"
            set_ssh_param "MaxAuthTries" "3"
            set_ssh_param "LogLevel" "VERBOSE"
            set_ssh_param "PermitUserEnvironment" "no"

            # ChallengeResponseAuthentication только для старых версий
            SSH_MAJOR_VERSION=$(sshd -V 2>&1 | head -1 | grep -oP 'OpenSSH_\K[0-9]+' || echo "9")
            if [ "$SSH_MAJOR_VERSION" -lt 9 ]; then
                set_ssh_param "ChallengeResponseAuthentication" "no"
            fi

            if [ "$KEEP_PASSWORD_AUTH" != "true" ]; then
                set_ssh_param "PasswordAuthentication" "no"
            fi

            print_success "Настройки SSH применены"

            # Отключение socket activation
            print_info "Настройка механизма запуска SSH..."
            if systemctl is-enabled --quiet ssh.socket 2>/dev/null || systemctl is-active --quiet ssh.socket 2>/dev/null; then
                print_info "Обнаружен systemd socket activation — отключаем"
                systemctl stop ssh.socket 2>/dev/null || true
                systemctl disable ssh.socket 2>/dev/null || true
                systemctl mask ssh.socket
                systemctl enable ssh.service
                systemctl restart ssh.service
                systemctl daemon-reload
                print_success "ssh.socket замаскирован, классический сервис активирован"
            else
                systemctl restart ssh.service
            fi

            sleep 2

            # Проверка синтаксиса
            if sshd -t; then
                print_success "Синтаксис корректен. Перезапуск SSH..."
                systemctl restart ssh
                sleep 2

                IPV4_OK=false
                IPV6_OK=false
                ss -tuln | grep -q "0.0.0.0:$SSH_PORT " && IPV4_OK=true
                ss -tuln | grep -q "\[::\]:$SSH_PORT " && IPV6_OK=true

                if [ "$IPV4_OK" = true ] && [ "$IPV6_OK" = true ]; then
                    print_success "SSH слушает порт $SSH_PORT на IPv4 и IPv6 ✓"
                elif [ "$IPV4_OK" = true ]; then
                    print_success "SSH слушает порт $SSH_PORT на IPv4 ✓"
                elif [ "$IPV6_OK" = true ]; then
                    print_error "SSH слушает ТОЛЬКО IPv6!"
                else
                    print_error "SSH НЕ слушает порт $SSH_PORT!"
                fi
            else
                print_error "ОШИБКА СИНТАКСИСА! Откатываем изменения..."
                cp "$BACKUP_FILE" "$SSHD_CONFIG"
                print_warning "Восстановлен оригинальный конфиг"
            fi
        else
            print_warning "Пропускаем настройку SSH"
        fi
    fi

    # --- 2.16 Zsh ---
    print_section "2.16 ZSH"
    CURRENT_SHELL=$(getent passwd "$CURRENT_USER" | cut -d: -f7)
    if [[ "$CURRENT_SHELL" != *"zsh"* ]]; then
        chsh -s "$(which zsh)" "$CURRENT_USER"
        print_success "Zsh установлен как оболочка по умолчанию"
    else
        print_info "Zsh уже является оболочкой по умолчанию"
    fi

    # --- 2.17 Oh My Zsh ---
    print_section "2.17 OH MY ZSH"
    if [ ! -d "$USER_HOME/.oh-my-zsh" ]; then
        print_info "Установка Oh My Zsh..."
        export RUNZSH=no KEEP_ZSHRC=no
        if [ "$CURRENT_USER" = "root" ]; then
            sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
        else
            sudo -u "$CURRENT_USER" sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
        fi
        print_success "Oh My Zsh установлен"
    else
        print_info "Oh My Zsh уже установлен"
    fi

    # --- 2.18 Powerlevel10k ---
    print_section "2.18 POWERLEVEL10K"
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

    # --- 2.19 Плагины ---
    print_section "2.19 ПЛАГИНЫ"
    clone_plugin() {
        local name=$1 url=$2
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

    # --- 2.20 .zshrc ---
    print_section "2.20 .zshrc"
    print_info "Создание конфигурации .zshrc..."

    # Определяем путь к локальным бинарникам
    if [ "$CURRENT_USER" = "root" ]; then
        LOCAL_BIN_PATH="/root/.local/bin"
    else
        LOCAL_BIN_PATH="/home/$CURRENT_USER/.local/bin"
    fi

    cat > "$USER_HOME/.zshrc" << EOF
# ============================================================
# КРИТИЧЕСКИ ВАЖНО: PATH должен быть задан ДО всего остального!
# Без этого на minimized системах команды не находятся
# ============================================================
export PATH="${LOCAL_BIN_PATH}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\$PATH"

# Enable Powerlevel10k instant prompt
if [[ -r "\${XDG_CACHE_HOME:-\$HOME/.cache}/p10k-instant-prompt-\${(%):-%n}.zsh" ]]; then
  source "\${XDG_CACHE_HOME:-\$HOME/.cache}/p10k-instant-prompt-\${(%):-%n}.zsh"
fi

export ZSH="\$HOME/.oh-my-zsh"
ZSH_THEME="powerlevel10k/powerlevel10k"

# ВАЖНО: БЕЗ плагина fzf из OMZ! Он ломает minimized системы
plugins=(
  git
  zsh-autosuggestions
  zsh-syntax-highlighting
  zsh-completions
  sudo
  extract
  docker
)

source \$ZSH/oh-my-zsh.sh

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

# === UFW ===
alias ufwv="sudo ufw status verbose"
alias ufwn="sudo ufw status numbered"
alias ufwl="sudo journalctl -u ufw -n 50 --no-pager"

# === SSH безопасность ===
alias sshlog="sudo journalctl -u ssh -n 50 --no-pager"
alias sshcheck="sudo sshd -t && echo 'SSH config OK'"

# === Мониторинг ===
alias iotop="sudo iotop"
alias ncdu="ncdu --color dark"

# === FZF — УНИВЕРСАЛЬНЫЙ способ ===
setup_fzf() {
  command -v fzf >/dev/null 2>&1 || return 0

  local fzf_ver
  fzf_ver=\$(fzf --version 2>/dev/null | awk '{print \$1}')

  # Если fzf >= 0.48.0 — встроенная интеграция
  if [[ -n "\$fzf_ver" ]] && printf '%s\n%s' "0.48.0" "\$fzf_ver" | sort -V | head -n1 | grep -q "^0.48.0\$"; then
    eval "\$(fzf --zsh 2>/dev/null)" && return 0
  fi

  # Пробуем файлы примеров
  local fzf_paths=(
    "/usr/share/doc/fzf/examples/key-bindings.zsh"
    "/usr/share/fzf/key-bindings.zsh"
    "/usr/local/share/fzf/key-bindings.zsh"
  )
  for path in "\${fzf_paths[@]}"; do
    if [[ -f "\$path" ]]; then
      source "\$path" 2>/dev/null
      local comp="\${path%/*}/completion.zsh"
      [[ -f "\$comp" ]] && source "\$comp" 2>/dev/null
      return 0
    fi
  done

  # Fallback: скачиваем с GitHub (абсолютные пути для надёжности)
  local tmp
  tmp=\$(/bin/mktemp 2>/dev/null || echo "/tmp/fzf_kb_\$\$")
  /usr/bin/curl -fsSL https://raw.githubusercontent.com/junegunn/fzf/master/shell/key-bindings.zsh -o "\$tmp" 2>/dev/null && source "\$tmp" 2>/dev/null
  /bin/rm -f "\$tmp" 2>/dev/null
}
setup_fzf
unfunction setup_fzf 2>/dev/null || unset -f setup_fzf

# === Zoxide (умный cd) ===
if command -v zoxide >/dev/null 2>&1; then
  eval "\$(zoxide init zsh)"
else
  alias z="cd"
fi

# === Powerlevel10k config ===
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh
EOF

    print_success ".zshrc создан"

    # --- 2.21 Права доступа ---
    print_section "2.21 ПРАВА ДОСТУПА"
    if [ "$CURRENT_USER" != "root" ]; then
        chown -R "$CURRENT_USER:$CURRENT_USER" "$USER_HOME/.oh-my-zsh"
        chown "$CURRENT_USER:$CURRENT_USER" "$USER_HOME/.zshrc"
    fi
    print_success "Права доступа настроены"

    # --- 2.22 Финальная проверка ---
    print_section "2.22 ФИНАЛЬНАЯ ПРОВЕРКА"

    # SSH порт
    if ss -tuln | grep -q "0.0.0.0:$SSH_PORT "; then
        print_success "SSH слушает порт $SSH_PORT на IPv4 ✓"
    else
        print_error "SSH НЕ слушает порт $SSH_PORT на IPv4! ⚠️"
    fi

    # IPv6
    if ss -tuln | grep -q "\[::\]:$SSH_PORT "; then
        print_success "SSH слушает порт $SSH_PORT на IPv6 ✓"
    else
        print_warning "SSH НЕ слушает порт $SSH_PORT на IPv6"
    fi

    # SSH сервис
    if systemctl is-active --quiet ssh; then
        print_success "SSH сервис активен ✓"
    else
        print_error "SSH сервис НЕ активен! ⚠️"
    fi

    # ssh.socket
    SOCKET_STATE=$(systemctl is-enabled ssh.socket 2>/dev/null || true)
    if [[ "$SOCKET_STATE" == "masked" ]]; then
        print_success "ssh.socket замаскирован ✓"
    elif [[ "$SOCKET_STATE" == "disabled" ]]; then
        print_warning "ssh.socket отключён, но не замаскирован"
    elif [[ "$SOCKET_STATE" == "enabled" || "$SOCKET_STATE" == "static" ]]; then
        print_error "ssh.socket ВКЛЮЧЁН!"
    fi

    # PasswordAuthentication
    PASS_AUTH_FINAL=$(grep -E "^PasswordAuthentication" "$SSHD_CONFIG" | tail -1 || true)
    if [[ "$PASS_AUTH_FINAL" == *"no"* ]]; then
        print_success "PasswordAuthentication отключён ✓"
    else
        print_warning "PasswordAuthentication включён ⚠️"
    fi

    # UFW
    if LC_ALL=C ufw status 2>/dev/null | grep -q "Status: active"; then
        print_success "UFW активен ✓"
    else
        print_warning "UFW НЕ активен"
    fi

    if [ "$IS_MINIMIZED" = true ]; then
        print_warning "⚠️  Система осталась в minimized состоянии"
    fi

    print_success "ЧАСТЬ 2 ЗАВЕРШЕНА!"

    # Финальное сообщение
    echo ""
    echo "=========================================="
    print_success "Настройка завершена!"
    echo "=========================================="
    echo ""
    echo "  1. Выйдите из текущей сессии: exit"
    echo "  2. Зайдите снова:  ssh -p $SSH_PORT $NEW_USER@YOUR_IP"
    echo "  3. Запустите:  p10k configure"
    echo "  4. Установите шрифт MesloLGS NF на клиент"
    echo ""
    print_error "⚠️  ВХОД ПО ПАРОЛЮ ОТКЛЮЧЁН! Только по SSH-ключу!"
    print_error "⚠️  Вход под root по SSH ЗАПРЕЩЁН!"
}

# ============================================
# ЧАСТЬ 3: ТЕСТЫ
# ============================================
part3_tests() {
    print_section "ЧАСТЬ 3: ТЕСТЫ И ДИАГНОСТИКА"

    cat << 'EOF'
╔══════════════════════════════════════════════════════╗
║              🧪 Выберите тест:                       ║
╠══════════════════════════════════════════════════════╣
║  1) 📊 Мой iPerf3 Monitor                            ║
║  2) 🌍 IP Region (только IPv4)                       ║
║  3) 🔒 Censorcheck (геоблок)                         ║
║  4) 🇷🇺 Censorcheck (РФ DPI)                         ║
║  5) 🚀 iPerf3 до российских серверов                 ║
║  6) 📈 YABS (только IPv4)                            ║
║  7) 🚫 Проверка IP на блокировки                     ║
║  8) ⚡ Bench.sh                                       ║
║  9) 🎯 IPQuality                                     ║
║ 10) 💻 Sysbench CPU                                  ║
║ 11) 🔁 Запустить основные                            ║
║  0) Назад                                            ║
╚══════════════════════════════════════════════════════╝
EOF

    ask_input "Ваш выбор: " TEST_CHOICE

    case "$TEST_CHOICE" in
        1) run_my_iperf ;;
        2) bash <(wget -qO- https://ipregion.vrnt.xyz) -4 ;;
        3) bash <(wget -qO- https://github.com/vernette/censorcheck/raw/master/censorcheck.sh) --mode geoblock ;;
        4) bash <(wget -qO- https://github.com/vernette/censorcheck/raw/master/censorcheck.sh) --mode dpi ;;
        5) bash <(wget -qO- https://github.com/itdoginfo/russian-iperf3-servers/raw/main/speedtest.sh) ;;
        6) curl -sL yabs.sh | bash -s -- -4 ;;
        7) bash <(curl -Ls IP.Check.Place) -l en ;;
        8) wget -qO- bench.sh | bash ;;
        9) bash <(curl -Ls https://Check.Place) -EI ;;
        10) sysbench cpu run --threads=1 ;;
        11) run_all_tests ;;
        0) return ;;
        *) print_error "Неверный выбор" ;;
    esac

    pause
}

run_my_iperf() {
    print_info "Загрузка iperf_real_monitor.sh..."
    if curl -fsSL https://raw.githubusercontent.com/Namsaraev/vps-setup/main/iperf_real_monitor.sh -o /tmp/iperf_real_monitor.sh 2>/dev/null; then
        chmod +x /tmp/iperf_real_monitor.sh
        bash /tmp/iperf_real_monitor.sh
    else
        print_warning "Скрипт не найден. Запустите вручную."
    fi
}

run_all_tests() {
    print_info "Запуск основных тестов..."
    bash <(wget -qO- https://ipregion.vrnt.xyz) -4
    bash <(curl -Ls IP.Check.Place) -l en
    curl -sL yabs.sh | bash -s -- -4
}

# ============================================
# ГЛАВНЫЙ ЦИКЛ
# ============================================
while true; do
    show_menu
    ask_input "Выберите действие [0-4]: " CHOICE

    case "$CHOICE" in
        1) part1_update ;;
        2) part2_setup ;;
        3) part3_tests ;;
        4)
            part1_update
            print_warning "После перезагрузки запустите скрипт снова и выберите пункт 2"
            exit 0
            ;;
        0)
            print_info "Выход. До свидания!"
            exit 0
            ;;
        *) print_error "Неверный выбор" ;;
    esac

    echo ""
    pause
done
