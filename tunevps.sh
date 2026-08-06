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
NC='\033[0m'

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Автоматический перезапуск через sudo
if [ "$EUID" -ne 0 ]; then
    print_info "Требуются права root. Перезапускаем скрипт через sudo..."
    exec sudo bash "$0" "$@"
fi

print_info "Скрипт запущен от имени root"
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
print_info "Обновление системы..."
apt-get update -y
apt-get upgrade -y
apt-get autoremove -y
print_success "Система обновлена"

# ============================================
# 2. ЧАСОВОЙ ПОЯС
# ============================================
print_info "Настройка часового пояса: Asia/Irkutsk"
timedatectl set-timezone Asia/Irkutsk
print_success "Часовой пояс установлен: $(timedatectl | grep 'Time zone')"

# ============================================
# 3. ЛОКАЛЬ
# ============================================
print_info "Настройка русской локали..."
apt-get install -y language-pack-ru
locale-gen ru_RU.UTF-8
update-locale LANG=ru_RU.UTF-8
print_success "Русская локаль установлена"

# ============================================
# 4. БАЗОВЫЕ УТИЛИТЫ
# ============================================
print_info "Установка базовых утилит..."
apt-get install -y \
    nano vim git curl wget unzip jq htop tmux net-tools dnsutils \
    bat eza fd-find ripgrep zoxide fzf \
    python3 python3-pip python3-venv build-essential \
    btop mtr iperf3 zsh
print_success "Базовые утилиты установлены"

# ============================================
# 5. СИМЛИНКИ
# ============================================
print_info "Создание симлинков для bat и fd..."
ln -sf /usr/bin/batcat /usr/local/bin/bat 2>/dev/null || true
ln -sf /usr/bin/fdfind /usr/local/bin/fd 2>/dev/null || true
print_success "Симлинки созданы"

# ============================================
# 6. SUDOERS (NOPASSWD)
# ============================================
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
print_info "Проверка пользователя $NEW_USER..."
if id -u "$NEW_USER" &>/dev/null; then
    print_info "Пользователь $NEW_USER уже существует — пропускаем создание"
else
    print_warning "Пользователь $NEW_USER не найден в системе"
    echo -n "Создать пользователя $NEW_USER и добавить в группу sudo? [Y/n]: "
    read CREATE_USER
    
    if [[ "$CREATE_USER" =~ ^[Yy]$ ]] || [[ -z "$CREATE_USER" ]]; then
        # Создаём пользователя без пароля (зададим ниже)
        adduser --disabled-password --gecos "" "$NEW_USER"
        # Добавляем в группу sudo
        usermod -aG sudo "$NEW_USER"
        print_success "Пользователь $NEW_USER создан и добавлен в группу sudo"
        
        # Запрашиваем пароль сразу
        echo ""
        print_info "Теперь задайте пароль для пользователя $NEW_USER"
        while true; do
            read -s -p "Введите пароль для $NEW_USER: " USER_PASSWORD
            echo
            read -s -p "Повторите пароль: " USER_PASSWORD_CONFIRM
            echo
            
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
    else
        print_warning "Пропускаем создание пользователя $NEW_USER"
    fi
fi

# ============================================
# 8. ДОБАВЛЕНИЕ SSH-КЛЮЧА ДЛЯ ПОЛЬЗОВАТЕЛЯ
# ============================================
print_info "Проверка SSH-ключа для пользователя $NEW_USER..."

if [ ! -d "/home/$NEW_USER" ]; then
    print_warning "Пользователь $NEW_USER не существует. Пропускаем настройку SSH-ключа."
else
    PIN_SSH_DIR="/home/$NEW_USER/.ssh"
    PIN_AUTH_KEYS="$PIN_SSH_DIR/authorized_keys"
    SKIP_KEY=false
    
    # Проверяем, есть ли уже ключи
    if [ -f "$PIN_AUTH_KEYS" ] && [ -s "$PIN_AUTH_KEYS" ]; then
        print_info "SSH-ключ для $NEW_USER уже настроен"
        echo -n "Добавить ещё один ключ? [y/N]: "
        read ADD_MORE
        if [[ ! "$ADD_MORE" =~ ^[Yy]$ ]]; then
            print_info "Пропускаем добавление ключа"
            SKIP_KEY=true
        fi
    fi
    
    if [ "$SKIP_KEY" != "true" ]; then
        echo ""
        print_warning "⚠️  ВАЖНО: Добавьте SSH-ключ для $NEW_USER, чтобы не потерять доступ после отключения root-входа"
        echo ""
        echo "Выберите способ добавления ключа:"
        echo "  1) Вставить публичный ключ вручную (скопируйте содержимое id_ed25519.pub)"
        echo "  2) Указать путь к файлу ключа на сервере"
        echo "  3) Пропустить (если ключ уже настроен)"
        echo -n "Ваш выбор [1/2/3]: "
        read KEY_METHOD
        
        case "$KEY_METHOD" in
            1)
                echo ""
                print_info "Вставьте ваш публичный ключ одной строкой (начинается с ssh-ed25519 или ssh-rsa):"
                read PUBLIC_KEY
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
                echo -n "Введите путь к файлу публичного ключа: "
                read KEY_PATH
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
print_info "Проверка файрвола UFW..."

# Устанавливаем UFW, если его нет
if ! command -v ufw &>/dev/null; then
    print_info "UFW не установлен. Устанавливаем..."
    apt-get install -y ufw
fi

# Проверяем, активен ли UFW
if ufw status | grep -q "Status: active"; then
    print_info "UFW уже активен — пропускаем настройку"
    ufw status verbose
else
    print_warning "UFW не активен или не настроен"
    echo -n "Настроить UFW с базовыми правилами? [Y/n]: "
    read SETUP_UFW
    
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
        
        print_warning "ВНИМАНИЕ: UFW будет активирован. Убедитесь, что ваш SSH порт ($SSH_PORT) открыт!"
        echo -n "Активировать UFW сейчас? [Y/n]: "
        read ENABLE_UFW
        
        if [[ "$ENABLE_UFW" =~ ^[Yy]$ ]] || [[ -z "$ENABLE_UFW" ]]; then
            # --force чтобы не было интерактивного вопроса про SSH
            ufw --force enable
            print_success "UFW активирован"
            ufw status verbose
        else
            print_warning "UFW настроен, но не активирован. Активируйте позже: sudo ufw enable"
        fi
    else
        print_warning "Пропускаем настройку UFW"
    fi
fi

# ============================================
# 10. НАСТРОЙКА SSH (БЕЗОПАСНОСТЬ)
# ============================================
print_info "Проверка настроек SSH..."

SSHD_CONFIG="/etc/ssh/sshd_config"
BACKUP_FILE="/etc/ssh/sshd_config.backup.$(date +%Y%m%d_%H%M%S)"

# Проверяем, применены ли уже все нужные настройки
SSH_PORT_SET=$(grep -E "^Port $SSH_PORT$" "$SSHD_CONFIG" || true)
ROOT_LOGIN_SET=$(grep -E "^PermitRootLogin no$" "$SSHD_CONFIG" || true)
EMPTY_PASS_SET=$(grep -E "^PermitEmptyPasswords no$" "$SSHD_CONFIG" || true)
PUBKEY_SET=$(grep -E "^PubkeyAuthentication yes$" "$SSHD_CONFIG" || true)

if [[ -n "$SSH_PORT_SET" && -n "$ROOT_LOGIN_SET" && -n "$EMPTY_PASS_SET" && -n "$PUBKEY_SET" ]]; then
    print_info "SSH уже настроен правильно — пропускаем"
else
    print_warning "SSH требует настройки безопасности"
    echo ""
    print_warning "⚠️  БУДУТ ПРИМЕНЕНЫ СЛЕДУЮЩИЕ ИЗМЕНЕНИЯ:"
    echo "    - Port $SSH_PORT (смена стандартного порта 22)"
    echo "    - PermitRootLogin no (запрет входа под root)"
    echo "    - PermitEmptyPasswords no (запрет пустых паролей)"
    echo "    - PubkeyAuthentication yes (вход по ключам)"
    echo ""
    print_error "❗ После применения вы НЕ СМОЖЕТЕ зайти под root по SSH!"
    print_error "❗ Убедитесь, что у пользователя $NEW_USER настроен SSH-ключ или вы знаете его пароль"
    echo ""
    
    # Дополнительная проверка: есть ли ключ у pin перед отключением root
    if [ -f "/home/$NEW_USER/.ssh/authorized_keys" ] && [ -s "/home/$NEW_USER/.ssh/authorized_keys" ]; then
        print_success "SSH-ключ для $NEW_USER обнаружен. Можно безопасно отключать root-вход."
    else
        print_error "⚠️  У пользователя $NEW_USER НЕТ SSH-ключа!"
        print_error "После отключения root-входа вы сможете зайти только по паролю пользователя $NEW_USER"
    fi
    
    echo ""
    echo -n "Применить настройки SSH? [Y/n]: "
    read APPLY_SSH
    
    if [[ "$APPLY_SSH" =~ ^[Yy]$ ]] || [[ -z "$APPLY_SSH" ]]; then
        # Создаём резервную копию
        cp "$SSHD_CONFIG" "$BACKUP_FILE"
        print_info "Резервная копия создана: $BACKUP_FILE"
        
        # Применяем настройки через sed
        print_info "Применяем настройки SSH..."
        
        # Порт (раскомментируем и меняем, либо добавляем если нет)
        if grep -qE "^#?Port " "$SSHD_CONFIG"; then
            sed -i "s/^#\?Port .*/Port $SSH_PORT/" "$SSHD_CONFIG"
        else
            echo "Port $SSH_PORT" >> "$SSHD_CONFIG"
        fi
        
        # PermitRootLogin no
        if grep -qE "^#?PermitRootLogin " "$SSHD_CONFIG"; then
            sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin no/" "$SSHD_CONFIG"
        else
            echo "PermitRootLogin no" >> "$SSHD_CONFIG"
        fi
        
        # PermitEmptyPasswords no
        if grep -qE "^#?PermitEmptyPasswords " "$SSHD_CONFIG"; then
            sed -i "s/^#\?PermitEmptyPasswords .*/PermitEmptyPasswords no/" "$SSHD_CONFIG"
        else
            echo "PermitEmptyPasswords no" >> "$SSHD_CONFIG"
        fi
        
        # PubkeyAuthentication yes
        if grep -qE "^#?PubkeyAuthentication " "$SSHD_CONFIG"; then
            sed -i "s/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/" "$SSHD_CONFIG"
        else
            echo "PubkeyAuthentication yes" >> "$SSHD_CONFIG"
        fi
        
        # Проверяем синтаксис конфига ПЕРЕД перезапуском
        print_info "Проверка синтаксиса sshd_config..."
        if sshd -t; then
            print_success "Синтаксис корректен. Перезапускаем SSH..."
            systemctl restart ssh
            print_success "SSH перезапущен с новыми настройками"
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
# 11. ZSH
# ============================================
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
# 12. OH MY ZSH
# ============================================
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
# 13. POWERLEVEL10K
# ============================================
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
# 14. ПЛАГИНЫ OMZ
# ============================================
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
# 15. .zshrc
# ============================================
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

# === FZF (универсальный способ для всех Ubuntu 22/24/26) ===
source <(fzf --zsh)

# === Zoxide (умный cd) ===
eval "$(zoxide init zsh)"

# === Powerlevel10k config ===
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh
EOF
print_success "Файл .zshrc создан"

# ============================================
# 16. ПРАВА ДОСТУПА
# ============================================
if [ "$CURRENT_USER" != "root" ]; then
    chown -R "$CURRENT_USER:$CURRENT_USER" "$USER_HOME/.oh-my-zsh"
    chown "$CURRENT_USER:$CURRENT_USER" "$USER_HOME/.zshrc"
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
if [[ -f "$BACKUP_FILE" ]] 2>/dev/null; then
    print_warning "Резервная копия sshd_config: $BACKUP_FILE"
fi
print_warning "Вход под root по SSH теперь ЗАПРЕЩЁН!"
echo ""
