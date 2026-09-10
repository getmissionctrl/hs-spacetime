{
  description = "hs-spacetime — native Haskell client SDK for SpacetimeDB";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    # NOTE: the `spacetimedb` input and the `.#live` dev shell are added in
    # Phase 6 (Task 6.1). Keeping them out of the initial flake means the
    # hermetic dev shell does not need to fetch/build the (large, Rust)
    # SpacetimeDB tree just to compile and test Phases 1–4.
  };

  outputs = { self, nixpkgs, flake-utils }:
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
      in {
        packages.default = hs-spacetime;
        devShells.dev = dev;
        devShells.default = dev;
      });
}
