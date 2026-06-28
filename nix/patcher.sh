#!/usr/bin/env bash
set -euo pipefail

#
# maplestory-linux-patch
#
# Applies all patches needed to run MapleStory (Steam app 216150) under
# GE-Proton11-1 on Linux. Run it after installing MapleStory on Steam,
# selecting GE-Proton11-1, and launching once to create the Proton prefix.
#
# Prerequisites:
#   1. Steam installed and logged in.
#   2. MapleStory (app 216150) installed.
#   3. GE-Proton11-1 selected as the compatibility tool.
#   4. MapleStory launched at least once (creates the Proton prefix).
#
# What this does:
#   - Installs VC++ 2022 runtime DLLs (from the Microsoft redistributable)
#   - Generates .mappings.ini and apps-settings.db
#   - Applies byte-level patches to GE-Proton11-1's kernelbase.dll and win32u.so
#   - Imports Wine registry patches (alt-tab fix, input fixes, DLL overrides, etc.)
#
# Everything is backed up before modification.
#

APPID="${APPID:-216150}"
PROTON_REQUIRED="GE-Proton11-1"

SHARE_DIR="@share@"
VC_RUNTIME_DIR="$SHARE_DIR/vc-runtime"
PATCHES_DIR="$SHARE_DIR/patches"

# DLLs to install from the VC++ redist (ucrtbase is Wine-builtin, not from redist)
SYSTEM32_DLLS=(
  concrt140.dll msvcp140.dll msvcp140_1.dll msvcp140_2.dll
  msvcp140_atomic_wait.dll msvcp140_codecvt_ids.dll
  vccorlib140.dll vcomp140.dll vcruntime140.dll vcruntime140_1.dll
  vcruntime140_threads.dll
)
SYSWOW64_DLLS=(
  concrt140.dll msvcp140.dll msvcp140_1.dll msvcp140_2.dll
  msvcp140_atomic_wait.dll msvcp140_codecvt_ids.dll
  vccorlib140.dll vcomp140.dll vcruntime140.dll
  vcruntime140_threads.dll
)

USE_VIRTUAL_DESKTOP=0
DESKTOP_SIZE="${VIRTUAL_DESKTOP_SIZE:-3840x2160}"
KILL_RUNNING=0
DRY_RUN=0
FIX_FKEYS=0
PERSIST_FKEYS=0

log() { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: maplestory-linux-patch [options]

Applies all patches to run MapleStory under GE-Proton11-1 on Linux.

Prerequisites:
  1. Install MapleStory on Steam (app 216150).
  2. Select GE-Proton11-1 as the compatibility tool.
  3. Launch once from Steam to create the Proton prefix.

Options:
  --virtual-desktop         Enable the Wine virtual desktop (for BadWindow /
                            X_CreateWindow crash or alt-tab input loss under
                            XWayland: Hyprland, Mint, GNOME/mutter).
  --no-virtual-desktop      Disable the Wine virtual desktop (default).
  --desktop-size WxH        Enable virtual desktop at a custom size (default: 3840x2160).
  --kill                    Terminate running MapleStory/Nexon processes before patching.
  --dry-run                 Print actions without modifying anything.
  --fix-fkeys               Set hid_apple fnmode=2 for this boot so Apple-compatible
                            keyboards send real F1-F12 instead of media keys.
                            Requires sudo. Use only if plain F-keys don't work.
  --persist-fkeys           Also write /etc/modprobe.d/hid_apple.conf for reboot
                            persistence. Implies --fix-fkeys.
  --steam-root PATH         Override Steam install directory (default: auto-detect).
  --appid ID                Steam app ID (default: 216150). The prefix is
                            auto-detected as <steam-root>/steamapps/compatdata/<appid>.
  --prefix-dir PATH         Override the compatdata directory entirely (skips
                            the steam-root + appid computation).
  -h, --help                Show this help.

Environment overrides:
  STEAM_ROOT, APPID, PREFIX_DIR, VIRTUAL_DESKTOP_SIZE
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --virtual-desktop) USE_VIRTUAL_DESKTOP=1; shift ;;
    --no-virtual-desktop) USE_VIRTUAL_DESKTOP=0; shift ;;
    --desktop-size) DESKTOP_SIZE="${2:?}"; USE_VIRTUAL_DESKTOP=1; shift 2 ;;
    --kill) KILL_RUNNING=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --fix-fkeys) FIX_FKEYS=1; shift ;;
    --persist-fkeys) FIX_FKEYS=1; PERSIST_FKEYS=1; shift ;;
    --steam-root) STEAM_ROOT="${2:?}"; shift 2 ;;
    --appid) APPID="${2:?}"; shift 2 ;;
    --prefix-dir) PREFIX_DIR="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

if [ "$DRY_RUN" -eq 1 ]; then
  run() { printf '[dry-run] '; printf '%q ' "$@"; printf '\n'; }
else
  run() { "$@"; }
fi

#
# --- Locate Steam ---
#
STEAM_ROOT="${STEAM_ROOT:-}"
if [ -z "$STEAM_ROOT" ]; then
  for p in \
    "$HOME/.local/share/Steam" \
    "$HOME/.steam/steam" \
    "$HOME/.steam/debian-installation"; do
    [ -d "$p" ] && STEAM_ROOT="$p" && break
  done
fi
[ -d "$STEAM_ROOT" ] || die "Steam not found. Pass --steam-root PATH or set STEAM_ROOT."
log "Steam root: $STEAM_ROOT"
log "App ID: $APPID"

#
# --- Locate Proton prefix (auto: $STEAM_ROOT/steamapps/compatdata/$APPID) ---
#
PREFIX_DIR="${PREFIX_DIR:-$STEAM_ROOT/steamapps/compatdata/$APPID}"
PFX="$PREFIX_DIR/pfx"
if [ ! -d "$PFX/drive_c" ]; then
  die "Proton prefix not found at $PFX/drive_c.
Launch MapleStory once from Steam to create it:
  steam steam://rungameid/$APPID"
fi
log "Prefix: $PREFIX_DIR"

#
# --- Verify GE-Proton11-1 ---
#
VERSION_FILE="$PREFIX_DIR/version"
[ -f "$VERSION_FILE" ] || die "No Proton version file at $VERSION_FILE."
PROTON_VERSION="$(tr -d '\r\n' < "$VERSION_FILE")"
case "$PROTON_VERSION" in
  *"$PROTON_REQUIRED"*) ;;
  *) die "Proton tool is '$PROTON_VERSION', but '$PROTON_REQUIRED' is required.
Select GE-Proton11-1 in Steam -> MapleStory -> Properties -> Compatibility." ;;
esac
log "Proton: $PROTON_VERSION"

#
# --- Find Proton and Wine binaries ---
#
COMMON_DIR="$STEAM_ROOT/steamapps/common"
PROTON=""
for p in \
  "$STEAM_ROOT/compatibilitytools.d/$PROTON_VERSION/proton" \
  "$COMMON_DIR/$PROTON_VERSION/proton"; do
  [ -x "$p" ] && PROTON="$p" && break
done
[ -n "$PROTON" ] || die "Proton binary not found for $PROTON_VERSION."

PROTON_DIR="$(cd "$(dirname "$PROTON")" && pwd)"
WINE_LIB="$PROTON_DIR/files/lib/wine"
WINE_BIN=""
WINESERVER=""
for b in \
  "$PROTON_DIR/files/bin/wine" \
  "$PROTON_DIR/files/bin/wine64" \
  "$PROTON_DIR/dist/bin/wine" \
  "$PROTON_DIR/dist/bin/wine64"; do
  [ -x "$b" ] && WINE_BIN="$b" && break
done
for w in \
  "$PROTON_DIR/files/bin/wineserver" \
  "$PROTON_DIR/dist/bin/wineserver"; do
  [ -x "$w" ] && WINESERVER="$w" && break
done
log "Proton binary: $PROTON"
[ -n "$WINE_BIN" ] && log "Wine binary: $WINE_BIN" || warn "Wine binary not found (regedit fallback unavailable)"

#
# --- Check for running processes ---
#
check_processes() {
  command -v pgrep >/dev/null 2>&1 || return 0
  local matches
  matches="$(pgrep -af -i "SteamLaunch AppId=$APPID|MapleStory.exe|nxsteam|BlackCipher|DwarfAxe" 2>/dev/null | grep -vE "^($$|$PPID) " || true)"
  [ -n "$matches" ] || return 0

  if [ "$KILL_RUNNING" -eq 1 ]; then
    log "Terminating running MapleStory/Nexon processes"
    if [ "$DRY_RUN" -eq 1 ]; then
      printf '[dry-run] pkill -TERM MapleStory/Nexon\n'
    else
      pkill -TERM -f "MapleStory.exe|nxsteam|BlackCipher|DwarfAxe|SteamLaunch AppId=$APPID" 2>/dev/null || true
      sleep 2
    fi
  else
    printf '%s\n' "$matches" >&2
    die "MapleStory or helpers are still running. Close them first, or use --kill."
  fi
}
check_processes

#
# --- Backups ---
#
BACKUP_DIR="$PREFIX_DIR/linux_maplestory-backups/$(date +%Y%m%d-%H%M%S)"
log "Backup directory: $BACKUP_DIR"

backup_path() {
  local path="$1"
  [ -e "$path" ] || return 0
  local rel="${path#$PREFIX_DIR/}"
  run mkdir -p "$BACKUP_DIR/$(dirname "$rel")"
  run cp -a -- "$path" "$BACKUP_DIR/$rel"
}

backup_targets() {
  backup_path "$PFX/user.reg"
  backup_path "$PFX/system.reg"
  backup_path "$PFX/userdef.reg"
  backup_path "$PFX/drive_c/.mappings.ini"
  backup_path "$PFX/drive_c/users/steamuser/AppData/Roaming/NexonLauncher/apps-settings.db"

  local dll
  for dll in "${SYSTEM32_DLLS[@]}"; do
    backup_path "$PFX/drive_c/windows/system32/$dll"
  done
  for dll in "${SYSWOW64_DLLS[@]}"; do
    backup_path "$PFX/drive_c/windows/syswow64/$dll"
  done

  # Note: Wine binaries (kernelbase.dll, win32u.so) are backed up separately
  # by byte-patch.py into $BACKUP_DIR/wine-patches/
}

log "Backing up files..."
backup_targets

#
# --- Step 1: VC++ 2022 runtime DLLs ---
#
log "Installing VC++ 2022 runtime DLLs (from Microsoft redistributable)"

for dll in "${SYSTEM32_DLLS[@]}"; do
  src="$VC_RUNTIME_DIR/system32/$dll"
  dst="$PFX/drive_c/windows/system32/$dll"
  if [ ! -f "$src" ]; then
    warn "missing from redist: system32/$dll"
    continue
  fi
  run cp -f -- "$src" "$dst"
done

for dll in "${SYSWOW64_DLLS[@]}"; do
  src="$VC_RUNTIME_DIR/syswow64/$dll"
  dst="$PFX/drive_c/windows/syswow64/$dll"
  if [ ! -f "$src" ]; then
    warn "missing from redist: syswow64/$dll"
    continue
  fi
  run cp -f -- "$src" "$dst"
done

# Note: ucrtbase.dll is NOT installed — it is a Wine builtin, already in the prefix.

#
# --- Step 2: .mappings.ini ---
#
log "Installing .mappings.ini"
if [ "$DRY_RUN" -eq 1 ]; then
  printf '[dry-run] write .mappings.ini\n'
else
  cat > "$PFX/drive_c/.mappings.ini" <<'EOF'
MapleStory.exe=MapleStory
nexon_client.exe=Nexon Launcher
nexon_updater.exe=Nexon Updater
EOF
fi

#
# --- Step 3: apps-settings.db ---
#
log "Installing apps-settings.db"
APPS_SETTINGS_DIR="$PFX/drive_c/users/steamuser/AppData/Roaming/NexonLauncher"
if [ "$DRY_RUN" -eq 1 ]; then
  printf '[dry-run] write apps-settings.db\n'
else
  mkdir -p -- "$APPS_SETTINGS_DIR"
  printf '{"locale":"en_US"}' > "$APPS_SETTINGS_DIR/apps-settings.db"
fi

#
# --- Step 4: Wine binary patches (kernelbase.dll + win32u.so) ---
#
log "Applying Wine binary patches to GE-Proton11-1"
log "  (modifies $WINE_LIB in-place — backups in $BACKUP_DIR/wine-patches)"
log "  NOTE: dinput8.dll cross-build substitute is SKIPPED (unproven necessity)"
if [ "$DRY_RUN" -eq 1 ]; then
  printf '[dry-run] python3 %s %s %s/wine-patches\n' \
    "$SHARE_DIR/byte-patch.py" "$WINE_LIB" "$BACKUP_DIR"
else
  python3 "$SHARE_DIR/byte-patch.py" "$WINE_LIB" "$BACKUP_DIR/wine-patches" || \
    die "Byte patching failed. The GE-Proton11-1 build may differ from expected."
fi

#
# --- Step 5: Registry imports ---
#
# All .reg files are imported in a single wineserver session, then the
# wineserver is killed once to flush everything to disk. Killing and
# restarting the wineserver between each import was breaking subsequent
# imports.
wait_wineserver() {
  [ -n "$WINESERVER" ] && [ -x "$WINESERVER" ] || return 0
  WINEPREFIX="$PFX" "$WINESERVER" -k 2>/dev/null || true
  WINEPREFIX="$PFX" "$WINESERVER" -w 2>/dev/null || true
}

reg_value_present() {
  local marker="$1"
  [ -n "$marker" ] || return 0
  grep -F -q -- "$marker" "$PFX/user.reg" 2>/dev/null && return 0
  grep -F -q -- "$marker" "$PFX/system.reg" 2>/dev/null && return 0
  return 1
}

# Runs regedit without touching the wineserver — the server stays alive
# between calls so all imports share one in-memory registry.
run_regedit() {
  local reg_file="$1"
  local name
  name="$(basename "$reg_file")"
  log "Importing $name"

  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] regedit /S %s\n' "$reg_file"
    return
  fi

  LD_LIBRARY_PATH="$PROTON_DIR/files/lib:${LD_LIBRARY_PATH:-}" \
  WINEPREFIX="$PFX" \
  WINEDEBUG=-all \
  "$WINE_BIN" regedit /S "$reg_file" 2>&1 | grep -v '^fsync:' || true
}

# Generate virtual-desktop .reg if needed
if [ "$USE_VIRTUAL_DESKTOP" -eq 1 ]; then
  if [[ ! "$DESKTOP_SIZE" =~ ^[0-9]+x[0-9]+$ ]]; then
    die "desktop size must be WIDTHxHEIGHT, got: $DESKTOP_SIZE"
  fi
  log "Enabling Wine virtual desktop at $DESKTOP_SIZE"
  desktop_reg="$BACKUP_DIR/02-virtual-desktop-$DESKTOP_SIZE.reg"
  if [ "$DRY_RUN" -eq 0 ]; then
    cat > "$desktop_reg" <<REG
Windows Registry Editor Version 5.00

[HKEY_CURRENT_USER\\Software\\Wine\\Explorer]
"Desktop"="Default"

[HKEY_CURRENT_USER\\Software\\Wine\\Explorer\\Desktops]
"Default"="$DESKTOP_SIZE"
REG
  fi
fi

# Import all .reg files in one wineserver session
run_regedit "$PATCHES_DIR/01-usetakefocus.reg"
if [ "$USE_VIRTUAL_DESKTOP" -eq 1 ]; then
  [ -n "$desktop_reg" ] && run_regedit "$desktop_reg"
else
  run_regedit "$PATCHES_DIR/02-disable-virtual-desktop.reg"
  log "Virtual desktop disabled (default). Use --virtual-desktop if you hit"
  log "the BadWindow/X_CreateWindow crash or alt-tab input loss under XWayland."
fi
run_regedit "$PATCHES_DIR/03-nexon-launcher-protocol.reg"
run_regedit "$PATCHES_DIR/04-direct3d-dll-overrides.reg"
run_regedit "$PATCHES_DIR/05-input-fixes.reg"
run_regedit "$PATCHES_DIR/06-appdefaults-winver.reg"

# Flush the registry to disk (single kill + wait)
wait_wineserver

# Verify markers
check_reg() {
  local reg_file="$1"
  local marker="$2"
  [ -n "$marker" ] || return 0
  local name
  name="$(basename "$reg_file")"
  if ! reg_value_present "$marker"; then
    warn "registry patch may not have applied: $name (expected '$marker')"
    warn "try importing it manually via Protontricks for app $APPID"
  fi
}

check_reg "$PATCHES_DIR/01-usetakefocus.reg" '"UseTakeFocus"'
check_reg "$PATCHES_DIR/03-nexon-launcher-protocol.reg" 'URL:nxl protocol'
check_reg "$PATCHES_DIR/04-direct3d-dll-overrides.reg" 'cb_access_map_w'
check_reg "$PATCHES_DIR/05-input-fixes.reg" '"UseLinuxInputEvents"'
check_reg "$PATCHES_DIR/06-appdefaults-winver.reg" '"Version"="win10"'

#
# --- Verify ---
#
if [ "$DRY_RUN" -eq 0 ]; then
  log "Verifying installation"
  for f in \
    "$PFX/drive_c/windows/system32/vcruntime140_threads.dll" \
    "$PFX/drive_c/windows/syswow64/vcruntime140_threads.dll" \
    "$PFX/drive_c/.mappings.ini" \
    "$PFX/drive_c/users/steamuser/AppData/Roaming/NexonLauncher/apps-settings.db"; do
    [ -f "$f" ] || die "verification failed: $f not found"
  done

  # Verify Wine binary patches landed
  if [ -f "$WINE_LIB/x86_64-windows/kernelbase.dll" ] && [ -f "$WINE_LIB/x86_64-unix/win32u.so" ]; then
    log "Wine binary patches verified (kernelbase.dll + win32u.so)"
  else
    warn "could not verify Wine binary patches — check that GE-Proton11-1 is installed"
  fi
fi

#
# --- F-key fix (hid_apple fnmode) ---
#
HID_APPLE_PARAM="/sys/module/hid_apple/parameters/fnmode"
HID_APPLE_CONF="/etc/modprobe.d/hid_apple.conf"

apply_fkey_fix() {
  [ "$FIX_FKEYS" -eq 1 ] || return 0

  if [ ! -e "$HID_APPLE_PARAM" ]; then
    log "hid_apple module not loaded — no F-key fix needed."
    return 0
  fi

  local current
  current="$(cat "$HID_APPLE_PARAM" 2>/dev/null || true)"

  if [ "$current" = "2" ]; then
    log "hid_apple fnmode is already 2 (F1-F12 first)."
  else
    log "Setting hid_apple fnmode=2 (F1-F12 first). Requires sudo."
    if [ "$DRY_RUN" -eq 1 ]; then
      printf '[dry-run] echo 2 | sudo tee %s\n' "$HID_APPLE_PARAM"
    else
      printf '2\n' | sudo tee "$HID_APPLE_PARAM" >/dev/null
    fi
  fi

  if [ "$PERSIST_FKEYS" -eq 1 ]; then
    log "Writing persistent modprobe config: $HID_APPLE_CONF"
    if [ "$DRY_RUN" -eq 1 ]; then
      printf '[dry-run] echo "options hid_apple fnmode=2" | sudo tee %s\n' "$HID_APPLE_CONF"
    else
      printf 'options hid_apple fnmode=2\n' | sudo tee "$HID_APPLE_CONF" >/dev/null
      log "If your distro loads hid_apple from initramfs, rebuild it before rebooting."
    fi
  fi

  if [ "$DRY_RUN" -eq 0 ]; then
    log "hid_apple fnmode: $(cat "$HID_APPLE_PARAM")"
  fi
}

#
# --- Warn about hid_apple if not fixing ---
#
warn_hid_apple() {
  [ "$FIX_FKEYS" -eq 1 ] && return 0
  [ -r "$HID_APPLE_PARAM" ] || return 0
  local mode
  mode="$(cat "$HID_APPLE_PARAM" 2>/dev/null || true)"
  [ "$mode" = "2" ] && return 0
  warn "hid_apple fnmode is $mode, not 2. Some Apple-compatible keyboards"
  warn "send media keys instead of F1-F12. If F-keys don't work in MapleStory,"
  warn "re-run with --fix-fkeys (or --persist-fkeys for reboot persistence)."
}

warn_hid_apple
apply_fkey_fix

#
# --- Done ---
#
log ""
log "Install complete!"
log "Backups: $BACKUP_DIR"
log ""
log "Next steps:"
log "  1. Relaunch MapleStory through Steam."
log "  2. Test keyboard input (movement, skills, Alt+1-5, F1-F12)."
log "  3. Test alt-tab (switch away and back)."
log ""
if [ "$USE_VIRTUAL_DESKTOP" -eq 0 ]; then
  log "If you hit the BadWindow/X_CreateWindow crash or lose input after alt-tab:"
  log "  nix run .#maplestory-linux-patch -- --virtual-desktop"
fi
