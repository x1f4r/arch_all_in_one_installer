#!/bin/bash

# Arch Linux All-in-One Installer - Enhanced Back Navigation and Custom Package Selection

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script as root."
  exit 1
fi

# Install required packages if not present
install_dependencies() {
  for pkg in arch-install-scripts curl fzf; do
    if ! command -v $pkg &> /dev/null; then
      echo "Installing '$pkg'..."
      pacman -Sy --noconfirm $pkg
    fi
  done
}
install_dependencies

# Logging setup
LOGFILE="/var/log/arch-installer.log"
exec > >(tee -a "$LOGFILE") 2>&1

log_message() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Variables to hold user choices
DEVICE=""
include_swap=1
BOOT_SIZE=""
SWAP_SIZE=""
ROOT_SIZE=""
selected_keymap=""
selected_timezone=""
hostname=""
selected_de=""
selected_term=""
PACKAGES="base linux linux-firmware"
enable_multilib=false
CATEGORY_PACKAGES=()
ADDITIONAL_PACMAN_PACKAGES=""
ADDITIONAL_AUR_PACKAGES=""
MOUNT_DIR="/mnt/iso"

# Function to download the ISO
download_iso() {
  # URL for the latest Arch Linux ISO from a mirror
  ISO_URL="https://mirror.rackspace.com/archlinux/iso/latest/archlinux-x86_64.iso"
  ISO_PATH="/tmp/archlinux-latest.iso"

  log_message "Downloading the latest Arch Linux ISO from $ISO_URL..."

  # Download the latest Arch Linux ISO using curl with a progress bar
  curl -# -L "$ISO_URL" -o "$ISO_PATH"
  if [ $? -eq 0 ]; then
    log_message "Download completed successfully: $ISO_PATH"
  else
    log_message "Download failed. Please check your internet connection or the mirror."
    exit 1
  fi

  # Verify the ISO was downloaded
  if [ ! -f "$ISO_PATH" ]; then
    log_message "ISO file not found after download."
    exit 1
  fi

  log_message "Arch Linux ISO has been successfully downloaded and saved to $ISO_PATH"
}

# Function to select the drive
select_drive() {
  while true; do
    echo -e "\nSelect the drive to install Arch Linux on:"
    DRIVE_SELECTION=$(list_drives | fzf --prompt="Drive> " --height 10 --border --bind "esc:abort")
    if [ -z "$DRIVE_SELECTION" ]; then
      echo "No drive selected. Exiting."
      exit 1
    fi

    # Extract the device name from the selection
    DEVICE=$(echo "$DRIVE_SELECTION" | awk '{print $1}')

    # Confirm drive selection
    echo -e "\nWARNING: All data on $DEVICE will be erased. Continue? (yes/no)"
    read -r confirmation
    if [ "$confirmation" == "yes" ]; then
      break
    fi
  done

  # Unmount and deactivate any existing partitions on the device
  umount "${DEVICE}"* &> /dev/null || true
  swapoff "${DEVICE}"* &> /dev/null || true
}

# Function to list available drives
list_drives() {
  local drives=()
  for drive in /dev/sd[a-z] /dev/nvme[0-9]n[0-9]; do
    if [ -b "$drive" ]; then
      size=$(lsblk -dn -o SIZE "$drive")
      model=$(lsblk -dn -o MODEL "$drive" | sed 's/ *$//g')
      [ -z "$model" ] && model="Unknown Model"
      drives+=("$drive - $model - $size")
    fi
  done
  printf "%s\n" "${drives[@]}"
}

# Function to partition the disk
partition_disk() {
  while true; do
    echo -e "\nDo you want to create a swap partition? (yes/no)"
    read -r include_swap_response
    if [ "$include_swap_response" == "yes" ]; then
      include_swap=0
    else
      include_swap=1
    fi

    # Prompt for partition sizes
    echo -e "\nEnter Boot partition size (e.g., 512M, 1G) [Default: 512M]:"
    read -r BOOT_SIZE
    BOOT_SIZE=${BOOT_SIZE:-512M}

    if [ "$include_swap" -eq 0 ]; then
      echo -e "\nEnter Swap partition size (e.g., 2G, 4G) [Default: 4G]:"
      read -r SWAP_SIZE
      SWAP_SIZE=${SWAP_SIZE:-4G}
    fi

    # Filesystem selection for root partition
    echo -e "\nSelect filesystem for Root partition:"
    fs_options=("ext4" "btrfs" "xfs" "f2fs")
    ROOT_FS=$(printf "%s\n" "${fs_options[@]}" | fzf --prompt="Filesystem> " --height 10 --border --bind "esc:abort")
    ROOT_FS=${ROOT_FS:-ext4}

    # Validate inputs
    if ! [[ "$BOOT_SIZE" =~ ^[0-9]+[MG]$ ]]; then
      echo "Invalid Boot partition size."
      continue
    fi
    if [ "$include_swap" -eq 0 ] && ! [[ "$SWAP_SIZE" =~ ^[0-9]+[MG]$ ]]; then
      echo "Invalid Swap partition size."
      continue
    fi
    break
  done

  # Partitioning steps remain the same as before
  # ... (omitting code for brevity)
}

# Function to select keyboard layout
select_keyboard_layout() {
  while true; do
    echo -e "\nSelect a Keyboard Layout (Press ESC to go back):"
    keymaps=( $(localectl list-keymaps) )
    selected_keymap=$(printf "%s\n" "${keymaps[@]}" | fzf --prompt="Keymap> " --height 15 --border --bind "esc:abort")
    if [ -z "$selected_keymap" ]; then
      echo "Using default keymap: us"
      selected_keymap="us"
      break
    else
      break
    fi
  done
}

# Function to select timezone
select_timezone() {
  while true; do
    echo -e "\nSelect your Timezone (Press ESC to go back):"
    timezones=$(timedatectl list-timezones)
    selected_timezone=$(printf "%s\n" "$timezones" | fzf --prompt="Timezone> " --height 15 --border --bind "esc:abort")
    if [ -z "$selected_timezone" ]; then
      echo "Using default timezone: UTC"
      selected_timezone="UTC"
      break
    else
      break
    fi
  done
}

# Function to set hostname
set_hostname() {
  while true; do
    echo -e "\nEnter a hostname for your system (Default: archlinux):"
    read -r hostname
    hostname=${hostname:-archlinux}
    if [ -n "$hostname" ]; then
      break
    fi
  done
}

# Function to select desktop environment
select_desktop_environment() {
  while true; do
    echo -e "\nSelect a Desktop Environment (Press ESC to go back):"
    de_options=(
      "GNOME" "GNOME Desktop Environment"
      "Plasma" "KDE Plasma Desktop"
      "XFCE" "XFCE Desktop Environment"
      "Cinnamon" "Cinnamon Desktop Environment"
      "MATE" "MATE Desktop Environment"
      "Custom" "Custom Desktop Environment"
      "None" "No Desktop Environment"
    )
    selected_de=$(printf "%s\n" "${de_options[@]}" | paste - - | awk '{print $1}' | fzf --prompt="DE> " --height 10 --border --bind "esc:abort")
    if [ -z "$selected_de" ]; then
      continue
    fi

    # Map selection to packages
    case "$selected_de" in
      "GNOME")
        DE_PACKAGES="gnome gnome-extra gdm"
        ;;
      "Plasma")
        DE_PACKAGES="plasma-meta kde-applications-meta sddm"
        ;;
      "XFCE")
        DE_PACKAGES="xfce4 xfce4-goodies lightdm lightdm-gtk-greeter"
        ;;
      "Cinnamon")
        DE_PACKAGES="cinnamon lightdm lightdm-gtk-greeter"
        ;;
      "MATE")
        DE_PACKAGES="mate mate-extra lightdm lightdm-gtk-greeter"
        ;;
      "Custom")
        echo -e "\nEnter the packages for your custom desktop environment (separated by spaces):"
        read -r DE_PACKAGES
        ;;
      "None")
        DE_PACKAGES=""
        ;;
    esac
    break
  done
}

# Function to select terminal emulator
select_terminal_emulator() {
  while true; do
    echo -e "\nSelect a Terminal Emulator (Press ESC to go back):"
    term_options=(
      "Kitty"
      "Alacritty"
      "Tilix"
      "GNOME Terminal"
      "Custom"
      "None"
    )
    selected_term=$(printf "%s\n" "${term_options[@]}" | fzf --prompt="Terminal> " --height 10 --border --bind "esc:abort")
    if [ -z "$selected_term" ]; then
      continue
    fi

    # Map selection to packages
    case "$selected_term" in
      "Kitty")
        TERM_PACKAGES="kitty"
        ;;
      "Alacritty")
        TERM_PACKAGES="alacritty"
        ;;
      "Tilix")
        TERM_PACKAGES="tilix"
        ;;
      "GNOME Terminal")
        TERM_PACKAGES="gnome-terminal"
        ;;
      "Custom")
        echo -e "\nEnter the packages for your custom terminal emulator (separated by spaces):"
        read -r TERM_PACKAGES
        ;;
      "None")
        TERM_PACKAGES=""
        ;;
    esac
    break
  done
}

# Function to select packages with hierarchical navigation
select_packages() {
  declare -A package_categories
  package_categories=(
    ["Audio"]="pipewire pipewire-pulse pipewire-alsa pipewire-jack"
    ["Development"]="base-devel git neovim code docker"
    ["Fonts"]="ttf-dejavu ttf-liberation noto-fonts"
    ["Internet"]="firefox chromium thunderbird transmission-gtk"
    ["Multimedia"]="vlc obs-studio gimp inkscape"
    ["Network"]="networkmanager"
    ["Office"]="libreoffice-fresh"
    ["Shell"]="zsh bash-completion"
    ["Utilities"]="htop neofetch tree unzip"
  )

  # Sort categories logically (alphabetically)
  sorted_categories=($(printf "%s\n" "${!package_categories[@]}" | sort))

  # Initialize selection variables
  current_level="categories"
  selected_category=""
  declare -A category_package_selection

  while true; do
    if [ "$current_level" == "categories" ]; then
      # Display categories
      category=$(printf "%s\n" "${sorted_categories[@]}" | fzf --prompt="Categories> " --height 15 --border \
        --bind "right:execute(echo {} > /tmp/selected_category; echo 'ENTER' > /tmp/selected_action)+abort" \
        --bind "esc:abort" --expect=enter)

      # Read action from /tmp/selected_action
      if [ -f /tmp/selected_action ]; then
        action=$(cat /tmp/selected_action)
        rm /tmp/selected_action
      else
        action=""
      fi

      if [ "$action" == "ENTER" ]; then
        selected_category=$(cat /tmp/selected_category)
        rm /tmp/selected_category
        current_level="packages"
      else
        break  # User pressed ESC, exit package selection
      fi

    elif [ "$current_level" == "packages" ]; then
      # Display packages in the selected category, allow selection/deselection
      packages_in_category=${package_categories[$selected_category]}
      IFS=' ' read -r -a package_array <<< "$packages_in_category"

      # Get existing selections or use default
      existing_selection=()
      if [ -n "${category_package_selection[$selected_category]}" ]; then
        existing_selection=(${category_package_selection[$selected_category]})
      else
        existing_selection=("${package_array[@]}")
      fi

      # Allow user to select/deselect packages
      selected_packages=$(printf "%s\n" "${package_array[@]}" | fzf --multi --prompt="Packages> " --height 15 --border \
        --bind "esc:execute(echo 'BACK' > /tmp/selected_action)+abort" \
        --bind "left:execute(echo 'BACK' > /tmp/selected_action)+abort" \
        --expect=enter --ansi --preview-window=up:1 \
        --header="Press ENTER to confirm, ESC or LEFT to go back" \
        --toggle-on="${existing_selection[@]}")

      # Read action
      if [ -f /tmp/selected_action ]; then
        action=$(cat /tmp/selected_action)
        rm /tmp/selected_action
        if [ "$action" == "BACK" ]; then
          current_level="categories"
          continue
        fi
      fi

      # Update selected packages
      IFS=$'\n' read -r -d '' -a selected_packages_array <<< "$selected_packages"
      category_package_selection[$selected_category]="${selected_packages_array[@]}"

      # Return to category selection
      current_level="categories"
    fi
  done

  # Combine selected packages from all categories
  for category in "${!category_package_selection[@]}"; do
    CATEGORY_PACKAGES+=("${category_package_selection[$category]}")
  done
}

# Function to input additional packages
input_additional_packages() {
  while true; do
    echo -e "\nEnter additional pacman packages to install (separated by spaces):"
    read -r ADDITIONAL_PACMAN_PACKAGES

    echo -e "\nEnter additional AUR packages to install (separated by spaces):"
    read -r ADDITIONAL_AUR_PACKAGES

    echo -e "\nAre these correct? (yes to proceed, no to re-enter)"
    echo "Pacman packages: $ADDITIONAL_PACMAN_PACKAGES"
    echo "AUR packages: $ADDITIONAL_AUR_PACKAGES"
    read -r confirm
    if [ "$confirm" == "yes" ]; then
      break
    fi
  done
}

# Function to ask about Multilib support
ask_multilib_support() {
  while true; do
    echo -e "\nDo you want to enable Multilib Support? (yes/no)"
    read -r multilib_response
    if [ "$multilib_response" == "yes" ]; then
      enable_multilib=true
      break
    elif [ "$multilib_response" == "no" ]; then
      enable_multilib=false
      break
    fi
  done
}

# Function to perform installation
perform_installation() {
  # Combine selected packages
  PACKAGES="$PACKAGES $DE_PACKAGES $TERM_PACKAGES ${CATEGORY_PACKAGES[@]} $ADDITIONAL_PACMAN_PACKAGES"

  echo -e "\nInstalling base system and selected packages..."
  # Redirect output to log file to suppress verbose output
  pacstrap -c /mnt $PACKAGES --cachedir="$MOUNT_DIR" --noconfirm &>> "$LOGFILE"

  # Check if pacstrap was successful
  if [ $? -ne 0 ]; then
    echo "An error occurred during the installation. Please check the log file at $LOGFILE for details."
    exit 1
  fi

  # Generate FSTAB
  genfstab -U /mnt >> /mnt/etc/fstab

  # Configuration in chroot
  echo "Configuring the system..."
  arch-chroot /mnt /bin/bash <<EOF
  # Set timezone
  ln -sf /usr/share/zoneinfo/$selected_timezone /etc/localtime
  hwclock --systohc

  # Set localization
  echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
  locale-gen
  echo "LANG=en_US.UTF-8" > /etc/locale.conf
  echo "KEYMAP=$selected_keymap" > /etc/vconsole.conf

  # Set hostname
  echo "$hostname" > /etc/hostname
  echo "127.0.0.1   localhost" >> /etc/hosts
  echo "::1         localhost" >> /etc/hosts
  echo "127.0.1.1   $hostname.localdomain $hostname" >> /etc/hosts

  # Enable multilib repository if selected
  if [ "$enable_multilib" = true ]; then
    sed -i '/\[multilib\]/,/Include/ s/^#//' /etc/pacman.conf
    pacman -Sy --noconfirm &>> "$LOGFILE"
  fi

  # Install GRUB and efibootmgr
  pacman -S grub efibootmgr --noconfirm &>> "$LOGFILE"

  # Install GRUB bootloader to the EFI directory
  grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB &>> "$LOGFILE"

  # Generate GRUB configuration file
  grub-mkconfig -o /boot/grub/grub.cfg &>> "$LOGFILE"

  # Enable necessary services
  if pacman -Qs gdm &> /dev/null; then
    systemctl enable gdm &>> "$LOGFILE"
  elif pacman -Qs sddm &> /dev/null; then
    systemctl enable sddm &>> "$LOGFILE"
  elif pacman -Qs lightdm &> /dev/null; then
    systemctl enable lightdm &>> "$LOGFILE"
  fi

  if pacman -Qs NetworkManager &> /dev/null; then
    systemctl enable NetworkManager &>> "$LOGFILE"
  fi

  # Set default shell to zsh if installed
  if pacman -Qs zsh &> /dev/null; then
    chsh -s /bin/zsh root
    # Install oh-my-zsh
    pacman -S git --noconfirm &>> "$LOGFILE"
    git clone https://github.com/ohmyzsh/ohmyzsh.git /root/.oh-my-zsh &>> "$LOGFILE"
    cp /root/.oh-my-zsh/templates/zshrc.zsh-template /root/.zshrc
  fi

  # Install yay AUR helper
  pacman -S --noconfirm git base-devel &>> "$LOGFILE"
  git clone https://aur.archlinux.org/yay.git /tmp/yay &>> "$LOGFILE"
  cd /tmp/yay
  makepkg -si --noconfirm &>> "$LOGFILE"

  # Install additional AUR packages
  if [ -n "$ADDITIONAL_AUR_PACKAGES" ]; then
    sudo -u root yay -S --noconfirm $ADDITIONAL_AUR_PACKAGES &>> "$LOGFILE"
  fi

EOF

  # Set root password
  echo -e "\nYou will now set the root password for the new installation."
  arch-chroot /mnt passwd root

  # Clean up
  echo "Finalizing installation..."
  umount -R /mnt
  swapoff -a
  rm -rf "$ISO_PATH"

  # Completion message
  echo -e "\nArch Linux has been installed successfully on $DEVICE."
  echo "You can reboot now."
}

# Main installation loop with back navigation
main_installation() {
  steps=("download_iso" "select_drive" "partition_disk" "select_keyboard_layout" "select_timezone" "set_hostname" "select_desktop_environment" "select_terminal_emulator" "ask_multilib_support" "select_packages" "input_additional_packages" "perform_installation")
  current_step=0
  total_steps=${#steps[@]}

  while [ $current_step -lt $total_steps ]; do
    ${steps[$current_step]}
    if [ $? -ne 0 ]; then
      echo -e "\nAn error occurred. Do you want to go back to the previous step? (yes/no)"
      read -r go_back
      if [ "$go_back" == "yes" ] && [ $current_step -gt 0 ]; then
        ((current_step--))
      else
        echo "Installation cancelled."
        exit 1
      fi
    else
      ((current_step++))
    fi
  done
}

# Start the installation
main_installation

