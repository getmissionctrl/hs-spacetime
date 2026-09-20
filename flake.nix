{
  description = "hs-spacetime — native Haskell client SDK for SpacetimeDB";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    spacetimedb = {
      url = "github:clockworklabs/SpacetimeDB";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    ghc-wasm-meta = {
      url = "github:haskell-wasm/ghc-wasm-meta";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, spacetimedb, ghc-wasm-meta }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        hs-spacetime = pkgs.haskellPackages.callCabal2nix "hs-spacetime" ./. {};
        # Hermetic shell: GHC with every dep of the package plus cabal, a
        # formatter, and the C libs the wire layer links (brotli, zlib).
        dev = hs-spacetime.env.overrideAttrs (old: {
          nativeBuildInputs = (old.nativeBuildInputs or [])
            ++ [ pkgs.cabal-install pkgs.fourmolu pkgs.brotli pkgs.zlib pkgs.pkg-config ];
        });
        # Live shell: everything in dev, plus the spacetime CLI + a Rust wasm
        # toolchain for building the fixture module. Kept out of `dev` so CI
        # carries no compiler.
        spacetimeCli = spacetimedb.packages.${system}.spacetime;
        live = dev.overrideAttrs (old: {
          nativeBuildInputs = (old.nativeBuildInputs or [])
            ++ [ spacetimeCli pkgs.rustup ];
        });
        # ghc-wasm-meta moved from tweag/ to haskell-wasm/ on GitHub.
        # all_9_12 chosen: GHC 9.12 is the newest stable wasm-capable release
        # (all_9_14 exists but is pre-release; 9.10+ required for reactor + --export flags).
        wasmToolchain = ghc-wasm-meta.packages.${system}.all_9_12;
        wasm = pkgs.mkShell {
          packages = [
            wasmToolchain
            pkgs.wizer
            pkgs.wasm-tools
            pkgs.binaryen
            pkgs.rustup
            pkgs.cargo
            spacetimeCli
          ];
        };
      in {
        packages.default = hs-spacetime;
        packages.spacetime = spacetimeCli;
        devShells.dev = dev;
        devShells.default = dev;
        devShells.live = live;
        devShells.wasm = wasm;
      });
}
