{ pkgs
, vcRuntime
}:

let
  inherit (pkgs) stdenv lib steam-run-free;

  # Inner derivation: the script + bundled resources (patches, VC++ DLLs).
  inner = stdenv.mkDerivation {
    name = "maplestory-linux-patch-inner";
    dontUnpack = true;

    installPhase = ''
      runHook preInstall

      share="$out/share/maplestory-linux-patch"
      mkdir -p \
        "$out/bin" \
        "$share/patches" \
        "$share/vc-runtime/system32" \
        "$share/vc-runtime/syswow64"

      # Byte-patching script
      cp ${./byte-patch.py} "$share/byte-patch.py"

      # Registry patches
      cp ${../patches}/*.reg "$share/patches/"

      # VC++ runtime DLLs (from the Microsoft redistributable)
      cp ${vcRuntime}/system32/* "$share/vc-runtime/system32/"
      cp ${vcRuntime}/syswow64/* "$share/vc-runtime/syswow64/"

      # Main wrapper script
      substitute ${./patcher.sh} "$out/bin/maplestory-linux-patch" \
        --subst-var-by share "$share"
      chmod +x "$out/bin/maplestory-linux-patch"

      runHook postInstall
    '';
  };
in
  # steam-run provides an FHS environment with 32-bit and 64-bit glibc,
  # graphics drivers, python3, and other libraries that Proton/Wine need.
  # This is the same environment Steam uses to run Proton on NixOS.
  stdenv.mkDerivation {
    name = "maplestory-linux-patch";
    dontUnpack = true;

    installPhase = ''
      runHook preInstall

      mkdir -p "$out/bin"
      cat > "$out/bin/maplestory-linux-patch" <<EOF
      #!/bin/sh
      exec ${steam-run-free}/bin/steam-run ${inner}/bin/maplestory-linux-patch "\$@"
      EOF
      chmod +x "$out/bin/maplestory-linux-patch"

      runHook postInstall
    '';

    meta = with lib; {
      description = "Patches MapleStory to run under GE-Proton11-1 on Linux";
      mainProgram = "maplestory-linux-patch";
      platforms = [ "x86_64-linux" ];
      license = licenses.mit;
    };
  }
