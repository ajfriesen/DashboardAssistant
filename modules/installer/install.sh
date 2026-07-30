# Interactive installer: partition a disk from the same declarative disko layout
# the persistent system is built with, copy the pre-built system closure onto it,
# then power off. Runs on the console of the live USB. $DISKO_SCRIPT, $SRC_DEVICE
# and $SYS_TOPLEVEL are prepended by installer.nix; everything it needs is already
# in this ISO's store, so the whole install is offline (no network).
#
# The operator explicitly chooses the target disk and confirms by typing its name
# — nothing is ever erased automatically. This USB stick is safe to leave lying
# around: booting it can't wipe a machine without someone at the console.

banner() {
  printf '\n=== Dashboard Assistant installer ===\n'
  printf '%s\n\n' "$1"
}

# Bail out without writing anything, leaving a shell for a human to inspect.
abort_to_shell() {
  banner "$1"
  echo "Nothing was written. Dropping to a shell for inspection."
  exec bash -i
}

# Let udev finish enumerating disks before we look at them.
udevadm settle || true

# Best-effort: the disk we booted the installer from, so we never offer it as a
# target. The live medium's filesystem is mounted at /iso; map that partition to
# its parent disk.
bootdisk=""
bootpart="$(findmnt -n -o SOURCE /iso 2>/dev/null || true)"
if [ -n "$bootpart" ]; then
  bootdisk="$(lsblk -ndo PKNAME "$bootpart" 2>/dev/null || true)"
fi

# Installable whole disks: real disks only, excluding virtual devices, the eMMC's
# hardware boot/RPMB areas, USB-attached disks, and the USB we booted from.
disks=()
while read -r name rm tran type; do
  case "$name" in
    zram* | loop* | sr* | fd* | dm-*) continue ;; # virtual / optical / mapper
    mmcblk*boot* | mmcblk*rpmb) continue ;;        # eMMC hardware boot/RPMB areas
  esac
  [ "$type" = disk ] || continue          # whole disks only
  if [ "$rm" = 1 ]; then continue; fi      # skip removable media
  if [ "$tran" = usb ]; then continue; fi  # skip USB-attached disks
  if [ -n "$bootdisk" ] && [ "$name" = "$bootdisk" ]; then continue; fi
  disks+=("$name")
done < <(lsblk -dn -o NAME,RM,TRAN,TYPE)

if [ "${#disks[@]}" -eq 0 ]; then
  abort_to_shell "No installable internal disk found."
fi

# Present the disks and let the operator pick one. Nothing is preselected.
banner "Choose the disk to install onto. The selected disk will be ERASED."
echo "Detected internal disks:"
echo
n=1
for d in "${disks[@]}"; do
  info="$(lsblk -dn -o SIZE,MODEL "/dev/$d" 2>/dev/null)"
  printf '  %d) /dev/%-10s %s\n' "$n" "$d" "$info"
  n=$((n + 1))
done
printf '  q) abort — write nothing\n\n'

target=""
while [ -z "$target" ]; do
  printf 'Select a disk to ERASE and install onto [1-%d or q]: ' "${#disks[@]}"
  read -r choice || choice=q
  case "$choice" in
    q | Q) abort_to_shell "Aborted at the operator's request." ;;
    '' | *[!0-9]*) echo "  Enter a number from the list, or q to abort." ;;
    *)
      if [ "$choice" -ge 1 ] && [ "$choice" -le "${#disks[@]}" ]; then
        target="/dev/${disks[$((choice - 1))]}"
      else
        echo "  That number isn't on the list."
      fi
      ;;
  esac
done

# Require typing the disk name back verbatim — a deliberate, unambiguous
# confirmation that resists a reflexive "yes".
name="${target#/dev/}"
echo
echo "About to ERASE ${target}:"
lsblk -o NAME,SIZE,RM,TRAN,TYPE,MODEL "$target" || true
echo
printf 'Type the disk name "%s" to confirm (anything else aborts): ' "$name"
read -r confirm || confirm=""
if [ "$confirm" != "$name" ]; then
  abort_to_shell "Confirmation did not match — aborted."
fi

banner "Installing to ${target} — erasing now."

# Partition, format and mount the target via the disko script. It is generated
# for the image's build device ($SRC_DEVICE, e.g. /dev/vda); retarget the sole
# whole-disk reference to the chosen disk. Partitions are addressed by stable
# partition labels, so nothing else needs rewriting. The script wipes, creates
# the GPT + btrfs layout, and mounts it under /mnt.
work="$(mktemp -d)"
sed "s#${SRC_DEVICE}#${target}#g" "$DISKO_SCRIPT" >"$work/disko"
bash "$work/disko"

# Copy the pre-built system closure onto the fresh filesystems and install the
# bootloader. --system points at the already-built toplevel so nothing is
# evaluated or fetched; the closure is served from this ISO's local store.
nixos-install --root /mnt --system "$SYS_TOPLEVEL" --no-root-password --no-channel-copy

sync
umount -R /mnt || true

# Power off rather than reboot: the installer USB is usually earlier in the boot
# order than the internal disk, so rebooting with it still plugged in would boot
# straight back into the installer. Powering off lets the operator pull the
# stick, then power on into the freshly installed system.
banner "Install complete. Powering off — remove the USB stick, then power the device back on."
sleep 3
systemctl poweroff
