{
  description = "A Nix-flake-based rust-crane development environment";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";

    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    pre-commit-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

    crane = {
      url = "github:ipetkov/crane";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      flake-parts,
      rust-overlay,
      pre-commit-hooks,
      crane,
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        pre-commit-hooks.flakeModule
      ];

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];

      perSystem =
        {
          config,
          self',
          inputs',
          pkgs,
          system,
          ...
        }:
        let
          inherit (builtins)
            attrValues
            elem
            ;
          inherit (pkgs.lib) getExe filterAttrs fileset;

          additionalPackages = attrValues (filterAttrs (key: value: (elem key [ ])) config.packages);

          rustToolchain =
            let
              inherit (builtins) pathExists;

              rust = pkgs.rust-bin;
            in
            if pathExists ./rust-toolchain.toml then
              rust.fromRustupToolchainFile ./rust-toolchain.toml
            else if pathExists ./rust-toolchain then
              rust.fromRustupToolchainFile ./rust-toolchain
            else
              rust.stable.latest.default.override {
                extensions = [
                  "rust-src"
                  "rustfmt"
                ];
              };
          craneLib = (crane.mkLib pkgs).overrideToolchain rustToolchain;

          inherit (craneLib)
            buildPackage
            cargoDoc
            cargoFmt
            cargoNextest
            ;

          src = fileset.toSource {
            root = ./.;
            fileset = fileset.unions [
              (craneLib.fileset.commonCargoSources ./.)
              # (fileset.fileFilter (file: any (ext: file.hasExt ext) ["md"]) ./.)
              # (fileset.maybeMissing ./images)
            ];
          };

          commonArgs = {
            inherit src;
            strictDeps = true;

            nativeBuildInputs = [
              pkgs.openssl
              pkgs.openssl.dev
              pkgs.pkg-config
            ];

            PKG_CONFIG_PATH = "${pkgs.openssl.dev}/lib/pkgconfig";
            OPENSSL_NO_VENDOR = 1;
          };

          cargoArtifacts = craneLib.buildDepsOnly commonArgs;

          individualCrateArgs = commonArgs // {
            inherit cargoArtifacts;
            inherit (craneLib.crateNameFromCargoToml { inherit src; }) version;
            # NB: we disable tests since we'll run them all via cargo-nextest
            doCheck = false;
          };

          workspace = buildPackage (commonArgs // { inherit cargoArtifacts; });

          rust-bin = buildPackage (
            individualCrateArgs
            // {
              pname = "rust-bin";
              cargoExtraArgs = "--bin=bin";
            }
          );

          onefetch = getExe pkgs.onefetch;
        in
        {
          _module.args.pkgs = import nixpkgs {
            inherit system;

            overlays = [ rust-overlay.overlays.default ];
          };

          pre-commit.settings.hooks = {
            cargo-check.enable = true;
            check-toml.enable = true;
            clippy.enable = true;
            nixfmt-rfc-style.enable = true;
            rustfmt.enable = true;
          };

          checks = {
            inherit workspace;

            my-workspace-doc = cargoDoc (
              commonArgs
              // {
                inherit cargoArtifacts;
              }
            );

            my-workspace-fmt = cargoFmt {
              inherit src;
            };

            my-workspace-nextest = cargoNextest (
              commonArgs
              // {
                inherit cargoArtifacts;
                partitions = 1;
                partitionType = "count";
                cargoNextestPartitionsExtraArgs = "--no-tests=pass";
              }
            );
          };

          devShells =
            let
              inherit (pkgs.rust.packages.stable.rustPlatform) rustLibSrc;
              inherit (config) pre-commit;
            in
            {
              default = craneLib.devShell {
                packages = [
                  pkgs.openssl
                  pkgs.pkg-config
                  pkgs.cargo-deny
                  pkgs.cargo-edit
                  pkgs.cargo-nextest
                  pkgs.cargo-watch
                  pkgs.rust-analyzer
                ]
                ++ additionalPackages;

                env = {
                  # Required by rust-analyzer
                  RUST_SRC_PATH = "${rustLibSrc}";
                };

                shellHook = ''
                  ${pre-commit.installationScript}
                  ${onefetch} --no-bots
                '';
              };

              ci = craneLib.devShell {
                packages = [
                  pkgs.openssl
                  pkgs.pkg-config
                  pkgs.cargo-nextest
                ];

                env = {
                  # Required by rust-analyzer
                  RUST_SRC_PATH = "${rustLibSrc}";
                  CARGO_TERM_COLOR = "always";
                };
              };
            };

          packages = {
            inherit
              workspace
              rust-bin
              ;

            default = workspace;
          };
        };
    };
}
