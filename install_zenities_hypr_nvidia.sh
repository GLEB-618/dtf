#!/usr/bin/env bash
set -Eeuo pipefail

# --- sanity checks ---
if ! command -v pacman >/dev/null 2>&1; then
  echo "Это не Arch Linux. Останавливаюсь."; exit 1
fi
if ! pacman -Qq sudo >/dev/null 2>&1; then
  echo "Нужен sudo: pacman -S sudo"; exit 1
fi

# --- базовые инструменты + включаем multilib для lib32-nvidia-utils ---
echo "[1/8] Базовые утилиты и multilib..."
sudo pacman -Sy --noconfirm --needed git base-devel curl sed awk jq

if ! grep -q "^\[multilib\]" /etc/pacman.conf; then
  sudo sed -i '/#\[multilib\]/,/#Include = \/etc\/pacman\.d\/mirrorlist/ s/^#//' /etc/pacman.conf
  sudo pacman -Sy
fi

# --- Hyprland и основа Wayland DE ---
echo "[2/8] Hyprland и must-have пакеты..."
sudo pacman -S --noconfirm --needed \
  hyprland xorg-xwayland wayland-protocols \
  xdg-desktop-portal xdg-desktop-portal-hyprland qt5-wayland qt6-wayland \
  wl-clipboard grim slurp \
  pipewire wireplumber pipewire-alsa pipewire-pulse pipewire-jack \
  hyprpaper hypridle hyprlock kitty rofi-wayland yazi neovim zsh stow \
  pamixer brightnessctl playerctl pavucontrol gvfs gvfs-mtp

# Шрифты/иконки (нормальные fallback’и для тем/баров/иконок)
sudo pacman -S --noconfirm --needed noto-fonts noto-fonts-emoji ttf-font-awesome ttf-nerd-fonts-symbols

# --- NVIDIA: драйверы, headers, EGL/VA-API ---
echo "[3/8] NVIDIA драйверы и настройки..."
# headers под установленные ядра
headers=()
for k in linux linux-zen linux-lts; do
  if pacman -Q "$k" >/dev/null 2>&1; then headers+=("${k}-headers"); fi
done
if ((${#headers[@]})); then
  sudo pacman -S --noconfirm --needed "${headers[@]}"
fi

# Для RTX 3060 (Ampere) рекомендуются open kernel modules (nvidia-open-dkms) + userspace (nvidia-utils)
sudo pacman -S --noconfirm --needed nvidia-open-dkms nvidia-utils lib32-nvidia-utils egl-wayland libva-nvidia-driver

# Включаем modeset=1 (на Arch и так включено, но подстрахуемся)
echo "options nvidia_drm modeset=1" | sudo tee /etc/modprobe.d/nvidia.conf >/dev/null || true

# Ранний KMS: добавим модули в mkinitcpio (если нет) и пересоберём initramfs
if grep -q '^MODULES=' /etc/mkinitcpio.conf; then
  sudo sed -i 's/^MODULES=(\(.*\))/MODULES=(\1 nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf || true
fi
sudo mkinitcpio -P || true

# --- Сети/BT ---
echo "[4/8] NetworkManager и Bluetooth..."
sudo pacman -S --noconfirm --needed networkmanager bluez bluez-utils
sudo systemctl enable --now NetworkManager
sudo systemctl enable --now bluetooth.service

# --- Клонируем zenities и патчим их INSTALL.sh ---
echo "[5/8] Клонирование zenities и патч инсталлятора..."
cd "$HOME"
if [ ! -d zenities ]; then
  git clone https://github.com/hayyaoe/zenities
fi
cd zenities

# их INSTALL.sh:
#  - интерактивно тянет rustup через curl | sh (подвиснет в скрипте)
#  - в конце делает sudo reboot (сломает пост-настройку)
# правим: rustup → non-interactive, reboot → пропуск
if [ -f INSTALL.sh ]; then
  sed -i "s|curl --proto '=https' -- tlsv1\.2 -sSf https://sh\.rustup\.rs | sh|rustup default stable -y|" INSTALL.sh
  sed -i 's/sudo reboot/echo "Reboot пропущен обёрткой. Перезагрузите после завершения."/g' INSTALL.sh
else
  echo "Не найден INSTALL.sh в zenities"; exit 1
fi

# для сборки yay нужен go (их скрипт про это не знает)
sudo pacman -S --noconfirm --needed go

echo "[6/8] Запуск их INSTALL.sh..."
bash INSTALL.sh

# --- Докидываем то, чего не хватает для нормальной работы ---
echo "[7/8] Допакеты: polkit agent, уведомления и прочее..."
sudo pacman -S --noconfirm --needed hyprpolkitagent swaync

# --- NV env и автозапуск — добавим, если отсутствуют ---
echo "[8/8] NV env/автостарт в hyprland.conf..."
HYPRCONF="$HOME/.config/hypr/hyprland.conf"
mkdir -p "$(dirname "$HYPRCONF")"; touch "$HYPRCONF"

grep -q "__GLX_VENDOR_LIBRARY_NAME" "$HYPRCONF" || printf '\nenv = __GLX_VENDOR_LIBRARY_NAME,nvidia\n' >> "$HYPRCONF"
grep -q "LIBVA_DRIVER_NAME"        "$HYPRCONF" || printf 'env = LIBVA_DRIVER_NAME,nvidia\n' >> "$HYPRCONF"
grep -q "NVD_BACKEND"              "$HYPRCONF" || printf 'env = NVD_BACKEND,direct\n' >> "$HYPRCONF"
grep -q "ELECTRON_OZONE_PLATFORM_HINT" "$HYPRCONF" || printf 'env = ELECTRON_OZONE_PLATFORM_HINT,auto\n' >> "$HYPRCONF"

# полкит-агент и уведомлялка
grep -q "hyprpolkitagent" "$HYPRCONF" || printf '\nexec-once = systemctl --user start hyprpolkitagent\n' >> "$HYPRCONF"
grep -q "^exec-once = swaync" "$HYPRCONF" || printf 'exec-once = swaync\n' >> "$HYPRCONF"

echo
echo "Готово. РЕКОМЕНДУЮ перезагрузку. После ребута войди в TTY и запусти Hyprland командой: Hyprland"
