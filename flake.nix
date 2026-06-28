{
  description = "MapleStory Linux Proton patcher — applies all patches needed to run MapleStory under GE-Proton11-1";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      #
      # VC++ 2022 redistributable — fetched from Microsoft with pinned hashes.
      # These are fixed-output derivations: if Microsoft updates the redist,
      # the hash won't match and you'll need to update it (nix-prefetch-url).
      #
      vcRedistX64 = pkgs.fetchurl {
        url = "https://aka.ms/vs/17/release/vc_redist.x64.exe";
        hash = "sha256-zA/w6x3D9RiK5jAPrvMr9b7rpL3W6ORFqRhAcglrcTs=";
      };
      vcRedistX86 = pkgs.fetchurl {
        url = "https://aka.ms/vs/17/release/vc_redist.x86.exe";
        hash = "sha256-DAnyYRZgRBCEzg30JcUcEeFH5kR5Y8NpD5fgslxV7WQ=";
      };

      #
      # Extract the VC++ runtime DLLs from the redistributable installers.
      #
      # The redist exe is a Burn (WiX) bundle. cabextract pulls out individual
      # package cabs (a0, a1, ...). We then extract each one and collect the
      # *_amd64 / *_x86 CRT DLLs. The cab numbering can change between redist
      # versions, so we scan all of them rather than hard-coding an index.
      #
      vcRuntime = pkgs.stdenv.mkDerivation {
        name = "vc-runtime-2022";
        nativeBuildInputs = [ pkgs.cabextract ];
        dontUnpack = true;

        installPhase = ''
          runHook preInstall

          mkdir -p "$out/system32" "$out/syswow64"

          # --- x64 (system32) ---
          work64="$(mktemp -d)"
          pushd "$work64"
          cabextract -q "${vcRedistX64}"
          for cab in a*; do
            cabextract -q "$cab" 2>/dev/null || true
          done
          popd
          for f in "$work64"/*.dll_amd64; do
            [ -f "$f" ] || continue
            base="''${f##*/}"          # strip directory
            base="''${base%.dll_amd64}" # strip suffix
            cp "$f" "$out/system32/$base.dll"
          done

          # --- x86 (syswow64) ---
          work86="$(mktemp -d)"
          pushd "$work86"
          cabextract -q "${vcRedistX86}"
          for cab in a*; do
            cabextract -q "$cab" 2>/dev/null || true
          done
          popd
          for f in "$work86"/*.dll_x86; do
            [ -f "$f" ] || continue
            base="''${f##*/}"
            base="''${base%.dll_x86}"
            cp "$f" "$out/syswow64/$base.dll"
          done

          # Verify critical DLLs landed
          for arch in system32 syswow64; do
            [ -f "$out/$arch/vcruntime140_threads.dll" ] || {
              echo "ERROR: vcruntime140_threads.dll missing from $arch" >&2
              exit 1
            }
            [ -f "$out/$arch/vcruntime140.dll" ] || {
              echo "ERROR: vcruntime140.dll missing from $arch" >&2
              exit 1
            }
          done

          runHook postInstall
        '';
      };

      maplestory-linux-patch = import ./nix/maplestory-linux-patch.nix {
        inherit pkgs vcRuntime;
      };
    in
    {
      packages.${system} = {
        default = maplestory-linux-patch;
        inherit maplestory-linux-patch;
      };

      apps.${system} = {
        default = {
          type = "app";
          program = "${maplestory-linux-patch}/bin/maplestory-linux-patch";
        };
      };
    };
}
