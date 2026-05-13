#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACMAN_LIST="$REPO_DIR/packages/pacman.txt"
AUR_LIST="$REPO_DIR/packages/aur.txt"

info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[ERR ]\033[0m %s\n' "$*"; }

# ─────────────────────────────────────────────
#  Держим sudo живым на всё время установки
# ─────────────────────────────────────────────
keep_sudo_alive() {
  sudo -v
  while true; do
    sudo -n true
    sleep 60
    kill -0 "$$" || exit
  done 2>/dev/null &
  SUDO_KEEPALIVE_PID=$!
  trap 'kill $SUDO_KEEPALIVE_PID 2>/dev/null || true' EXIT
}

# ─────────────────────────────────────────────
#  Читает файл пакетов, пропускает комментарии
# ─────────────────────────────────────────────
read_pkg_file() {
  grep -vE '^\s*#|^\s*$' "$1"
}

# ─────────────────────────────────────────────
#  Базовые инструменты (нужны для остального)
# ─────────────────────────────────────────────
install_base_tools() {
  info "Installing bootstrap packages..."
  sudo pacman -S --needed --noconfirm base-devel git rsync pciutils
}

# ─────────────────────────────────────────────
#  Пакеты из официальных репозиториев
# ─────────────────────────────────────────────
install_pacman_packages() {
  info "Installing pacman packages..."
  mapfile -t pkgs < <(read_pkg_file "$PACMAN_LIST")
  if ((${#pkgs[@]})); then
    sudo pacman -Syu --needed --noconfirm "${pkgs[@]}"
  fi
}

# ─────────────────────────────────────────────
#  yay — AUR-хелпер
# ─────────────────────────────────────────────
install_yay() {
  if command -v yay >/dev/null 2>&1; then
    info "yay already installed"
    return
  fi

  info "Installing yay..."
  local tmpdir
  tmpdir="$(mktemp -d)"
  git clone https://aur.archlinux.org/yay-bin.git "$tmpdir/yay-bin"
  (
    cd "$tmpdir/yay-bin"
    makepkg -si --noconfirm
  )
  rm -rf "$tmpdir"
}

# ─────────────────────────────────────────────
#  AUR пакеты
# ─────────────────────────────────────────────
install_aur_packages() {
  info "Installing AUR packages..."
  mapfile -t pkgs < <(read_pkg_file "$AUR_LIST")
  if ((${#pkgs[@]})); then
    yay -S --needed --noconfirm --answerdiff None --answerclean None "${pkgs[@]}"
  fi
}

# ─────────────────────────────────────────────
#  Симлинк с бэкапом если файл уже существует
# ─────────────────────────────────────────────
backup_and_link() {
  local src="$1"
  local dst="$2"

  mkdir -p "$(dirname "$dst")"

  if [[ -L "$dst" ]]; then
    # Уже симлинк — просто перезаписываем
    rm -f "$dst"
  elif [[ -e "$dst" ]]; then
    # Реальный файл/папка — бэкапим
    mv "$dst" "${dst}.backup.$(date +%Y%m%d-%H%M%S)"
    warn "Backed up: $dst"
  fi

  ln -s "$src" "$dst"
}

# ─────────────────────────────────────────────
#  Раскладываем конфиги через симлинки
# ─────────────────────────────────────────────
link_configs() {
  info "Linking config directories..."

  mkdir -p "$HOME/.config" "$HOME/.local/bin" "$HOME/Pictures/Screenshots"

  # config/* -> ~/.config/*
  if [[ -d "$REPO_DIR/config" ]]; then
    for path in "$REPO_DIR"/config/*; do
      [[ -e "$path" ]] || continue
      backup_and_link "$path" "$HOME/.config/$(basename "$path")"
    done
  fi

  # local/bin/* -> ~/.local/bin/*
  if [[ -d "$REPO_DIR/local/bin" ]]; then
    for path in "$REPO_DIR"/local/bin/*; do
      [[ -e "$path" ]] || continue
      chmod +x "$path" || true
      backup_and_link "$path" "$HOME/.local/bin/$(basename "$path")"
    done
  fi

  # Обои копируем (не симлинкуем, чтобы работал swww)
  if [[ -d "$REPO_DIR/assets/wallpapers" ]]; then
    mkdir -p "$HOME/Pictures/Wallpapers"
    rsync -a "$REPO_DIR/assets/wallpapers/" "$HOME/Pictures/Wallpapers/" || true
  fi
}

# ─────────────────────────────────────────────
#  greetd конфиг (требует sudo)
# ─────────────────────────────────────────────
setup_greetd() {
  local src="$REPO_DIR/system/etc/greetd/config.toml"
  if [[ -f "$src" ]]; then
    info "Installing greetd config..."
    sudo install -Dm644 "$src" /etc/greetd/config.toml
  fi
}

# ─────────────────────────────────────────────
#  Определяем ноут/ПК и видеокарту
#  Записываем в ~/.config/rice/host.env
#  Создаём симлинк на нужный gpu.env для Hyprland
# ─────────────────────────────────────────────
detect_profile() {
  local profile="desktop"
  local gpu="generic"

  # Есть батарея — ноут
  if compgen -G "/sys/class/power_supply/BAT*" > /dev/null; then
    profile="laptop"
  fi

  # Определяем GPU
  if lspci | grep -qi "NVIDIA"; then
    gpu="nvidia"
  elif lspci | grep -Eqi "VGA.*Intel|3D controller.*Intel"; then
    gpu="intel"
  elif lspci | grep -Eqi "AMD|ATI"; then
    gpu="amd"
  fi

  # Сохраняем профиль — его читает Hyprland и скрипты
  mkdir -p "$HOME/.config/rice"
  cat > "$HOME/.config/rice/host.env" <<EOF
export RICE_PROFILE="$profile"
export RICE_GPU="$gpu"
EOF

  # ── Создаём симлинк gpu.env -> nvidia.env / intel.env / generic ──
  # Hyprland читает: source = ~/.config/hypr/envs/gpu.env
  # Нам нужно чтобы этот файл уже существовал до первого запуска Hyprland
  local env_src="$REPO_DIR/config/hypr/envs/${gpu}.env"
  local env_dst="$HOME/.config/hypr/envs/gpu.env"

  mkdir -p "$(dirname "$env_dst")"

  if [[ -f "$env_src" ]]; then
    # Удаляем старый симлинк если был
    [[ -L "$env_dst" ]] && rm -f "$env_dst"
    ln -sf "$env_src" "$env_dst"
    info "GPU env linked: ${gpu}.env"
  else
    # GPU не определён или нет файла — создаём пустой чтобы Hyprland не падал
    touch "$env_dst"
    warn "No env file for GPU '$gpu', created empty gpu.env"
  fi

  info "Profile : $profile"
  info "GPU     : $gpu"
}

# ─────────────────────────────────────────────
#  XDG папки пользователя
# ─────────────────────────────────────────────
setup_user_dirs() {
  info "Creating XDG user dirs..."
  xdg-user-dirs-update || true
  mkdir -p \
    "$HOME/Pictures/Screenshots" \
    "$HOME/Pictures/Wallpapers" \
    "$HOME/Downloads" \
    "$HOME/Documents"
}

# ─────────────────────────────────────────────
#  Добавляем пользователя в нужные группы
# ─────────────────────────────────────────────
add_user_groups() {
  info "Adding user to groups..."
  sudo usermod -aG video,input "$USER" || true
}

# ─────────────────────────────────────────────
#  Fish как shell по умолчанию
# ─────────────────────────────────────────────
make_fish_default() {
  if ! command -v fish >/dev/null 2>&1; then
    warn "fish not found, skipping"
    return
  fi

  if [[ "${SHELL:-}" == "/usr/bin/fish" ]]; then
    info "fish is already default shell"
    return
  fi

  read -rp "$(printf '\033[1;34m[?]\033[0m Make fish default shell? [Y/n] ')" answer
  answer="${answer:-Y}"

  if [[ "$answer" =~ ^[Yy]$ ]]; then
    chsh -s /usr/bin/fish
    info "fish set as default shell (applies after re-login)"
  fi
}

# ─────────────────────────────────────────────
#  Включаем системные сервисы
# ─────────────────────────────────────────────
enable_services() {
  info "Enabling services..."

  local services=(
    NetworkManager.service
    bluetooth.service
    power-profiles-daemon.service
    greetd.service
  )

  for svc in "${services[@]}"; do
    if systemctl list-unit-files --quiet "$svc" &>/dev/null; then
      sudo systemctl enable "$svc"
      info "Enabled: $svc"
    else
      warn "Not found, skipping: $svc"
    fi
  done
}

# ─────────────────────────────────────────────
#  Заметка про драйверы GPU в конце
# ─────────────────────────────────────────────
show_gpu_note() {
  echo
  warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  warn " GPU DRIVERS — прочитай перед перезагрузкой"
  warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo
  warn "ПК (RTX 4060):"
  warn "  sudo pacman -S nvidia-dkms nvidia-utils linux-headers"
  warn "  После установки: sudo reboot"
  echo
  warn "Ноут (Intel iGPU):"
  warn "  sudo pacman -S mesa vulkan-intel"
  warn "  Обычно уже стоит, ничего делать не нужно"
  echo
  warn "Если Hyprland не стартует после reboot — проверь nvidia-drm:"
  warn "  /etc/modprobe.d/nvidia.conf должен содержать:"
  warn "  options nvidia-drm modeset=1 fbdev=1"
  echo
}

# ─────────────────────────────────────────────
#  MAIN
# ─────────────────────────────────────────────
main() {
  echo
  info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  info " Dotfiles installer"
  info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo

  keep_sudo_alive

  install_base_tools
  install_pacman_packages
  install_yay
  install_aur_packages

  setup_user_dirs
  link_configs
  setup_greetd

  detect_profile      # <-- теперь создаёт и gpu.env симлинк

  add_user_groups
  make_fish_default
  enable_services

  show_gpu_note

  echo
  info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  info " Готово! Перезагрузи систему:"
  info " sudo reboot"
  info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo
}

main "$@"
