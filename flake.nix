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
        # Extra Haskell libs the example clients need but the core package does
        # not depend on. These must land in GHC's package DB (not merely on
        # PATH): CI has no Hackage index and resolves deps solely from the
        # Nix-provided DB, so `nativeBuildInputs` alone is not enough (it leaves
        # the DB unchanged and `cabal build all` fails to find vty-crossplatform).
        # `shellFor` with `additional` registers them in the same DB as
        # hs-spacetime's own deps.
        extraHsPkgs = p: [ p.brick p.vty p.vty-crossplatform ];
        # Add the example clients' libs as build-depends of hs-spacetime, so its
        # `.env` builds a GHC whose package DB includes them. `.env` registers
        # every haskellBuildInput in the DB (unlike nativeBuildInputs, which only
        # affects PATH) — required for CI, which has no Hackage index.
        hsForDev = pkgs.haskell.lib.addBuildDepends hs-spacetime
          (extraHsPkgs pkgs.haskellPackages);
        dev = hsForDev.env.overrideAttrs (old: {
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
            pkgs.nodejs
            pkgs.python3
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
