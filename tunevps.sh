#!/bin/bash

set -e  # Остановка при любой ошибке

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Функции для красивого вывода
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Проверка прав
if [ "$EUID" -eq 0 ]; then
    print_info "Скрипт запущен от имени root"
    CURRENT_USER="root"
    USER_HOME="/root"
elif sudo -n true 2>/dev/null; then
    print_info "Скрипт запущен с правами sudo"
    CURRENT_USER=$(whoami)
    USER_HOME="$HOME"
else
    print_error "Для работы скрипта нужны права root или sudo"
    exit 1
fi

print_info "Начинаем настройку системы для пользователя: $CURRENT_USER"
echo ""

# ============================================
# 1. ОБНОВЛЕНИЕ СИСТЕМЫ
# ============================================
print_info "Обновление системы..."
sudo apt update -y
sudo apt upgrade -y
sudo apt autoremove -y
print_success "Система обновлена"

# ============================================
# 2. НАСТРОЙКА ЧАСОВОГО ПОЯСА
# ============================================
print_info "Настройка часового пояса: Asia/Irkutsk"
sudo timedatectl set-timezone Asia/Irkutsk
print_success "Часовой пояс установлен: $(timedatectl | grep 'Time zone')"

# ============================================
# 3. НАСТРОЙКА РУССКОЙ ЛОКАЛИ
# ============================================
print_info "Настройка русской локали..."
sudo apt install language-pack-ru -y
sudo locale-gen ru_RU.UTF-8
sudo update-locale LANG=ru_RU.UTF-8
print_success "Русская локаль установлена"

# ============================================
# 4. УСТАНОВКА БАЗОВЫХ УТИЛИТ (БЕЗ procs)
# ============================================
print_info "Установка базовых утилит..."
sudo apt install -y \
    git curl wget unzip jq htop tmux net-tools dnsutils \
    bat eza fd-find ripgrep zoxide fzf \
    python3 python3-pip python3-venv build-essential \
    btop mtr iperf3 zsh cargo
print_success "Базовые утилиты установлены"

# ============================================
# 5. СОЗДАНИЕ СИМЛИНКОВ ДЛЯ UBUNTU
# ============================================
print_info "Создание симлинков для bat и fd..."
sudo ln -sf /usr/bin/batcat /usr/local/bin/bat 2>/dev/null || true
sudo ln -sf /usr/bin/fdfind /usr/local/bin/fd 2>/dev/null || true
print_success "Симлинки созданы"

# ============================================
# 6. УСТАНОВКА procs ЧЕРЕЗ CARGO (Rust)
# ============================================
print_info "Установка procs через cargo..."
if [ "$CURRENT_USER" = "root" ]; then
    CARGO_BIN="/root/.cargo/bin"
else
    CARGO_BIN="$HOME/.cargo/bin"
fi

if [ ! -f "$CARGO_BIN/procs" ]; then
    # Запускаем cargo install от имени текущего пользователя
    if [ "$CURRENT_USER" = "root" ]; then
        cargo install procs
    else
        sudo -u "$CURRENT_USER" cargo install procs
    fi
    print_success "procs установлен"
else
    print_warning "procs уже установлен"
fi

# Добавляем cargo bin в PATH в .zshrc (позже будет перезаписан, поэтому дублируем в bashrc тоже)
if [ "$CURRENT_USER" = "root" ]; then
    PATH_FILE="/root/.bashrc"
else
    PATH_FILE="$HOME/.bashrc"
fi
grep -q 'cargo/bin' "$PATH_FILE" || echo 'export PATH="$HOME/.cargo/bin:$PATH"' >> "$PATH_FILE"

# ============================================
# 7. НАСТРОЙКА SUDOERS (NOPASSWD)
# ============================================
print_info "Настройка sudoers для команд без пароля..."
SUDOERS_LINE="$CURRENT_USER ALL=(ALL) NOPASSWD: /usr/sbin/ufw, /usr/bin/journalctl"
if sudo grep -q "$SUDOERS_LINE" /etc/sudoers 2>/dev/null; then
    print_warning "Правило sudoers уже существует"
else
    echo "$SUDOERS_LINE" | sudo EDITOR='tee -a' visudo > /dev/null
    print_success "Sudoers настроен"
fi

# ============================================
# 8. УСТАНОВКА ZSH КАК ОБОЛОЧКИ ПО УМОЛЧАНИЮ
# ============================================
print_info "Установка Zsh как оболочки по умолчанию..."
if [ "$CURRENT_USER" = "root" ]; then
    sudo chsh -s $(which zsh) root
else
    sudo chsh -s $(which zsh) "$CURRENT_USER"
fi
print_success "Zsh установлен как оболочка по умолчанию"

# ============================================
# 9. УСТАНОВКА OH MY ZSH
# ============================================
print_info "Установка Oh My Zsh..."
if [ ! -d "$USER_HOME/.oh-my-zsh" ]; then
    export RUNZSH=no
    export KEEP_ZSHRC=no
    # Установка от имени текущего пользователя
    if [ "$CURRENT_USER" = "root" ]; then
        sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
    else
        sudo -u "$CURRENT_USER" sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
    fi
    print_success "Oh My Zsh установлен"
else
    print_warning "Oh My Zsh уже установлен"
fi

# ============================================
# 10. УСТАНОВКА POWERLEVEL10K
# ============================================
print_info "Установка Powerlevel10k..."
ZSH_CUSTOM_DIR="$USER_HOME/.oh-my-zsh/custom"
if [ ! -d "$ZSH_CUSTOM_DIR/themes/powerlevel10k" ]; then
    if [ "$CURRENT_USER" = "root" ]; then
        git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$ZSH_CUSTOM_DIR/themes/powerlevel10k"
    else
        sudo -u "$CURRENT_USER" git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$ZSH_CUSTOM_DIR/themes/powerlevel10k"
    fi
    print_success "Powerlevel10k установлен"
else
    print_warning "Powerlevel10k уже установлен"
fi

# ============================================
# 11. УСТАНОВКА ПЛАГИНОВ OMZ
# ============================================
print_info "Установка плагинов Oh My Zsh..."
clone_plugin() {
    local name=$1
    local url=$2
    if [ ! -d "$ZSH_CUSTOM_DIR/plugins/$name" ]; then
        if [ "$CURRENT_USER" = "root" ]; then
            git clone "$url" "$ZSH_CUSTOM_DIR/plugins/$name"
        else
            sudo -u "$CURRENT_USER" git clone "$url" "$ZSH_CUSTOM_DIR/plugins/$name"
        fi
    fi
}

clone_plugin "zsh-autosuggestions" "https://github.com/zsh-users/zsh-autosuggestions"
clone_plugin "zsh-syntax-highlighting" "https://github.com/zsh-users/zsh-syntax-highlighting.git"
clone_plugin "zsh-completions" "https://github.com/zsh-users/zsh-completions"

print_success "Плагины установлены"

# ============================================
# 12. СОЗДАНИЕ .zshrc
# ============================================
print_info "Создание конфигурации .zshrc..."

cat > "$USER_HOME/.zshrc" << 'EOF'
# Enable Powerlevel10k instant prompt
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

# Path to Oh My Zsh
export ZSH="$HOME/.oh-my-zsh"

# Theme
ZSH_THEME="powerlevel10k/powerlevel10k"

# Plugins
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
alias ps="procs"
alias psa="procs --tree"

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

# === FZF ===
source /usr/share/doc/fzf/examples/key-bindings.zsh
source /usr/share/doc/fzf/examples/completion.zsh

# === Zoxide (умный cd) ===
eval "$(zoxide init zsh)"

# === Cargo bin в PATH ===
export PATH="$HOME/.cargo/bin:$PATH"

# Powerlevel10k config
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh
EOF

print_success "Файл .zshrc создан"

# ============================================
# 13. НАСТРОЙКА ПРАВ ДОСТУПА
# ============================================
if [ "$CURRENT_USER" != "root" ]; then
    sudo chown -R "$CURRENT_USER:$CURRENT_USER" "$USER_HOME/.oh-my-zsh"
    sudo chown "$CURRENT_USER:$CURRENT_USER" "$USER_HOME/.zshrc"
    sudo chown -R "$CURRENT_USER:$CURRENT_USER" "$USER_HOME/.cargo" 2>/dev/null || true
fi

# ============================================
# ФИНАЛЬНЫЕ ИНСТРУКЦИИ
# ============================================
echo ""
echo "=========================================="
print_success "Настройка завершена!"
echo "=========================================="
echo ""
print_info "ВАЖНО: Для применения всех изменений:"
echo ""
echo "  1. Выйдите из текущей SSH-сессии:"
echo "     exit"
echo ""
echo "  2. Зайдите снова на сервер (Zsh подхватится автоматически)"
echo ""
echo "  3. При первом входе запустите настройку Powerlevel10k:"
echo "     p10k configure"
echo ""
echo "  4. Установите шрифт MesloLGS NF на ваш локальный компьютер:"
echo "     https://github.com/romkatv/powerlevel10k#fonts"
echo ""
print_warning "Не забудьте настроить SSH вручную после выхода из скрипта"
echo ""
