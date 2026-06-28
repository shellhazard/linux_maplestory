# linux_maplestory

Run MapleStory on Linux under GE-Proton11-1 using Nix. This is a reproducible stopgap until the necessary patches are upstreamed to Proton.

## Prerequisites

1. The [Nix package manager](https://github.com/NixOS/nix-installer), or NixOS.
2. **Steam** installed and logged in
3. **MapleStory** installed on Steam
4. **GE-Proton11-1** selected under Properties -> Compatibility (install with `protonup` and restart Steam).
5. Launch MapleStory **once** from Steam to create the Proton prefix.

## Usage

```sh
nix run .#maplestory-linux-patch
```
This will:
- Install VC++ 2022 runtime DLLs (fetched from Microsoft's redistributable at Nix build time).
- Generate `.mappings.ini` and `apps-settings.db`.
- Apply binary patches to GE-Proton11-1's `kernelbase.dll` (this is the important one) and `win32u.so`.
- Apply Wine registry patches for alt-tab focus, DirectInput, DLL overrides,
  and the Nexon Launcher protocol.

### Options

```
--virtual-desktop          Enable Wine virtual desktop (for BadWindow /
                           X_CreateWindow crash or alt-tab input loss under
                           XWayland: Hyprland, Mint, GNOME/mutter).
--desktop-size WxH         Enable virtual desktop at a custom size (default: 3840x2160).
--kill                     Terminate running MapleStory/Nexon processes before patching.
--dry-run                  Print actions without modifying anything.
--fix-fkeys                Set hid_apple fnmode=2 for this boot so Apple-compatible
                           keyboards send real F1-F12 instead of media keys.
                           Requires sudo. Use only if plain F-keys don't work.
--persist-fkeys            Also write /etc/modprobe.d/hid_apple.conf for reboot
                           persistence. Implies --fix-fkeys. Requires sudo.
--steam-root PATH          Override Steam install directory (default: auto-detect).
--appid ID                 Steam app ID (default: 216150).
--prefix-dir PATH          Override compatdata directory.
```

## Contributions

- Aside from the README and the patches sourced from upstream, this repository was entirely authored by GLM 5.2 and is not intended for human consumption. Please file an issue if you're running into problems.