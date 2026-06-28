#!/usr/bin/env python3
"""Apply byte-level patches to Wine binaries shipped with GE-Proton11-1.

These patches are build-specific and were reverse-engineered from the known-working
macOS Wine environment.

Patches applied:
  kernelbase.dll:
    - CharPrevExA @0x11413: add NULL-check for lpString (fixes 0xc0000005/Themida crash)
    - HeapSetInformation @0x33443: return TRUE (success) without doing anything
    - HeapSetInformation @0x3344e: increment eax instead of ebx
    - SetLastError(0) @0x335a9: clear error to 0 instead of 0x7b
  win32u.so:
    - SPI_SETSTICKYKEYS @0x122fa7: jz → jmp (force success)
    - SPI_SETFILTERKEYS @0x122c1c: jz → jmp (force success)

  dinput8.dll: SKIPPED — was a cross-build substitute from Proton-Experimental.
  The original repo shipped a wholesale copy with no documented crash it fixes.
  TODO: investigate whether this is actually needed.
"""
import os
import shutil
import struct
import sys
from pathlib import Path

#
# --- kernelbase.dll patches ---
#
# Exact byte replacements at fixed file offsets. These instructions are
# position-independent (no relative jumps), so the stock bytes must match
# exactly. If they don't, the GE-Proton11-1 build differs from the expected one.
#
KERNELBASE_PATCHES = [
    (0x11413,
     b"\x0f\xb7\xf9\xeb\x2d\x0f\x1f\x84\x00\x00\x00\x00\x00",
     b"\x48\x85\xdb\x74\x35\x0f\xb7\xf9\xeb\x28\x90\x90\x90"),
    (0x33443, b"\x31\xdb", b"\x31\xc0"),
    (0x3344e, b"\x89\xd8", b"\xff\xc0"),
    (0x335a9, b"\xc7\x40\x68\x7b\x00\x00\x00",
              b"\xc7\x40\x68\x00\x00\x00\x00"),
]

#
# --- win32u.so patches ---
#
# These convert `jz rel32` (conditional jump to a failure handler) to
# `jmp rel32` (unconditional jump to the success-return path) + nop.
#
# The jz targets (failure handlers) can move between builds, but the jmp
# target (success-return path) is a fixed code sequence: `mov ebx, 1; nop`
# (sets the return value to TRUE before the function epilogue). We search
# for this pattern near the expected address and compute the jmp rel32
# dynamically. This is independent of where the jz failure handler ended up.
#

# File offsets of the two jz instructions to patch
WIN32U_PATCH_OFFSETS = [
    0x122fa7,   # SPI_SETSTICKYKEYS
    0x122c1c,   # SPI_SETFILTERKEYS
]

# Success-return pattern: mov ebx, 1 (set return TRUE); 3-byte nop
SUCCESS_RETURN_PATTERN = b"\xbb\x01\x00\x00\x00\x0f\x1f\x00"

# Expected address of the success-return pattern (from the original build)
SUCCESS_RETURN_EXPECTED = 0x121dd0

# How far to search around the expected address
SEARCH_RANGE = 0x2000   # ±8 KB

TARGET_PATHS = {
    "kernelbase.dll": ["x86_64-windows", "kernelbase.dll"],
    "win32u.so":      ["x86_64-unix",    "win32u.so"],
}


def apply_fixed_patch(data, offset, stock, live):
    """Exact byte replacement. Returns True if ok (patched or already-patched)."""
    actual = bytes(data[offset:offset + len(stock)])
    if actual == live:
        print(f"  already patched @0x{offset:x}")
        return True
    if actual != stock:
        print(f"  ERROR @0x{offset:x}: expected stock {stock.hex()}, got {actual.hex()}",
              file=sys.stderr)
        return False
    data[offset:offset + len(live)] = live
    print(f"  patched @0x{offset:x}: {stock.hex()} -> {live.hex()}")
    return True


def find_success_return(data):
    """Search for the success-return pattern near the expected address."""
    start = max(0, SUCCESS_RETURN_EXPECTED - SEARCH_RANGE)
    end = min(len(data), SUCCESS_RETURN_EXPECTED + SEARCH_RANGE)
    idx = data.find(SUCCESS_RETURN_PATTERN, start, end)
    if idx == -1:
        return None
    return idx


def patch_win32u(data):
    """Apply jz→jmp patches to win32u.so.

    Finds the success-return path by searching for `mov ebx, 1; nop`,
    then rewrites each `jz rel32` (6 bytes) to `jmp rel32 + nop` (6 bytes)
    targeting that address.
    """
    # Check if all sites are already patched
    all_patched = all(
        data[off] == 0xE9 and data[off + 5] == 0x90
        for off in WIN32U_PATCH_OFFSETS
    )
    if all_patched:
        for off in WIN32U_PATCH_OFFSETS:
            rel = struct.unpack_from('<i', data, off + 1)[0]
            print(f"  already patched @0x{off:x} (jmp {rel:#x})")
        return True

    # Verify each site is a jz rel32 (0f 84)
    for off in WIN32U_PATCH_OFFSETS:
        if data[off] == 0xE9 and data[off + 5] == 0x90:
            continue   # already patched
        if data[off] != 0x0F or data[off + 1] != 0x84:
            got = bytes(data[off:off + 2]).hex()
            print(f"  ERROR @0x{off:x}: expected jz (0f 84), got {got}",
                  file=sys.stderr)
            return False

    # Find the success-return address
    success_addr = find_success_return(data)
    if success_addr is None:
        print(f"  ERROR: success-return pattern ({SUCCESS_RETURN_PATTERN.hex()}) "
              f"not found within ±{SEARCH_RANGE:#x} of {SUCCESS_RETURN_EXPECTED:#x}",
              file=sys.stderr)
        return False

    if success_addr != SUCCESS_RETURN_EXPECTED:
        print(f"  NOTE: success-return found at 0x{success_addr:x} "
              f"(shifted {success_addr - SUCCESS_RETURN_EXPECTED:+#x} from expected)")

    # Apply patches
    for off in WIN32U_PATCH_OFFSETS:
        if data[off] == 0xE9 and data[off + 5] == 0x90:
            rel = struct.unpack_from('<i', data, off + 1)[0]
            print(f"  already patched @0x{off:x} (jmp {rel:#x})")
            continue

        actual_jz = struct.unpack_from('<i', data, off + 2)[0]
        jmp_rel = success_addr - (off + 5)

        data[off] = 0xE9
        struct.pack_into('<i', data, off + 1, jmp_rel)
        data[off + 5] = 0x90

        print(f"  patched @0x{off:x}: jz {actual_jz:#x} -> "
              f"jmp {jmp_rel:#x} (target 0x{success_addr:x})")

    return True


def patch_file(path: Path, patches, backup_dir: Path, patch_type: str) -> bool:
    original = path.read_bytes()
    data = bytearray(original)

    if patch_type == "fixed":
        for offset, stock, live in patches:
            if not apply_fixed_patch(data, offset, stock, live):
                return False
    elif patch_type == "jump":
        if not patch_win32u(data):
            return False

    changed = (bytes(data) != original)
    if not changed:
        print("  (no changes needed)")
        return True

    backup_dir.mkdir(parents=True, exist_ok=True)
    backup = backup_dir / path.name
    if not backup.exists():
        shutil.copy2(path, backup)
        print(f"  backed up original -> {backup}")

    os.chmod(path, 0o755)
    path.write_bytes(bytes(data))
    print(f"  wrote {len(data)} bytes to {path}")
    return True


def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <wine_lib_dir> <backup_dir>", file=sys.stderr)
        print(f"  wine_lib_dir: GE-Proton11-1/files/lib/wine", file=sys.stderr)
        sys.exit(2)

    wine_lib = Path(sys.argv[1])
    backup_dir = Path(sys.argv[2])

    targets = {
        "kernelbase.dll": ("fixed", KERNELBASE_PATCHES),
        "win32u.so":      ("jump", WIN32U_PATCH_OFFSETS),
    }

    all_ok = True
    for name, (ptype, patches) in targets.items():
        parts = TARGET_PATHS[name]
        path = wine_lib.joinpath(*parts)

        if not path.exists():
            print(f"SKIP {name}: not found at {path}", file=sys.stderr)
            all_ok = False
            continue

        print(f"PATCH {name} ({path})")
        if not patch_file(path, patches, backup_dir, ptype):
            all_ok = False

    if all_ok:
        print("All binary patches applied successfully.")
    else:
        print("Some patches failed or were skipped.", file=sys.stderr)
    sys.exit(0 if all_ok else 1)


if __name__ == "__main__":
    main()
