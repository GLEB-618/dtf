#!/usr/bin/env bash
set -Eeuo pipefail

# --- не запускать от root ---
if [[ ${EUID} -eq 0 ]]; then
  echo "Не запускай скрипт от root. Запусти обычным пользователем."
  exit 1
fi

# --- проверки окружения ---
if ! command -v pacman >/dev/null 2>&1; then
  echo "Похоже, это не Arch Linux. Останавливаюсь."
  exit 1
fi
if ! command -v sudo >/dev/null 2>&1; then
  echo "Нужен sudo: pacman -S sudo"
  exit 1
fi

# --- базовые инструменты + multilib ---
echo "[1/9] Базовые пакеты и multilib…"
sudo pacman -Sy --noconfirm --needed git base-devel curl sed awk jq

if ! grep -q "^\[multilib\]" /etc/pacman.conf; then
  # раскомментируем блок multilib
  sudo sed -i '/^\s*#\[multilib\]/,/#Include = \/etc\/pacman\.d\/mirrorlist/ s/^\s*#//' /etc/pacman.conf
  sudo pacman -Sy
fi

# --- Hyprland и must-have для Wayland ---
echo "[2/9] Hyprland + Wayland must-have…"
sudo pacman -S --noconfirm --needed \
  hyprland xorg-xwayland wayland-protocols \
  xdg-desktop-portal xdg-desktop-portal-hyprland \
  qt5-wayland qt6-wayland \
  wl-clipboard grim slurp \
  pipewire wireplumber pipewire-alsa pipewire-pulse pipewire-jack \
  hyprpaper hypridle hyprlock kitty rofi-wayland yazi neovim zsh stow \
  pamixer brightnessctl playerctl pavucontrol gvfs gvfs-mtp

# Шрифты (нормальные fallback’и)
sudo pacman -S --noconfirm --needed noto-fonts noto-fonts-emoji ttf-font-awesome ttf-nerd-fonts-symbols

# --- NVIDIA: драйверы и настройка для RTX 3060 ---
echo "[3/9] NVIDIA драйверы и настройка…"
# headers под установленные ядра
headers=()
for k in linux linux-lts linux-zen; do
  if pacman -Q "$k" >/dev/null 2>&1; then
    headers+=("${k}-headers")
  fi
done
if ((${#headers[@]})); then
  sudo pacman -S --noconfirm --needed "${headers[@]}"
fi

# Драйвер (open-dkms) + userspace + 32-bit, EGL/VA-API
sudo pacman -S --noconfirm --needed nvidia-open-dkms nvidia-utils lib32-nvidia-utils egl-wayland libva-nvidia-driver

# modeset=1 для раннего KMS
if ! grep -q "nvidia_drm.*modeset=1" /etc/modprobe.d/nvidia.conf 2>/dev/null; then
  echo "options nvidia_drm modeset=1" | sudo tee /etc/modprobe.d/nvidia.conf >/dev/null
fi

# добавить модули в mkinitcpio, если ещё не добавлены
if ! grep -q "nvidia_drm" /etc/mkinitcpio.conf; then
  sudo sed -i 's/^MODULES=(\([^)]*\))/MODULES=(\1 nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf
fi
sudo mkinitcpio -P || true

# --- сеть и BT ---
echo "[4/9] NetworkManager и Bluetooth…"
sudo pacman -S --noconfirm --needed networkmanager bluez bluez-utils
sudo systemctl enable --now NetworkManager
sudo systemctl enable --now bluetooth.service

# --- подготовка к их инсталлятору: rustup + go ---
echo "[5/9] Rust (rustup) и Go для сборок…"
sudo pacman -S --noconfirm --needed rustup go
# поставить стабильный toolchain и активировать
rustup toolchain install stable
rustup default stable
# cargo в PATH для текущей сессии (на всякий случай)
export PATH="$HOME/.cargo/bin:$PATH"

# --- клонируем zenities и чиним их INSTALL.sh ---
echo "[6/9] Клонирование zenities и патчи INSTALL.sh…"
cd "$HOME"
if [[ ! -d zenities ]]; then
  git clone https://github.com/hayyaoe/zenities
fi
cd zenities

if [[ ! -f INSTALL.sh ]]; then
  echo "В репозитории нет INSTALL.sh — проверь ссылку. Останов."
  exit 1
fi

# 1) закомментировать интерактивную установку rustup (curl | sh)
if grep -q "sh\.rustup\.rs" INSTALL.sh; then
  sed -i "/sh\.rustup\.rs/ s/^/# /" INSTALL.sh
fi

# 2) отключить автоперезагрузку в конце
sed -i 's/sudo reboot/echo "Reboot skipped by wrapper"/' INSTALL.sh

# 3) на всякий случай заставим исполняться под bash
sed -i '1s|^#!.*|#!/usr/bin/env bash|' INSTALL.sh
chmod +x INSTALL.sh

# --- запуск их инсталлятора (AUR, eww, dotfiles и т.д.) ---
echo "[7/9] Запуск INSTALL.sh из zenities…"
bash INSTALL.sh

# --- докидываем то, чего обычно не хватает ---
echo "[8/9] Допакеты: polkit-агент, уведомления…"
sudo pacman -S --noconfirm --needed hyprpolkitagent swaync

# --- env и автостарт в Hyprland ---
echo "[9/9] Прописываем env/exec-once в ~/.config/hypr/hyprland.conf…"
HYPRCONF="$HOME/.config/hypr/hyprland.conf"
mkdir -p "$(dirname "$HYPRCONF")"
touch "$HYPRCONF"

# ENV для NVIDIA/Wayland (минимально необходимое)
grep -q "__GLX_VENDOR_LIBRARY_NAME" "$HYPRCONF" || printf '\n# NVIDIA/Wayland env\nenv = __GLX_VENDOR_LIBRARY_NAME,nvidia\n' >> "$HYPRCONF"
grep -q "LIBVA_DRIVER_NAME"        "$HYPRCONF" || printf 'env = LIBVA_DRIVER_NAME,nvidia\n' >> "$HYPRCONF"
grep -q "NVD_BACKEND"              "$HYPRCONF" || printf 'env = NVD_BACKEND,direct\n' >> "$HYPRCONF"
grep -q "ELECTRON_OZONE_PLATFORM_HINT" "$HYPRCONF" || printf 'env = ELECTRON_OZONE_PLATFORM_HINT,auto\n' >> "$HYPRCONF"
# при артефактах курсора можно попробовать раскомментировать:
# grep -q "WLR_NO_HARDWARE_CURSORS" "$HYPRCONF" || printf 'env = WLR_NO_HARDWARE_CURSORS,1\n' >> "$HYPRCONF"

# автозапуск полкит-агента и уведомлялки
grep -q "hyprpolkitagent" "$HYPRCONF" || printf '\n# user services\nexec-once = systemctl --user start hyprpolkitagent\n' >> "$HYPRCONF"
grep -q "^exec-once = swaync" "$HYPRCONF" || printf 'exec-once = swaync\n' >> "$HYPRCONF"

echo
echo "=== Готово ==="
echo "Рекомендуется перезагрузить систему. После ребута войди в TTY и запусти: Hyprland"
