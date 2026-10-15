#!/bin/bash

# Title: Meshtastic
# Description: Meshtastic Start/Stop and Uninstall; Enable at Boot defaults OFF
# Author: GlytchTech
# Version: 9

set -u
# Never inherit hook suppression into normal dependency transactions.
unset IPKG_NO_SCRIPT
unset MESH_EXPLICIT_START MESHTASTIC_SESSION_START MESHTASTIC_BOOT_CHOICE_CHANGE
if ! command -v LOG >/dev/null 2>&1; then LOG() { printf '%s\n' "$*"; }; fi

# Single-file USB installer: uses the unmodified public Meshtastic package.
# Explicitly approved compatibility shim provides kmod-spi-dev globally to opkg.
# The shim contains no kernel driver. Other SPI consumers must not rely on it.
# Upstream: https://github.com/meshtastic/firmware (GPL-3.0-only)
# USB profile: v2.7.26.54e0d8d, available.d/lora-usb-meshtoad-e22.yaml
PACKAGE_VERSION='2.7.26-r1'
OLD_USB_VERSION='2.7.26-r1+meshusb.1'
BINARY_SHA256='615d3d9873f78c42a1e7722d03c0a2ddbeb156cdd1972b49cd0c7cab3a4d4e10'
KERNEL_VERSION='6.6.86~c8badeb44cdf8ea9da9e8314010b8614-r1'
REAL_DEPS=(libc bluez-libs libgpiod libi2c libopenssl3 liborcania libulfius-gnutls libusb-1.0-0 libuv1 libyaml-cpp0.7 libyder zlib)
UPSTREAM_URL='https://openwrt.meshtastic.org/openwrt-24.10/mipsel_24kc/meshtasticd-full_2.7.26-r1_mipsel_24kc.ipk'
UPSTREAM_SHA256='5cf3398ace72d4d5dd06a0383d4f54d048856d6c723c9c4909876171aaaa6fd5'
KEY_SHA256='73560c33aeb36336b9c5107b5b6f3f42a7ff54207ed8c9b58c4b89c07a397679'
PROFILE_SHA256='1c04468b4480c45afde5ac40512a2acaf6bf3702f2a9304f7d4e70dca425e5c0'
FEED='https://openwrt.meshtastic.org/openwrt-24.10/mipsel_24kc'
WORK=''
PACKAGE=''
KEY=''
PROFILE=''
SERVICE='/etc/init.d/meshtasticd'
BOOT_SETTINGS='/etc/config/meshtastic_payload'
CANONICAL_PAYLOAD='/root/payloads/user/general/Meshtastic/payload.sh'
BOOT_LINK='/etc/rc.d/S99meshtasticd'
PERSISTENT_DATA='/root/.meshtasticd'
LEGACY_DATA='/var/lib/meshtasticd'
LOCK_DIR='/tmp/meshtastic-payload.lock'
lock_owned=0
state_stage=''
PUBLIC_INIT_SHA256='bc688b88dd6e98c92d6c1d63f18e760b946c0cf72425a732d08dc3d4bcc1bdad'
OLD_MANUAL_INIT_SHA256='565c8fc19548ee46e420bd97eac61297ea8a379e6084a29c3d05d4ce46f50474'
PREVIOUS_GUARDED_INIT_SHA256='068fb493fe214085596f67fc9d3c64be088ffba99f17af01071c9226bb78d383'
GUARDED_INIT_SHA256='8c6c65999f4bbea234969dc3279def14e3535833c4cd97d2667d8476a5fb9a54'
ACTION='menu'
UNINSTALL=0
shim_added=0
need_shim=0
backup=''
stopped=0
profile_added=0
profile_needed=0
created_profile_sha=''
package_installed=0

cleanup() {
  rc=$?
  if [ "$rc" -ne 0 ] && [ "$profile_added" -eq 1 ] && [ "$package_installed" -eq 0 ] && [ -f "${DST-}" ]; then
    current_profile_sha="$(sha256sum "$DST" 2>/dev/null | awk '{print $1}')"
    [ "$current_profile_sha" != "$created_profile_sha" ] || rm -f "$DST"
  fi
  if [ "$rc" -ne 0 ] && [ "$stopped" -eq 1 ]; then LOG 'Meshtastic remains stopped; use Start explicitly after resolving the error'; fi
  if [ "$rc" -ne 0 ] && [ "$shim_added" -eq 1 ]; then
    if refresh_status && [ -z "$(consumers 'kmod-spi-dev' "$MESH_COMPAT_PACKAGE")" ]; then
      if opkg remove "$MESH_COMPAT_PACKAGE" >> "$backup/package.log" 2>&1; then
        if ! refresh_status || is_registered "$MESH_COMPAT_PACKAGE" || [ -e "$MESH_COMPAT_MARKER" ] || [ -L "$MESH_COMPAT_MARKER" ]; then
          LOG 'Installation cleanup is incomplete; inspect package status and the backup'
        fi
      else LOG "Installation cleanup failed; new package retained. Details: $backup/package.log"; fi
    else
      LOG 'Installation cleanup skipped: another package still depends on it; inspect package status and the backup'
    fi
  fi
  if [ "$rc" -ne 0 ] && [ -n "$backup" ]; then LOG "Recovery backup retained: $backup"; fi
  [ -z "$WORK" ] || rm -rf "$WORK"
  [ -z "$state_stage" ] || rm -rf "$state_stage"
  if [ "$lock_owned" -eq 1 ] && [ "$(cat "$LOCK_DIR/pid" 2>/dev/null)" = "$$" ]; then
    rm -f "$LOCK_DIR/pid"
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

fail() { LOG "FAIL: $*"; exit 1; }
lock_action() {
  [ "$ACTION" != status ] || return 0
  (umask 077; mkdir "$LOCK_DIR") 2>/dev/null || fail "Another Meshtastic action holds $LOCK_DIR; check for an active action or stale lock before retrying"
  lock_owned=1
  if ! printf '%s\n' "$$" > "$LOCK_DIR/pid"; then
    rm -f "$LOCK_DIR/pid"
    rmdir "$LOCK_DIR" 2>/dev/null || true
    lock_owned=0
    fail 'Cannot record the Meshtastic action lock'
  fi
}
case "${1-}" in
  '') ;;
  --install|--update) ACTION='install' ;;
  --start) ACTION='start' ;;
  --stop) ACTION='stop' ;;
  --boot-on) ACTION='boot-on' ;;
  --boot-off) ACTION='boot-off' ;;
  --boot-start) ACTION='boot-start' ;;
  --status) ACTION='status' ;;
  --uninstall) ACTION='uninstall'; UNINSTALL=1 ;;
  *) fail 'Usage: payload.sh [--install|--update|--start|--stop|--boot-on|--boot-off|--status|--uninstall]' ;;
esac
[ "$#" -le 1 ] || fail 'Use one Meshtastic action at a time'
if [ "$ACTION" = boot-start ]; then
  # Boot has no PayloadRunner UI context; send its diagnostics to system logs.
  LOG() { logger -t meshtastic-payload "$*" 2>/dev/null || printf '%s\n' "$*"; }
fi

verify_file() {
  [ -s "$1" ] || fail "Required file missing or empty: $(basename "$1")"
  printf '%s  %s\n' "$2" "$1" | sha256sum -c - >/dev/null 2>&1 || fail "Checksum failed: $(basename "$1")"
}

prepare_work() {
  [ -z "$WORK" ] || return 0
  WORK="$(umask 077; mktemp -d /tmp/mesh-installer.XXXXXX)" || fail 'Cannot create private installer staging directory'
  PACKAGE="$WORK/meshtasticd-full_${PACKAGE_VERSION}_mipsel_24kc.ipk"
  KEY="$WORK/meshtastic-ipk.pub"
  PROFILE="$WORK/lora-usb-meshtoad-e22.yaml"
}

write_key() {
  prepare_work
  printf '%s\n%s' 'untrusted comment: Meshtastic OpenWRT IPK Repo public key' 'RWS87sxZ9aKOrUptwSfC+7UsKhB501FH3Y5M7wD4XI82sgXIIEX5UAqJ' > "$KEY" || fail 'Cannot stage public signing key'
  verify_file "$KEY" "$KEY_SHA256"
}

write_profile() {
  prepare_work
  cat > "$PROFILE" <<'MESH_USB_PROFILE'
# This config works with all revisions of the Meshtoad USB radio.

Meta:
  name: meshtoad-e22
  support: official
  compatible:
    - usb

Lora:
  Module: sx1262
  CS: 0
  IRQ: 6
  Reset: 2
  Busy: 4
  RXen: 1
  DIO2_AS_RF_SWITCH: true
  DIO3_TCXO_VOLTAGE: true
  spidev: ch341
  USB_PID: 0x5512
  USB_VID: 0x1A86
  # Optional: Reduce power to 10 dBm to
  # avoid over-drawing the USB port
  # SX126X_MAX_POWER: 10
  # Optional: Set the serial number for multi-radio support
  # USB_Serialnum: 13374201
MESH_USB_PROFILE
  verify_file "$PROFILE" "$PROFILE_SHA256"
}

prepare_package() {
  prepare_work
  command -v curl >/dev/null 2>&1 || fail 'Verified HTTPS download requires curl (included in Pager 1.1.2)'
  LOG 'Downloading the pinned upstream MeshtasticD package'
  curl -q --fail --location --proto '=https' --proto-redir '=https' \
    --connect-timeout 20 --max-time 180 --output "$PACKAGE" "$UPSTREAM_URL" || fail 'MeshtasticD download failed; check connectivity and TLS certificates'
  verify_file "$PACKAGE" "$UPSTREAM_SHA256"
  tar -xOzf "$PACKAGE" ./control.tar.gz > "$WORK/control.tar.gz" || fail 'Cannot inspect public package control'
  tar -xOzf "$WORK/control.tar.gz" ./control > "$WORK/control" || fail 'Cannot inspect public package metadata'
  verify_file "$WORK/control" '425bbd0c539e0f4f78fcc5c96cb587795d42d98384040ad1a0448911ad96e2f8' 
}


opkg_update() {
  LOG 'Running opkg update'
  opkg update >/tmp/mesh-opkg-update.log 2>&1 || fail 'opkg update failed; see /tmp/mesh-opkg-update.log. Check connectivity and feed signatures.'
}

radio_selected() {
  # Only Lora keys select a radio; keep display/GPS profiles and Module:auto.
  awk '
    /^[^[:space:]#][^:]*:/ { lora = /^Lora:/; if (lora && /\{/) selected=1 }
    lora && /^[[:space:]]+(Module|spidev):/ {
      value=$0; sub(/^[[:space:]]+[^:]+:[[:space:]]*/, "", value)
      sub(/[[:space:]]*#.*/, "", value); gsub(/[[:space:]"\047]/, "", value)
      if (value != "" && value != "auto" && value != "null" && value != "~") selected=1
    }
    END { exit(selected ? 0 : 1) }
  ' "$1"
}

stop_service() {
  "$SERVICE" stop || fail 'Cannot stop MeshtasticD for configuration/update'
  for ((wait_attempt=0; wait_attempt<10; wait_attempt++)); do
    if [ -z "$(pidof meshtasticd 2>/dev/null || true)" ] && service_definition_absent; then stopped=1; return 0; fi
    sleep 2
  done
  fail 'MeshtasticD process or service definition remains; Stop could not be verified'
}

MESH_COMPAT_PACKAGE=meshtastic-usb-spidev-compat
MESH_COMPAT_VERSION=1.0-r1
MESH_COMPAT_MARKER=/usr/share/meshtastic-usb-spidev-compat/NOTICE
MESH_COMPAT_MARKER_SHA256=0e9968b4fb06ea4dfd86fefe297fbe104391671f7c28d074dc24e4623f341531

mesh_compat_notice() {
    cat <<'NOTICE'
meshtastic-usb-spidev-compat 1.0-r1

Disclosed USB-only compatibility provider for Meshtastic userspace CH341 USB radios.
This package provides the name kmod-spi-dev globally to opkg.
It contains NO kernel driver, does NOT enable kernel SPI support, and does NOT
provide /dev/spidev devices. It must not be used for kernel-controlled SPI radios.
Other packages can also regard its global Provides claim as satisfying kmod-spi-dev.
Removing this package removes that claim and this notice; it does not unload a driver.
NOTICE
}

mesh_compat_control() {
    cat <<'CONTROL'
Package: meshtastic-usb-spidev-compat
Version: 1.0-r1
Architecture: all
Provides: kmod-spi-dev
Section: utils
Description: Disclosed USB-only Meshtastic dependency compatibility provider.
 Contains NO kernel driver and does NOT enable SPI support or spidev devices.
 Provides kmod-spi-dev globally only for the acknowledged userspace USB workaround.
CONTROL
}

# BusyBox tar has no creation-time --owner/--group option. On the Pager this
# executes as root:root. The BSD branch permits a checked workstation prototype
# without root privileges and never runs on a normal root Pager invocation.
mesh_compat_pack_tar() {
    local archive=$1 directory=$2
    shift 2
    if [ "$(id -u)" = 0 ] && [ "$(id -g)" = 0 ]; then
        COPYFILE_DISABLE=1 tar -cf "$archive" -C "$directory" "$@"
    elif tar --version 2>/dev/null | awk 'NR == 1 { exit ($0 !~ /bsdtar/) }'; then
        COPYFILE_DISABLE=1 tar -cf "$archive" --format ustar --uid 0 --gid 0 \
            --uname root --gname root -C "$directory" "$@"
    else
        printf '%s\n' 'Compatibility IPK must be built as root:root with BusyBox tar.' >&2
        return 1
    fi
}

mesh_compat_build_ipk() (
    # Subshell: this cleanup trap and umask do not replace the caller's trap.
    set -e
    set -o pipefail
    umask 077
    local output=${1:-} work marker_hash
    [ -n "$output" ] || { printf '%s\n' 'Missing output IPK path.' >&2; exit 1; }
    case "$output" in
        /*) ;;
        *) output="$PWD/$output" ;;
    esac
    [ ! -e "$output" ] && [ ! -L "$output" ] || {
        printf '%s\n' 'Refusing to overwrite an existing output path.' >&2
        exit 1
    }
    work=$(mktemp -d /tmp/mesh-spidev-compat.XXXXXX) || exit 1
    trap 'rm -rf "$work"' EXIT
    trap 'exit 1' HUP INT TERM
    mkdir -p "$work/control" "$work/data/usr/share/$MESH_COMPAT_PACKAGE" "$work/outer" "$work/reopened" || exit 1
    chmod 755 "$work/data/usr" "$work/data/usr/share" "$work/data/usr/share/$MESH_COMPAT_PACKAGE" || exit 1
    mesh_compat_control > "$work/control/control" || exit 1
    mesh_compat_notice > "$work/data${MESH_COMPAT_MARKER}" || exit 1
    chmod 644 "$work/control/control" "$work/data${MESH_COMPAT_MARKER}" || exit 1
    printf '2.0\n' > "$work/outer/debian-binary" || exit 1
    chmod 644 "$work/outer/debian-binary" || exit 1

    # Separate tar and gzip operations avoid relying on tar -z support.
    mesh_compat_pack_tar "$work/control.tar" "$work/control" control || exit 1
    gzip -c "$work/control.tar" > "$work/outer/control.tar.gz" || exit 1
    mesh_compat_pack_tar "$work/data.tar" "$work/data" usr || exit 1
    gzip -c "$work/data.tar" > "$work/outer/data.tar.gz" || exit 1
    chmod 644 "$work/outer/control.tar.gz" "$work/outer/data.tar.gz" || exit 1
    mesh_compat_pack_tar "$work/outer.tar" "$work/outer" debian-binary control.tar.gz data.tar.gz || exit 1
    gzip -c "$work/outer.tar" > "$work/package.ipk" || exit 1

    # Reopen the completed IPK and verify exact member sets before extraction.
    gzip -dc "$work/package.ipk" > "$work/reopened/outer.tar" || exit 1
    printf 'debian-binary\ncontrol.tar.gz\ndata.tar.gz\n' > "$work/expected-outer" || exit 1
    tar -tf "$work/reopened/outer.tar" > "$work/actual-outer" || exit 1
    cmp "$work/expected-outer" "$work/actual-outer" || exit 1
    tar -xf "$work/reopened/outer.tar" -C "$work/reopened" || exit 1
    printf '2.0\n' > "$work/expected-debian-binary" || exit 1
    cmp "$work/expected-debian-binary" "$work/reopened/debian-binary" || exit 1
    gzip -dc "$work/reopened/control.tar.gz" > "$work/reopened/control.tar" || exit 1
    printf 'control\n' > "$work/expected-control" || exit 1
    tar -tf "$work/reopened/control.tar" > "$work/actual-control" || exit 1
    cmp "$work/expected-control" "$work/actual-control" || exit 1
    tar -xOf "$work/reopened/control.tar" control > "$work/reopened/control" || exit 1
    cmp "$work/control/control" "$work/reopened/control" || exit 1
    # Exact control contents above exclude Depends, hooks, and fake kernel metadata.

    gzip -dc "$work/reopened/data.tar.gz" > "$work/reopened/data.tar" || exit 1
    printf 'usr/\nusr/share/\nusr/share/%s/\nusr/share/%s/NOTICE\n' \
        "$MESH_COMPAT_PACKAGE" "$MESH_COMPAT_PACKAGE" > "$work/expected-data" || exit 1
    tar -tf "$work/reopened/data.tar" > "$work/actual-data" || exit 1
    cmp "$work/expected-data" "$work/actual-data" || exit 1
    tar -xOf "$work/reopened/data.tar" "${MESH_COMPAT_MARKER#/}" > "$work/reopened/NOTICE" || exit 1
    cmp "$work/data${MESH_COMPAT_MARKER}" "$work/reopened/NOTICE" || exit 1
    marker_hash=$(sha256sum "$work/reopened/NOTICE") || exit 1
    marker_hash=${marker_hash%% *}
    [ "$marker_hash" = "$MESH_COMPAT_MARKER_SHA256" ] || {
        printf '%s\n' 'Compatibility notice hash mismatch.' >&2
        exit 1
    }
    tar -tvf "$work/reopened/control.tar" | awk '
        { if ($1 != "-rw-r--r--") exit 1; count++ }
        END { if (count != 1) exit 1 }
    ' || exit 1
    tar -tvf "$work/reopened/data.tar" | awk '
        /NOTICE$/ { if ($1 != "-rw-r--r--") exit 1; files++ ; next }
        { if ($1 != "drwxr-xr-x") exit 1; dirs++ }
        END { if (files != 1 || dirs != 3) exit 1 }
    ' || exit 1
    # The caller normally places output inside its own private temporary directory.
    # Noclobber also rejects a path created after the initial existence check.
    (set -C; cat "$work/package.ipk" > "$output") || exit 1
    chmod 600 "$output" || exit 1
    printf '%s\n' "$output"
)


# Read-only view includes partial states omitted by `opkg status`; writes remain
# exclusively normal opkg transactions.
refresh_status() { STATUS="$(cat /usr/lib/opkg/status 2>/dev/null)"; }
status_field() {
  printf '%s\n' "$STATUS" | awk -v wanted="$1" -v field="$2" 'BEGIN {RS=""; FS="\n"}
    { p=""; value=""; for(i=1;i<=NF;i++) { if($i ~ /^Package: /) p=substr($i,10); if(index($i,field ": ")==1) value=substr($i,length(field)+3) } if(p==wanted) {print value; exit} }'
}
is_installed() { [[ "$(status_field "$1" Status)" = *' installed' ]]; }
is_registered() { local s; s="$(status_field "$1" Status)"; [ -n "$s" ] && [[ "$s" != *' not-installed' ]]; }
consumers() {
  printf '%s\n' "$STATUS" | awk -v names="$1" -v skip="$2" 'BEGIN {RS=""; FS="\n"}
    {p=""; s=""; d=""; dep=0; for(i=1;i<=NF;i++) {
      if($i~/^Package: /)p=substr($i,10); if($i~/^Status: /)s=substr($i,9);
      if($i~/^(Depends|Pre-Depends): /) {line=$i; sub(/^[^:]+: /,"",line); d=d " " line; dep=1}
      else if($i~/^[[:space:]]/ && dep) d=d " " $i; else dep=0}
     if(p==skip || s=="" || s~/ not-installed$/)next; gsub(/\([^)]*\)/,"",d); gsub(/[,|]/," ",d); n=split(d,a,/[[:space:]]+/);
     for(i=1;i<=n;i++) if(a[i]~("^(" names ")$")) {print p; break} }'
}
spi_support_present() {
  local module_dir
  module_dir="/lib/modules/$(uname -r)"
  [ ! -d /sys/module/spidev ] || return 0
  awk '$1=="spidev" {found=1} END {exit !found}' /proc/modules 2>/dev/null && return 0
  for p in "$module_dir/spidev.ko" "$module_dir/spidev.ko.gz" "$module_dir/spidev.ko.xz" "$module_dir/kernel/drivers/spi/spidev.ko"; do
    [ ! -e "$p" ] && [ ! -L "$p" ] || return 0
  done
  for p in "$module_dir/modules.builtin"; do
    if [ -f "$p" ] && grep -Eq '(^|/)spidev\.ko$' "$p"; then return 0; fi
  done
  return 1
}
verify_shim() {
  is_installed "$MESH_COMPAT_PACKAGE" || fail 'Meshtastic installation is not fully configured'
  [ "$(status_field "$MESH_COMPAT_PACKAGE" Version)" = "$MESH_COMPAT_VERSION" ] || fail 'Unknown installation package version; preserving it'
  [ "$(status_field "$MESH_COMPAT_PACKAGE" Provides)" = kmod-spi-dev ] || fail 'Unexpected installation package metadata'
  [ -z "$(status_field "$MESH_COMPAT_PACKAGE" Depends)" ] || fail 'Installation package unexpectedly requires other packages'
  [ "$(status_field "$MESH_COMPAT_PACKAGE" Architecture)" = all ] || fail 'Unexpected installation package architecture'
  [ ! -L "$MESH_COMPAT_MARKER" ] || fail 'Installation record is a symlink; preserving it'
  verify_file "$MESH_COMPAT_MARKER" "$MESH_COMPAT_MARKER_SHA256"
  shim_files="$(opkg files "$MESH_COMPAT_PACKAGE")" || fail 'Cannot read installation file ownership'
  printf '%s\n' "$shim_files" | grep -Fxq "$MESH_COMPAT_MARKER" || fail 'Installation record is not tracked by its package'
  printf '%s\n' "$shim_files" | awk -v marker="$MESH_COMPAT_MARKER" '/^\// {p=$0;sub(/\/$/,"",p);if(p!="/usr" && p!="/usr/share" && p!="/usr/share/meshtastic-usb-spidev-compat" && p!=marker)bad=1} END {exit bad}' || fail 'Installation package owns unexpected files; preserving them'
  for p in /usr/lib/opkg/info/meshtastic-usb-spidev-compat.preinst /usr/lib/opkg/info/meshtastic-usb-spidev-compat.postinst /usr/lib/opkg/info/meshtastic-usb-spidev-compat.prerm /usr/lib/opkg/info/meshtastic-usb-spidev-compat.postrm; do
    [ ! -e "$p" ] && [ ! -L "$p" ] || fail 'Installation package has unexpected scripts; preserving it'
  done
}
assert_compatibility_target_available() {
  local directory="${MESH_COMPAT_MARKER%/*}" entry
  [ ! -e "$MESH_COMPAT_MARKER" ] && [ ! -L "$MESH_COMPAT_MARKER" ] ||
    fail 'Untracked installation files already exist; preserving them'
  if [ -e "$directory" ] || [ -L "$directory" ]; then
    [ -d "$directory" ] && [ ! -L "$directory" ] ||
      fail 'Untracked installation files already exist; preserving them'
    # Normal opkg removal can leave this empty directory. Reuse it without
    # deleting anything; visible/hidden entries and broken symlinks still block.
    for entry in "$directory"/* "$directory"/.[!.]* "$directory"/..?*; do
      [ ! -e "$entry" ] && [ ! -L "$entry" ] ||
        fail 'Untracked installation files already exist; preserving them'
    done
  fi
  return 0
}
usb_resource_ready() {
  # A CH341 userspace radio is exclusive. Never stop another owner or detach it.
  # Failure never changes the other owner's service or restarts this daemon.
  local p device bus dev matches=0 usbfs procdir pid fd link comm exe
  local allowed_pid='' current_version checked_pids=0 checked_fds=0
  command -v readlink >/dev/null 2>&1 || fail 'Cannot inspect Meshtoad USB ownership: readlink is unavailable'
  for p in /sys/bus/usb/devices/*/idVendor; do
    [ -f "$p" ] || continue
    [ "$(cat "$p")" = 1a86 ] && [ "$(cat "${p%/idVendor}/idProduct" 2>/dev/null)" = 5512 ] || continue
    matches=$((matches + 1))
    device="${p%/idVendor}"
  done
  [ "$matches" -gt 0 ] || fail 'Meshtoad USB radio 1a86:5512 is not present'
  [ "$matches" -eq 1 ] || fail 'Multiple Meshtoad USB radios are connected; select one explicitly before using this installer'
  bus="$(cat "$device/busnum" 2>/dev/null)" && dev="$(cat "$device/devnum" 2>/dev/null)" || fail 'Cannot read Meshtoad USB address'
  [[ "$bus" =~ ^[0-9]{1,3}$ && "$dev" =~ ^[0-9]{1,3}$ ]] || fail 'Invalid Meshtoad USB address'
  bus=$((10#$bus)); dev=$((10#$dev))
  [ "$bus" -ge 1 ] && [ "$bus" -le 255 ] && [ "$dev" -ge 1 ] && [ "$dev" -le 127 ] || fail 'Invalid Meshtoad USB address'
  usbfs="$(printf '/dev/bus/usb/%03d/%03d' "$bus" "$dev")"
  [ -c "$usbfs" ] && [ ! -L "$usbfs" ] || fail 'Meshtoad USB device node is missing or unexpected'

  # An already running, verified Meshtastic daemon may retain its own radio.
  current_version="$(status_field meshtasticd-full Version)"
  if is_installed meshtasticd-full && { [ "$current_version" = "$PACKAGE_VERSION" ] || [ "$current_version" = "$OLD_USB_VERSION" ]; } &&
      [ -x "$SERVICE" ] && "$SERVICE" status >/dev/null 2>&1; then
    p="$(pidof meshtasticd 2>/dev/null || true)"
    if [[ "$p" =~ ^[0-9]+$ ]] && kill -0 "$p" 2>/dev/null; then
      verify_file /usr/bin/meshtasticd "$BINARY_SHA256"
      allowed_pid="$p"
    fi
  fi

  [ -d /proc ] || fail 'Cannot inspect Meshtoad USB ownership: /proc is unavailable'
  for procdir in /proc/[0-9]*; do
    [ -d "$procdir" ] || continue
    checked_pids=$((checked_pids + 1))
    [ "$checked_pids" -le 512 ] || fail 'Cannot safely inspect Meshtoad USB ownership: process limit exceeded'
    if [ ! -d "$procdir/fd" ] || [ ! -r "$procdir/fd" ] || [ ! -x "$procdir/fd" ]; then
      [ ! -d "$procdir" ] && continue
      fail 'Cannot inspect a process file-descriptor directory; preserve USB ownership and retry'
    fi
    pid="${procdir##*/}"
    for fd in "$procdir/fd/"*; do
      [ -L "$fd" ] || continue
      checked_fds=$((checked_fds + 1))
      [ "$checked_fds" -le 8192 ] || fail 'Cannot safely inspect Meshtoad USB ownership: descriptor limit exceeded'
      if ! link="$(readlink "$fd" 2>/dev/null)"; then
        [ ! -L "$fd" ] && continue
        fail 'Cannot inspect a process USB descriptor; preserve USB ownership and retry'
      fi
      case "$link" in "$usbfs"|"${usbfs} (deleted)") ;; *) continue ;; esac
      if [ -n "$allowed_pid" ] && [ "$pid" = "$allowed_pid" ]; then
        exe="$(readlink "$procdir/exe" 2>/dev/null || true)"
        [ "$exe" = /usr/bin/meshtasticd ] && continue
      fi
      [ -d "$procdir" ] || continue
      comm=''
      IFS= read -r comm < "$procdir/comm" 2>/dev/null || true
      [[ "$comm" =~ ^[A-Za-z0-9_.+-]{1,32}$ ]] || comm='unknown-process'
      fail "Meshtoad USB device is open in $comm (PID $pid); release it in its owning app or service, then rerun Mesh"
    done
  done
  return 0
}
usb_profile() {
  awk '
    /^[^[:space:]#][^:]*:/ {lora=/^Lora:/; if(lora && /\{/)bad=1}
    lora && /^[[:space:]]+(Module|spidev|USB_VID|USB_PID):/ {
      line=$0; sub(/^[[:space:]]*/,"",line); key=line; sub(/:.*/,"",key); value=line; sub(/^[^:]+:[[:space:]]*/,"",value);
      sub(/[[:space:]]*#.*/,"",value); gsub(/[[:space:]"\047]/,"",value); value=tolower(value); count[key]++;
      if((key=="Module" && value!="sx1262") || (key=="spidev" && value!="ch341") || (key=="USB_VID" && value!="0x1a86") || (key=="USB_PID" && value!="0x5512"))bad=1
    }
    END {exit(bad || count["Module"]!=1 || count["spidev"]!=1 || count["USB_VID"]!=1 || count["USB_PID"]!=1)}' "$1"
}
validate_main_config() {
  [ -f "$CONFIG_DIR/config.yaml" ] && [ -r "$CONFIG_DIR/config.yaml" ] || fail 'meshtasticd main config missing or unreadable'
  configured_profiles="$(awk '
    /^[^[:space:]#][^:]*:/ {general=/^General:/}
    general && /^[[:space:]]+ConfigDirectory:/ {value=$0; sub(/^[[:space:]]+ConfigDirectory:[[:space:]]*/,"",value); sub(/[[:space:]]*#.*/,"",value); gsub(/["\047]/,"",value); sub(/[[:space:]]*$/,"",value);print value}' "$CONFIG_DIR/config.yaml")"
  [ "${configured_profiles%/}" = "$CONFIG_DIR/config.d" ] || fail 'Custom profile directory requires explicit reconciliation'
}
backup_settings() {
  backup="$(mktemp -d /root/mesh-settings-backup.XXXXXX)" || fail 'Cannot create Mesh backup'
  paths=()
  actual_data="$(readlink -f "$DATA_DIR" 2>/dev/null || true)"
  for p in /etc/config/meshtasticd "$BOOT_SETTINGS" /etc/config/mesh_start "$CONFIG_DIR" "$DATA_DIR" "$actual_data" "$PERSISTENT_DATA" /etc/init.d/meshtasticd /usr/bin/meshtasticd /usr/lib/opkg/status /etc/opkg/customfeeds.conf /etc/opkg/keys /root/payloads/user/general/Mesh /root/payloads/user/general/Meshtastic /usr/share/meshtastic-usb-spidev-compat /usr/lib/opkg/info/meshtasticd-full.* /usr/lib/opkg/info/meshtastic-usb-spidev-compat.*; do
    if [ -n "$p" ] && { [ -e "$p" ] || [ -L "$p" ]; }; then paths+=("${p#/}"); fi
  done
  if [ "${#paths[@]}" -gt 0 ]; then (umask 077; cd / && tar -czf "$backup/settings.tar.gz" "${paths[@]}") || fail 'Mesh backup failed'; fi
  if [ "$UNINSTALL" -eq 1 ]; then
    [ ! -d "$CONFIG_DIR" ] || cp -a "$CONFIG_DIR" "$backup/config-preserved" || fail 'Cannot preserve configuration for uninstall'
    [ ! -f /etc/config/meshtasticd ] || cp -p /etc/config/meshtasticd "$backup/uci-preserved" || fail 'Cannot preserve UCI configuration for uninstall'
  fi
  LOG "Meshtastic installation/settings backup: $backup"
}
persistent_root_ready() {
  [ "$(readlink -f /root 2>/dev/null)" = /mmc/root ] && [ -d /mmc/root ] && [ -w /mmc/root ] ||
    fail 'Persistent eMMC home is unavailable; preserving state'
  awk '
    $2=="/mmc" && $1=="/dev/mmcblk0p1" && $3=="ext4" && $4~/(^|,)rw(,|$)/ {ok=1}
    $2=="/mmc/root" || $2=="/mmc/root/.meshtasticd" || index($2,"/mmc/root/.meshtasticd/")==1 {bad=1}
    $2=="/tmp/lib/meshtasticd" || index($2,"/tmp/lib/meshtasticd/")==1 {bad=1}
    END {exit (!ok || bad)}' /proc/mounts || fail 'Meshtastic requires the writable eMMC mount without nested state mounts'
  [ ! -L "$PERSISTENT_DATA" ] && { [ ! -e "$PERSISTENT_DATA" ] || [ -d "$PERSISTENT_DATA" ]; } ||
    fail 'Persistent state path is a symlink or non-directory; preserving it'
}
state_tree_valid() {
  local directory=$1 entry
  [ ! -L "$directory" ] && [ -d "$directory" ] || fail 'State must be a regular directory; preserving it'
  for entry in "$directory"/* "$directory"/.[!.]* "$directory"/..?*; do
    [ ! -L "$entry" ] || fail 'State contains a symlink; reconcile it before migration or Start'
    [ -e "$entry" ] || continue
    if [ -d "$entry" ]; then state_tree_valid "$entry"
    elif [ ! -f "$entry" ]; then fail 'State contains a special file; preserving it'; fi
  done
}
state_tree_empty() {
  local entry
  for entry in "$1"/* "$1"/.[!.]* "$1"/..?*; do
    [ ! -e "$entry" ] && [ ! -L "$entry" ] || return 1
  done
  return 0
}
state_trees_equal() {
  local source=$1 target=$2 entry name
  for entry in "$source"/* "$source"/.[!.]* "$source"/..?*; do
    [ -e "$entry" ] || continue
    name=${entry##*/}
    if [ -d "$entry" ]; then
      [ -d "$target/$name" ] && state_trees_equal "$entry" "$target/$name" || return 1
    else [ -f "$target/$name" ] && cmp -s "$entry" "$target/$name" || return 1; fi
  done
  for entry in "$target"/* "$target"/.[!.]* "$target"/..?*; do
    [ -e "$entry" ] || continue
    [ -e "$source/${entry##*/}" ] || return 1
  done
}
require_persistent_data() {
  persistent_root_ready
  [ "$DATA_DIR" = "$PERSISTENT_DATA" ] &&
    [ "$(uci -q get meshtasticd.meshtasticd.data_dir 2>/dev/null)" = "$PERSISTENT_DATA" ] ||
    fail 'Persistent storage setup is required; choose Stop, then Install / Update before Start'
  state_tree_valid "$PERSISTENT_DATA"
  [ "$(readlink -f "$PERSISTENT_DATA")" = /mmc/root/.meshtasticd ] || fail 'State is not on the expected eMMC path'
}
validate_data_migration() {
  local source=$DATA_DIR pending
  persistent_root_ready
  case "$source" in "$LEGACY_DATA"|"$PERSISTENT_DATA") ;;
    *) fail 'Custom data_dir requires explicit migration; preserving all state' ;;
  esac
  pending="$(uci changes 2>/dev/null)" || fail 'Cannot inspect pending configuration edits'
  if printf '%s\n' "$pending" | grep -Eq '^[-+]?meshtasticd([.=]|$)'; then
    fail 'Pending Meshtastic configuration edits must be resolved before migration'
  fi
  [ ! -e "$PERSISTENT_DATA/config.yaml" ] && [ ! -L "$PERSISTENT_DATA/config.yaml" ] ||
    fail 'Persistent state contains a local config.yaml override; preserve it for explicit reconciliation'
  if [ -e "$source" ] || [ -L "$source" ]; then state_tree_valid "$source"; fi
  if [ "$source" = "$LEGACY_DATA" ] && [ -d "$source" ]; then
    [ "$(readlink -f "$source")" = /tmp/lib/meshtasticd ] || fail 'Legacy data_dir resolves unexpectedly; preserve it for explicit migration'
  fi
  if [ -d "$PERSISTENT_DATA" ]; then state_tree_valid "$PERSISTENT_DATA"; fi
  if [ "$source" = "$PERSISTENT_DATA" ] && [ ! -d "$PERSISTENT_DATA" ] &&
      { [ -e "$LEGACY_DATA" ] || [ -L "$LEGACY_DATA" ]; }; then
    state_tree_valid "$LEGACY_DATA"
    state_tree_empty "$LEGACY_DATA" || fail 'Selected persistent state is missing but legacy state remains; preserve it for explicit recovery'
  fi
  if [ "$source" = "$LEGACY_DATA" ] && [ -d "$source" ] && ! state_tree_empty "$source" &&
      [ -d "$PERSISTENT_DATA" ] && ! state_tree_empty "$PERSISTENT_DATA"; then
    state_trees_equal "$source" "$PERSISTENT_DATA" || fail 'Legacy and persistent state differ; preserving both for explicit reconciliation'
  fi
}
prepare_persistent_data() {
  local source=$DATA_DIR entry
  assert_stopped
  validate_data_migration
  if [ "$source" = "$PERSISTENT_DATA" ] && [ -d "$PERSISTENT_DATA" ] &&
      [ "$(uci -q get meshtasticd.meshtasticd.data_dir 2>/dev/null)" = "$PERSISTENT_DATA" ]; then
    require_persistent_data
    return 0
  fi
  [ -n "$backup" ] || backup_settings
  if [ ! -d "$PERSISTENT_DATA" ] || state_tree_empty "$PERSISTENT_DATA"; then
    state_stage="$(umask 077; mktemp -d "$PERSISTENT_DATA.migrate.XXXXXX")" || fail 'Cannot stage persistent state'
    if [ "$source" != "$PERSISTENT_DATA" ] && [ -d "$source" ]; then
      for entry in "$source"/* "$source"/.[!.]* "$source"/..?*; do
        [ ! -e "$entry" ] && [ ! -L "$entry" ] || cp -a "$entry" "$state_stage/" || fail 'State copy failed; original state and backup retained'
      done
      state_tree_valid "$state_stage"
      state_trees_equal "$source" "$state_stage" || fail 'State copy verification failed; original state retained'
    fi
    [ ! -d "$PERSISTENT_DATA" ] || rmdir "$PERSISTENT_DATA" || fail 'Persistent destination changed; preserving it'
    [ ! -e "$PERSISTENT_DATA" ] && [ ! -L "$PERSISTENT_DATA" ] || fail 'Persistent destination appeared; preserving it'
    mv -T "$state_stage" "$PERSISTENT_DATA" || fail 'Cannot place persistent state; original state retained'
    state_tree_valid "$PERSISTENT_DATA"
    if [ "$source" != "$PERSISTENT_DATA" ] && [ -d "$source" ]; then
      state_trees_equal "$source" "$PERSISTENT_DATA" || fail 'Placed state verification failed; original state and backup retained'
    else state_tree_empty "$PERSISTENT_DATA" || fail 'Persistent destination changed; preserve it for reconciliation'; fi
    state_stage=''
  fi
  chmod 700 "$PERSISTENT_DATA" || fail 'Cannot protect persistent state'
  state_tree_valid "$PERSISTENT_DATA"
  sync || fail 'Cannot flush persistent state'
  uci set meshtasticd.meshtasticd.data_dir="$PERSISTENT_DATA" || fail 'Cannot stage persistent data_dir; state and backup retained'
  if ! uci commit meshtasticd; then
    uci revert meshtasticd.meshtasticd.data_dir >/dev/null 2>&1 || LOG 'Pending data_dir could not be reverted; inspect UCI before retrying'
    fail 'Cannot save persistent data_dir; original state, persistent copy and backup retained'
  fi
  DATA_DIR=$PERSISTENT_DATA
  require_persistent_data
}
api_ready() {
  netstat -lntp 2>/dev/null | awk -v pid="$1" '$1~/^tcp/ && $4~/:4403$/ && $6=="LISTEN" && $7==pid "/meshtasticd" {ok=1} END {exit !ok}'
}
radio_ready() {
  logread -e meshtasticd 2>/dev/null | awk -v pid="$1" 'index($0,"meshtasticd[" pid "]") && /sx1262 init success/ {ok=1} END {exit !ok}'
}

boot_choice_on() {
  [ -f "$BOOT_SETTINGS" ] && [ ! -L "$BOOT_SETTINGS" ] &&
    [ "$(uci -q get meshtastic_payload.settings.boot_start_enabled 2>/dev/null)" = 1 ] &&
    [ "$(uci -q get meshtastic_payload.settings.boot_start_choice 2>/dev/null)" = user-boot-v1 ]
}
boot_link_present() {
  [ -L "$BOOT_LINK" ] && [ "$(readlink "$BOOT_LINK" 2>/dev/null)" = ../init.d/meshtasticd ]
}
boot_enabled() {
  boot_choice_on && boot_link_present && [ -f "$SERVICE" ] && [ ! -L "$SERVICE" ] &&
    [ "$(sha256sum "$SERVICE" 2>/dev/null | awk '{print $1}')" = "$GUARDED_INIT_SHA256" ]
}
save_boot_choice() {
  local allowed=$1 tmp
  [ ! -L "$BOOT_SETTINGS" ] && { [ ! -e "$BOOT_SETTINGS" ] || [ -f "$BOOT_SETTINGS" ]; } || fail 'Boot settings must be a regular file'
  tmp="$(umask 077; mktemp "$BOOT_SETTINGS.XXXXXX")" || fail 'Cannot stage boot settings'
  printf "config settings 'settings'\n\toption boot_start_enabled '%s'\n\toption boot_start_choice 'user-boot-v1'\n" "$allowed" > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$BOOT_SETTINGS" || { rm -f "$tmp"; fail 'Cannot save boot choice'; }
}
mesh_menu() {
  local choice setting response current_init
  command -v LIST_PICKER >/dev/null 2>&1 || fail 'Pager menu unavailable; use an explicit command-line action'
  while :; do
  setting='OFF'
  current_init=''
  if [ -e "$SERVICE" ] || [ -L "$SERVICE" ]; then
    if [ -f "$SERVICE" ] && [ ! -L "$SERVICE" ]; then
      current_init="$(sha256sum "$SERVICE" 2>/dev/null | awk '{print $1}')"
    fi
    [ "$current_init" = "$GUARDED_INIT_SHA256" ] || setting='Setup required'
  fi
  boot_enabled && setting='ON'
  choice="$(LIST_PICKER 'Meshtastic' 'Start server' 'Stop server' 'Install / Update' "Enable at Boot: $setting" 'Uninstall' 'Exit' 'Exit')" || exit 0
  case "$choice" in
    'Start server')
      case "$current_init" in
        "$PUBLIC_INIT_SHA256"|"$OLD_MANUAL_INIT_SHA256"|"$PREVIOUS_GUARDED_INIT_SHA256")
          # Copying the launcher alone does not apply its startup policy.
          # Keep menu access available without starting or installing anything.
          LOG 'Startup setup is required; choose Stop server, then Install / Update before Start.'
          command -v PROMPT >/dev/null 2>&1 || fail 'Pager setup prompt unavailable'
          PROMPT 'Startup setup is required. Choose Stop server, then Install / Update before Start.' || exit 0
          continue ;;
      esac
      ACTION='start' ;;
    'Stop server') ACTION='stop' ;;
    'Install / Update') ACTION='install' ;;
    "Enable at Boot: $setting")
      choice="$(LIST_PICKER "Enable at Boot: $setting" 'ON - start at boot' 'OFF - manual start only' 'Back' 'Back')" || exit 0
      case "$choice" in
        'ON - start at boot') ACTION='boot-on' ;;
        'OFF - manual start only') ACTION='boot-off' ;;
        'Back') exit 0 ;;
        *) fail 'Unexpected boot menu result' ;;
      esac ;;
    'Uninstall')
      command -v CONFIRMATION_DIALOG >/dev/null 2>&1 || fail 'Uninstall confirmation is unavailable'
      response="$(CONFIRMATION_DIALOG 'Uninstall Meshtastic? Settings and messages stay.')" || exit 0
      # Firmware supplies its positive-response constant; 1 is documented.
      [ "$response" != 0 ] && [ -n "$response" ] || exit 0
      if [ "$response" != 1 ] && [ "$response" != "${DUCKYSCRIPT_USER_CONFIRMED:-CONFIRMED}" ]; then exit 0; fi
      ACTION='uninstall'; UNINSTALL=1 ;;
    'Exit') exit 0 ;;
    *) fail 'Unexpected Meshtastic menu result' ;;
  esac
  return 0
  done
}
assert_stopped() {
  local rc=0
  [ -z "$(pidof meshtasticd 2>/dev/null || true)" ] || fail 'Meshtastic is running; choose Stop before Install / Update'
  if [ -x "$SERVICE" ]; then
    require_known_init
    "$SERVICE" status >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 3 ] || fail 'Meshtastic service is registered or its state is unknown; choose Stop before Install / Update'
  fi
  service_definition_absent || fail 'Meshtastic service is registered or its state is unknown; choose Stop before Install / Update'
}
service_definition_absent() {
  # rc5 means a registered instance in respawn delay, not an inactive service.
  # Confirm rc3 independently: rc.common also emits it after a failed ubus read.
  local definition
  definition="$(ubus -S call service list '{"name":"meshtasticd"}' 2>/dev/null)" || return 1
  # The Pager's BusyBox tr lacks character classes; delete these bytes explicitly.
  [ "$(printf '%s' "$definition" | tr -d ' \t\r\n')" = '{}' ]
}
assert_no_partial_packages() {
  local pending
  refresh_status || fail 'Cannot inspect pending package configuration'
  pending="$(printf '%s\n' "$STATUS" | awk 'BEGIN {RS="";FS="\n"} {p="";s="";for(i=1;i<=NF;i++){if($i~/^Package: /)p=substr($i,10);if($i~/^Status: /)s=substr($i,9)} if(s!="" && (s!~/ (installed|not-installed)$/ || s~/(^|[ ,])reinstreq([, ]|$)/))print p}')"
  [ -z "$pending" ] || fail "Pending package state requires separate reconciliation before installation: $(printf '%s\n' "$pending" | awk -v package="$MESH_COMPAT_PACKAGE" '$0==package {$0="Meshtastic installation"} {print}')"
}

# Derived from the pinned public init script, retaining its licensing and procd
# configuration. Boot requires a proven explicit choice; manual Start grants
# a session only. Reload and install hooks never request a session.
guarded_init() {
  cat <<'MESH_GUARDED_INIT'
#!/bin/sh /etc/rc.common
#
# SPDX-License-Identifier: GPL-2.0-only

# shellcheck shell=busybox

START=99
STOP=10

USE_PROCD=1
PROG=/usr/bin/meshtasticd

# Meshtastic session start is independent of the default-OFF boot setting.
meshtastic_boot_choice_on() {
	[ -f /etc/config/meshtastic_payload ] && [ ! -L /etc/config/meshtastic_payload ] || return 1
	[ "$(uci -q get meshtastic_payload.settings.boot_start_enabled)" = 1 ] || return 1
	[ "$(uci -q get meshtastic_payload.settings.boot_start_choice)" = user-boot-v1 ] || return 1
}
boot() {
	meshtastic_boot_choice_on || return 0
	[ -f /root/payloads/user/general/Meshtastic/payload.sh ] &&
		[ ! -L /root/payloads/user/general/Meshtastic/payload.sh ] &&
		[ -x /root/payloads/user/general/Meshtastic/payload.sh ] || {
		logger -t meshtastic-payload 'Boot startup failed: canonical Meshtastic payload is missing or unexpected'
		return 1
	}
	# Reuse the single payload's complete USB, package, configuration and health
	# checks. It rechecks the boot choice/link before granting a session token.
	/bin/bash /root/payloads/user/general/Meshtastic/payload.sh --boot-start
}
enable() {
	[ "${MESHTASTIC_BOOT_CHOICE_CHANGE:-0}" = 1 ] && meshtastic_boot_choice_on || return 1
	if [ -e /etc/rc.d/S99meshtasticd ] || [ -L /etc/rc.d/S99meshtasticd ]; then
		[ -L /etc/rc.d/S99meshtasticd ] && [ "$(readlink /etc/rc.d/S99meshtasticd)" = ../init.d/meshtasticd ] || return 1
	fi
	ln -sf ../init.d/meshtasticd /etc/rc.d/S99meshtasticd
}
enabled() {
	meshtastic_boot_choice_on && [ -L /etc/rc.d/S99meshtasticd ] &&
		[ "$(readlink /etc/rc.d/S99meshtasticd)" = ../init.d/meshtasticd ]
}
reload_service() { return 0; }

restart() {
	[ "${MESHTASTIC_SESSION_START:-0}" = 1 ] || return 1
	stop "$@"
	start "$@"
}

start_service() {
	# rc.common ignores the callback return before committing a procd update.
	# Exit the init process so a rejected start cannot replace a live instance.
	[ "${MESHTASTIC_SESSION_START:-0}" = 1 ] || exit 1
	config_load 'meshtasticd' || exit 1

	local config_dir data_dir

	uci_validate_section 'meshtasticd' 'meshtasticd' 'meshtasticd' \
		'config_dir:string:/etc/meshtasticd' \
		'data_dir:string:/root/.meshtasticd' || exit 1

	# Never fall back to volatile state or register an instance after rejection.
	[ "$data_dir" = /root/.meshtasticd ] && [ "$(readlink -f /root)" = /mmc/root ] &&
		[ ! -L "$data_dir" ] && [ -d "$data_dir" ] && [ -w "$data_dir" ] || exit 1
	[ "$config_dir" = /etc/meshtasticd ] &&
		[ ! -e "$data_dir/config.yaml" ] && [ ! -L "$data_dir/config.yaml" ] || exit 1
	awk '
		$2=="/mmc" && $1=="/dev/mmcblk0p1" && $3=="ext4" && $4~/(^|,)rw(,|$)/ {ok=1}
		$2=="/mmc/root" || $2=="/mmc/root/.meshtasticd" || index($2,"/mmc/root/.meshtasticd/")==1 {bad=1}
		END {exit (!ok || bad)}' /proc/mounts || exit 1
	local unsafe
	unsafe="$(find "$data_dir" ! -type f ! -type d -print)" || exit 1
	[ -z "$unsafe" ] || exit 1

	local config_file="${config_dir}/config.yaml"
	local config_d_dir="${config_dir}/config.d/*"

	# meshtasticd needs to be run from its data directory
	cd "$data_dir" || exit 1

	procd_open_instance
	procd_set_param command "$PROG"
	procd_append_param command --fsdir="$data_dir"
	procd_set_param file "$config_file"
	procd_set_param file "$config_d_dir"
	procd_set_param term_timeout 15
	procd_set_param respawn
	procd_set_param stdout 1
	procd_set_param stderr 1
	procd_close_instance
}

service_triggers() {
	procd_add_reload_trigger 'meshtasticd'
}
MESH_GUARDED_INIT
}
verify_init_policy() {
  [ -x "$SERVICE" ] && [ ! -L "$SERVICE" ] || fail 'Meshtastic init script is missing or unexpected'
  [ "$(sha256sum "$SERVICE" 2>/dev/null | awk '{print $1}')" = "$GUARDED_INIT_SHA256" ] ||
    fail 'Startup policy in /etc/init.d/meshtasticd needs Install / Update or explicit reconciliation; no server was started'
}
verify_owned_boot_links() {
  local p
  for p in /etc/rc.d/S??meshtasticd /etc/rc.d/K??meshtasticd; do
    [ -e "$p" ] || [ -L "$p" ] || continue
    [ -L "$p" ] && [ "$(readlink "$p" 2>/dev/null)" = ../init.d/meshtasticd ] || fail 'Unexpected Meshtastic boot entry requires reconciliation; preserving it'
  done
}
change_boot_choice() {
  if [ "$ACTION" = boot-on ]; then
    verify_init_policy
    [ -f "$CANONICAL_PAYLOAD" ] && [ ! -L "$CANONICAL_PAYLOAD" ] && [ -x "$CANONICAL_PAYLOAD" ] || fail 'Install the payload in the Meshtastic directory before enabling boot'
    verify_owned_boot_links
    save_boot_choice 1
    if ! MESHTASTIC_BOOT_CHOICE_CHANGE=1 "$SERVICE" enable || ! boot_enabled; then
      save_boot_choice 0
      fail 'Boot enable failed; boot choice remains OFF. No server was started.'
    fi
    LOG 'Enable at Boot: ON. The current server session is unchanged.'
  else
    save_boot_choice 0
    if [ -e "$SERVICE" ] || [ -L "$SERVICE" ]; then
      require_known_init
      verify_owned_boot_links
      "$SERVICE" disable || fail 'Boot choice is OFF but boot-link removal failed; reconcile the existing boot policy'
    fi
    # Absence of init means its retained links cannot launch Meshtastic.
    if [ -e "$SERVICE" ]; then
      for p in /etc/rc.d/S??meshtasticd; do
        [ ! -e "$p" ] && [ ! -L "$p" ] || fail 'A Meshtastic boot entry remains; boot OFF could not be verified'
      done
    fi
    LOG 'Enable at Boot: OFF. Manual Start still works; the current session is unchanged.'
  fi
}
require_known_init() {
  local current
  [ -f "$SERVICE" ] && [ ! -L "$SERVICE" ] && [ -x "$SERVICE" ] || fail 'Meshtastic init script is missing or unexpected; preserving it'
  current="$(sha256sum "$SERVICE" | awk '{print $1}')"
  case "$current" in
    "$PUBLIC_INIT_SHA256"|"$OLD_MANUAL_INIT_SHA256"|"$PREVIOUS_GUARDED_INIT_SHA256"|"$GUARDED_INIT_SHA256") ;;
    *) fail 'Custom Meshtastic init script requires explicit reconciliation; preserving it' ;;
  esac
}
install_init_policy() {
  local current tmp
  [ -f "$SERVICE" ] && [ ! -L "$SERVICE" ] || fail 'Meshtastic init script is missing or unexpected'
  current="$(sha256sum "$SERVICE" | awk '{print $1}')"
  [ "$current" != "$GUARDED_INIT_SHA256" ] || return 0
  [ "$current" = "$PUBLIC_INIT_SHA256" ] || [ "$current" = "$OLD_MANUAL_INIT_SHA256" ] || [ "$current" = "$PREVIOUS_GUARDED_INIT_SHA256" ] || fail 'Custom Meshtastic init script requires explicit reconciliation; preserving it'
  tmp="$(umask 077; mktemp "$SERVICE.mesh.XXXXXX")" || fail 'Cannot stage manual-start init policy'
  guarded_init > "$tmp" && chmod 755 "$tmp" || { rm -f "$tmp"; fail 'Cannot stage manual-start init policy'; }
  verify_file "$tmp" "$GUARDED_INIT_SHA256"
  mv "$tmp" "$SERVICE" || { rm -f "$tmp"; fail 'Cannot install manual-start init policy'; }
}
start_server() {
  is_installed meshtasticd-full && [ "$(status_field meshtasticd-full Version)" = "$PACKAGE_VERSION" ] || fail 'Install / Update the supported public package before Start'
  verify_file /usr/bin/meshtasticd "$BINARY_SHA256"
  verify_init_policy
  require_persistent_data
  validate_main_config
  [ -f "$DST" ] && usb_profile "$DST" || fail 'Install / Update the supported USB radio profile before Start'
  for p in "$CONFIG_DIR/config.d/"*.yaml; do
    if [ "$p" != "$DST" ] && [ -f "$p" ] && radio_selected "$p"; then fail 'Another radio profile is selected; reconcile it before Start'; fi
  done
  radio_selected "$CONFIG_DIR/config.yaml" && fail 'Main config selects another radio; reconcile it before Start'
  usb_resource_ready
  local launched=0
  if ! "$SERVICE" status >/dev/null 2>&1; then
    MESHTASTIC_SESSION_START=1 "$SERVICE" start || fail 'Service start failed'
    launched=1
  fi
  local stable=0 previous_pid='' pid attempt
  for ((attempt=0; attempt<30; attempt++)); do
    pid="$(pidof meshtasticd 2>/dev/null || true)"
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null && "$SERVICE" status >/dev/null 2>&1 && api_ready "$pid" && { [ "$launched" -eq 0 ] || radio_ready "$pid"; }; then
      if [ "$pid" = "$previous_pid" ]; then stable=$((stable+1)); else stable=1; fi
      previous_pid="$pid"
      if [ "$stable" -ge 5 ]; then
        if [ "$launched" -eq 1 ]; then LOG "Public meshtasticd $PACKAGE_VERSION running (PID=$pid; stable radio/API startup verified)";
        else LOG "Public meshtasticd $PACKAGE_VERSION already running (PID=$pid; stable API verified)"; fi
        return 0
      fi
    else stable=0; previous_pid=''; fi
    sleep 2
  done
  fail 'Meshtastic did not reach stable daemon/radio/API startup; inspect logread -e meshtasticd'
}

[ "$(cat /tmp/sysinfo/board_name 2>/dev/null)" = hak5,wifi-pineapple-pager ] || fail 'This USB installer targets the WiFi Pineapple Pager'
[ "$ACTION" != menu ] || mesh_menu
lock_action
case "$ACTION" in
  boot-on|boot-off) change_boot_choice; exit 0 ;;
  stop)
    if [ -e "$SERVICE" ] || [ -L "$SERVICE" ]; then require_known_init; fi
    if [ -e "$SERVICE" ]; then stop_service; else [ -z "$(pidof meshtasticd 2>/dev/null || true)" ] && service_definition_absent || fail 'Meshtastic process or service state cannot be cleared without its init script; reconcile it explicitly'; fi
    LOG 'Meshtastic stopped'
    exit 0 ;;
  status)
    if boot_enabled; then LOG 'Enable at Boot: ON'; else LOG 'Enable at Boot is OFF or needs Install / Update; manual Start is independent'; fi
    if [ -e "$SERVICE" ] || [ -L "$SERVICE" ]; then
      require_known_init
      if "$SERVICE" status >/dev/null 2>&1; then LOG 'Meshtastic service is running'; else LOG 'Meshtastic service is not running; a retained definition may require Stop'; fi
    elif service_definition_absent; then LOG 'Meshtastic service is inactive'; else fail 'Meshtastic service state is unknown or registered without its init script'; fi
    exit 0 ;;
esac
opkg print-architecture | grep -q 'mipsel_24kc' || fail 'Unsupported architecture; mipsel_24kc is required'
[ "$(awk -F= '$1=="DISTRIB_RELEASE" {gsub(/["\047]/,"",$2);print $2}' /etc/openwrt_release)" = 24.10.1 ] || fail 'Unsupported OpenWrt base; this installer is verified for 24.10.1'
extra_roots="$(awk '$1=="dest" && $3!="/" {print $3}' /etc/opkg.conf /etc/opkg/*.conf 2>/dev/null)" || fail 'Cannot inspect opkg destinations'
for p in $extra_roots; do
  [[ "$p" = /* ]] || fail 'Unsupported opkg destination path'
  [ ! -s "${p%/}/usr/lib/opkg/status" ] || fail 'Additional package destination is in use; reconcile it before installing Meshtastic'
done
refresh_status || fail 'Cannot read package status'
is_installed kernel && [ "$(status_field kernel Version)" = "$KERNEL_VERSION" ] || fail 'Unsupported Pager kernel build; review this installer for the new firmware'
full_version="$(status_field meshtasticd-full Version)"
is_registered meshtasticd-full || full_version=''
if is_registered meshtasticd; then fail 'Legacy meshtasticd package requires separate reconciliation'; fi
if is_registered meshtasticd-full && ! is_installed meshtasticd-full; then fail 'Meshtastic package is partially installed; reconcile it before retrying'; fi
case "$full_version" in ''|"$PACKAGE_VERSION"|"$OLD_USB_VERSION") ;; *) fail 'Unsupported Meshtastic version; this installer only accepts the pinned public version or the previous known USB variant';; esac
need_install=0
[ "$full_version" = "$PACKAGE_VERSION" ] || need_install=1
CONFIG_DIR="$(uci -q get meshtasticd.meshtasticd.config_dir 2>/dev/null || true)"
DATA_DIR="$(uci -q get meshtasticd.meshtasticd.data_dir 2>/dev/null || true)"
CONFIG_DIR="${CONFIG_DIR:-/etc/meshtasticd}"
DATA_DIR="${DATA_DIR:-$LEGACY_DATA}"
[ "$CONFIG_DIR" = /etc/meshtasticd ] || fail 'Custom config_dir requires explicit service configuration; preserving it'
[ ! -L "$CONFIG_DIR" ] || fail 'Symlinked config directory requires explicit reconciliation; preserving it'
[[ "$DATA_DIR" = /* && "$DATA_DIR" != / && "$DATA_DIR" != *$'\n'* ]] || fail 'Unsupported data directory'
[ ! -e "$DATA_DIR/config.yaml" ] && [ ! -L "$DATA_DIR/config.yaml" ] || fail 'Local config.yaml override requires explicit reconciliation'
DST="$CONFIG_DIR/config.d/lora-usb-meshtoad-e22.yaml"
[ ! -L "$DST" ] || [ -f "$DST" ] || fail 'Existing broken profile symlink requires reconciliation'
[ ! -e "$DST" ] || [ -f "$DST" ] || fail 'Existing profile is not a regular file'
if [ -n "$full_version" ] || [ -e "$CONFIG_DIR/config.yaml" ] || [ -L "$CONFIG_DIR/config.yaml" ]; then validate_main_config; fi

if [ "$ACTION" = boot-start ]; then
  boot_enabled || fail 'Boot startup refused: Enable at Boot is OFF or its verified boot entry is missing'
  start_server
  exit 0
fi
if [ "$ACTION" = start ]; then start_server; exit 0; fi
if [ "$UNINSTALL" -eq 0 ]; then
  assert_stopped
  assert_no_partial_packages
fi
policy_needed=1
if [ -e "$SERVICE" ] || [ -L "$SERVICE" ]; then
  [ -f "$SERVICE" ] && [ ! -L "$SERVICE" ] || fail 'Meshtastic init script is unexpected; preserving it'
  init_sha="$(sha256sum "$SERVICE" | awk '{print $1}')"
  case "$init_sha" in
    "$GUARDED_INIT_SHA256") policy_needed=0 ;;
    "$PUBLIC_INIT_SHA256"|"$OLD_MANUAL_INIT_SHA256"|"$PREVIOUS_GUARDED_INIT_SHA256") ;;
    *) fail 'Custom Meshtastic init script requires explicit reconciliation; preserving it' ;;
  esac
fi

providers="$(printf '%s\n' "$STATUS" | awk 'BEGIN {RS="";FS="\n"} {p="";s="";v="";for(i=1;i<=NF;i++){if($i~/^Package: /)p=substr($i,10);if($i~/^Status: /)s=substr($i,9);if($i~/^Provides: /)v=substr($i,11)} if(s!="" && s!~/ not-installed$/ && v~/(^|[, ])kmod-spi-dev([, ]|$)/)print p}')"
for p in $providers; do
  [ "$p" = "$MESH_COMPAT_PACKAGE" ] || [ "$p" = kmod-spi-dev ] || fail "Existing SPI provider $p requires reconciliation; preserving it"
done
shim_present=0
if is_registered "$MESH_COMPAT_PACKAGE"; then verify_shim; shim_present=1; fi
real_spi=0
if is_registered kmod-spi-dev; then
  is_installed kmod-spi-dev || fail 'Real SPI package is partially installed; preserving it'
  [ "$(status_field kmod-spi-dev Depends)" = "kernel (= $KERNEL_VERSION)" ] || [ "$(status_field kmod-spi-dev Depends)" = "kernel (=$KERNEL_VERSION)" ] || fail 'Real SPI package has an unsupported kernel dependency'
  spi_support_present || fail 'Real SPI package is registered but no driver evidence was found; reconcile genuine support'
  real_spi=1
elif spi_support_present; then
  fail 'Existing spidev support has no matching package metadata; preserve it and obtain genuine vendor packaging'
fi
if [ "$real_spi" -eq 0 ] && [ "$shim_present" -eq 0 ]; then
  assert_compatibility_target_available
  [ -z "$(consumers 'kmod-spi-dev' meshtasticd-full)" ] || fail 'Other installed packages require SPI support; installation cannot continue safely'
  need_shim=1
fi

if [ "$UNINSTALL" -eq 1 ]; then
  [ -z "$(consumers 'meshtasticd|meshtasticd-full' meshtasticd-full)" ] || fail 'Other packages depend on Meshtastic; remove those explicitly before uninstalling'
  if [ "$shim_present" -eq 1 ]; then [ -z "$(consumers 'kmod-spi-dev' meshtasticd-full)" ] || fail 'Other packages still need these installation files; preserving them'; fi
  if [ -n "$full_version" ]; then
    backup_settings
    require_known_init
    verify_owned_boot_links
    stop_service
    opkg remove meshtasticd-full || fail 'Normal Meshtastic package removal failed; backup retained'
    if [ -d "$backup/config-preserved" ]; then
      mkdir -p "$CONFIG_DIR" && cp -a "$backup/config-preserved/." "$CONFIG_DIR/" || fail 'Cannot restore owner configuration after removal; backup retained'
    fi
    [ ! -f "$backup/uci-preserved" ] || cp -p "$backup/uci-preserved" /etc/config/meshtasticd || fail 'Cannot restore owner UCI after removal; backup retained'
    refresh_status || fail 'Cannot verify removal'
    is_registered meshtasticd-full && fail 'Meshtastic package remains registered after removal'
  fi
  if [ "$shim_present" -eq 1 ]; then
    [ -n "$backup" ] || backup_settings
    opkg remove "$MESH_COMPAT_PACKAGE" >> "$backup/package.log" 2>&1 || fail "Meshtastic removal failed; backup retained. Details: $backup/package.log"
    refresh_status || fail 'Cannot verify complete Meshtastic removal'
    is_registered "$MESH_COMPAT_PACKAGE" && fail 'Meshtastic removal is incomplete; an installation package remains registered'
  fi
  LOG 'Meshtastic uninstalled; settings, messages and backups retained'
  exit 0
fi

usb_resource_ready
validate_data_migration
for p in "$CONFIG_DIR/config.d/"*.yaml; do
  if [ "$p" != "$DST" ] && [ -f "$p" ] && radio_selected "$p"; then fail 'Another radio profile is selected; preserve it and reconcile explicitly'; fi
done
if [ -f "$CONFIG_DIR/config.yaml" ] && radio_selected "$CONFIG_DIR/config.yaml"; then fail 'Main config selects another radio; preserve it and reconcile explicitly'; fi
if [ -f "$DST" ]; then usb_profile "$DST" || fail 'Existing profile is not the supported CH341 Meshtoad configuration';
else write_profile; SRC="$PROFILE"; profile_needed=1; fi
missing_deps=()
for p in "${REAL_DEPS[@]}"; do is_installed "$p" || missing_deps+=("$p"); done
if [ "$need_install" -eq 1 ]; then prepare_package; fi
if [ "$need_install" -eq 1 ] || [ "$profile_needed" -eq 1 ] || [ "$need_shim" -eq 1 ] || [ "${#missing_deps[@]}" -gt 0 ] || [ "$policy_needed" -eq 1 ]; then
  backup_settings
fi
assert_stopped
[ ! -f "$SERVICE" ] || install_init_policy
if [ "$need_install" -eq 1 ] || [ "${#missing_deps[@]}" -gt 0 ]; then
  write_key
  opkg-key add "$KEY" || fail 'Package signing key add failed'
  feeds=/etc/opkg/customfeeds.conf
  [ -f "$feeds" ] && [ ! -L "$feeds" ] || fail 'customfeeds.conf must be an existing regular file'
  tmp="$(mktemp "$feeds.mesh.XXXXXX")" || fail 'Cannot prepare feed update'
  cp -p "$feeds" "$tmp" || { rm -f "$tmp"; fail 'Cannot preserve feed metadata'; }
  awk -v feed="$FEED" '$1=="src/gz" && $2=="meshtastic" {next} {print} END {print "src/gz meshtastic " feed}' "$feeds" > "$tmp" || { rm -f "$tmp"; fail 'Feed update failed'; }
  mv "$tmp" "$feeds" || { rm -f "$tmp"; fail 'Cannot save feed update'; }
  opkg_update
  if [ "${#missing_deps[@]}" -gt 0 ]; then
    assert_stopped
    assert_no_partial_packages
    opkg install "${missing_deps[@]}" || fail 'Real userspace dependency installation failed'
  fi
  refresh_status || fail 'Cannot verify dependency state'
  for p in "${REAL_DEPS[@]}"; do is_installed "$p" || fail "Required userspace package $p is not fully installed"; done
fi
if [ "$need_shim" -eq 1 ]; then
  refresh_status || fail 'Cannot recheck provider state'
  ! is_registered "$MESH_COMPAT_PACKAGE" && ! is_registered kmod-spi-dev && ! spi_support_present || fail 'SPI provider state changed during setup; preserve it and retry'
  prepare_work
  SHIM_IPK="$WORK/${MESH_COMPAT_PACKAGE}_${MESH_COMPAT_VERSION}_all.ipk"
  # Preserve raw package diagnostics privately instead of displaying internals.
  mesh_compat_build_ipk "$SHIM_IPK" >> "$backup/package.log" 2>&1 || fail "Cannot prepare Meshtastic installation. Details: $backup/package.log"
  LOG 'Preparing Meshtastic installation'
  assert_stopped
  assert_no_partial_packages
  assert_compatibility_target_available
  shim_added=1
  opkg install "$SHIM_IPK" >> "$backup/package.log" 2>&1 || fail "Meshtastic installation failed. Details: $backup/package.log"
  refresh_status || fail 'Cannot verify complete Meshtastic installation'
  verify_shim
fi
if [ "$profile_needed" -eq 1 ]; then
  mkdir -p "$CONFIG_DIR/config.d" || fail 'Cannot create radio config directory'
  profile_tmp="$(mktemp "$CONFIG_DIR/config.d/.meshtoad.XXXXXX")" || fail 'Cannot stage radio config'
  cp -p "$SRC" "$profile_tmp" && cmp -s "$SRC" "$profile_tmp" || { rm -f "$profile_tmp"; fail 'Config copy verification failed'; }
  [ ! -e "$DST" ] && [ ! -L "$DST" ] || { rm -f "$profile_tmp"; fail 'Profile appeared during setup; preserving it'; }
  mv "$profile_tmp" "$DST" || { rm -f "$profile_tmp"; fail 'Cannot save radio config'; }
  profile_added=1
  created_profile_sha="$(sha256sum "$DST" | awk '{print $1}')"
fi
if [ "$need_install" -eq 1 ]; then
  usb_resource_ready
  refresh_status || fail 'Cannot recheck installed daemon version'
  current_version="$(status_field meshtasticd-full Version)"
  is_registered meshtasticd-full || current_version=''
  [ "$current_version" = "$full_version" ] || fail 'Daemon version changed during setup; refusing an unintended conversion'
  assert_stopped
  assert_no_partial_packages
  LOG 'Installing the unmodified pinned public Meshtastic package; its automatic post-install start/enable is suppressed'
  if [ "$full_version" = "$OLD_USB_VERSION" ]; then
    IPKG_NO_SCRIPT=1 opkg --force-downgrade install "$PACKAGE" || fail 'Public-package switch failed; backup retained'
  else IPKG_NO_SCRIPT=1 opkg install "$PACKAGE" || fail 'Public Meshtastic package installation failed; backup retained'; fi
  package_installed=1
  refresh_status || fail 'Cannot verify public package status'
fi
is_installed meshtasticd-full && [ "$(status_field meshtasticd-full Version)" = "$PACKAGE_VERSION" ] || fail 'Pinned public Meshtastic package is not fully installed'
verify_file /usr/bin/meshtasticd "$BINARY_SHA256"
[ -x "$SERVICE" ] || fail 'meshtasticd init script missing'
validate_main_config
prepare_persistent_data
install_init_policy
verify_init_policy
assert_stopped
LOG "Public meshtasticd $PACKAGE_VERSION installed/configured; server remains stopped"
LOG 'Settings use persistent eMMC storage; legacy state and recovery backups are retained.'
if boot_enabled; then LOG 'Your explicit Enable at Boot: ON choice is preserved; no server was started'; else LOG 'Enable at Boot: OFF. Choose Start for the current session.'; fi
exit 0
