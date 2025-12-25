#!/bin/bash

# Title: MeshInstaller
# Description: Installs meshtasticd if missing, configures Mesh Mod, starts service
# Author: GlytchTech

set -u

opkg_update_soft() {
  LOG "Running opkg update"
  opkg update >/tmp/opkg_update.log 2>&1
  rc=$?

  if [ $rc -ne 0 ]; then
    LOG "WARN: opkg update returned rc=$rc (expected)"
    grep -iE "failed|error" /tmp/opkg_update.log 2>/dev/null | head -n 5 | while read -r line; do
      LOG "opkg: $line"
    done
  else
    LOG "opkg update completed"
  fi

  return 0
}

is_installed() {
  opkg list-installed 2>/dev/null | grep -qE '^meshtasticd[[:space:]]'
}

if is_installed; then
  LOG "meshtasticd already installed"
else
  opkg_update_soft

  if ! opkg list-installed 2>/dev/null | grep -qE '^wget-ssl[[:space:]]'; then
    LOG "Installing wget-ssl"
    opkg install wget-ssl || { LOG "FAIL: wget-ssl install failed"; exit 1; }
  else
    LOG "wget-ssl already installed"
  fi

  LOG "Downloading Meshtastic opkg key"
  wget -O /tmp/meshtastic-ipk.pub https://openwrt.meshtastic.org/meshtastic-ipk.pub \
    || { LOG "FAIL: key download failed"; exit 1; }

  LOG "Adding Meshtastic opkg key"
  opkg-key add /tmp/meshtastic-ipk.pub \
    || { LOG "FAIL: key add failed"; exit 1; }

  rm -f /tmp/meshtastic-ipk.pub

  LOG "Adding Meshtastic feed"
  sed -i '/meshtastic/d' /etc/opkg/customfeeds.conf 2>/dev/null || true
  echo "src/gz meshtastic https://openwrt.meshtastic.org/openwrt-24.10/mipsel_24kc/" \
    >> /etc/opkg/customfeeds.conf

  LOG "Detecting kernel kmod ABI"
  BASE="https://downloads.openwrt.org/releases/24.10.1/targets/ramips/mt76x8"
  ABI="$(wget -qO- "$BASE/kmods/" | sed -n 's#.*href="\([^/"]\+\)/.*#\1#p' | head -n1)"
  [ -n "$ABI" ] || { LOG "FAIL: could not determine kmod ABI"; exit 1; }

  sed -i '/^src\/gz .*kmods/d' /etc/opkg/distfeeds.conf 2>/dev/null || true
  echo "src/gz pineapple_pager_kmods $BASE/kmods/$ABI" >> /etc/opkg/distfeeds.conf
  LOG "Added kmods feed (ABI=$ABI)"

  opkg_update_soft

  LOG "Downloading meshtasticd package"
  opkg download meshtasticd || { LOG "FAIL: meshtasticd download failed"; exit 1; }

  LOG "Installing meshtasticd"
  opkg install --force-depends meshtasticd* \
    || { LOG "FAIL: meshtasticd install failed"; exit 1; }

  LOG "meshtasticd installed"
fi

SRC="/etc/meshtasticd/available.d/lora-usb-meshtoad-e22.yaml"
DST="/etc/meshtasticd/config.d/lora-usb-meshtoad-e22.yaml"

if [ -f "$DST" ]; then
  LOG "Config already present"
elif [ -f "$SRC" ]; then
  LOG "Copying config"
  cp "$SRC" "$DST" || { LOG "FAIL: config copy failed"; exit 1; }
else
  LOG "WARN: Config not found"
fi

if [ -x /etc/init.d/meshtasticd ]; then
  LOG "Enabling meshtasticd service"
  /etc/init.d/meshtasticd enable || true

  LOG "Starting meshtasticd service"
  /etc/init.d/meshtasticd start || true

  if /etc/init.d/meshtasticd status >/dev/null 2>&1; then
    LOG "meshtasticd is running"
  else
    LOG "WARN: meshtasticd not running (Mesh Mod connected?)"
  fi
else
  LOG "WARN: meshtasticd init script missing"
fi

LOG "MeshtasticD installer finished"

