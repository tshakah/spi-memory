{
  description = "w25q";
  inputs = {
    advisory-db = {
      url = "github:rustsec/advisory-db";
      flake = false;
    };

    crane = {
      url = "github:ipetkov/crane";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    devshell = {
      url = "github:numtide/devshell";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    pre-commit-hooks = {
      url = "github:cachix/pre-commit-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };
  };

  outputs = {
    self,
    advisory-db,
    devshell,
    crane,
    flake-utils,
    nixpkgs,
    pre-commit-hooks,
    rust-overlay,
  }:
    flake-utils.lib.eachDefaultSystem (localSystem: let
      pkgs = import nixpkgs {
        inherit localSystem;
        overlays = [
          devshell.overlays.default
          rust-overlay.overlays.default
        ];
      };
      inherit (pkgs) lib;

      projectName = "w25q";

      # We use rust-overlay to get a compatible stable toolchain for our host system
      # that can compile for the correct target
      rustToolchain = pkgs.pkgsBuildHost.rust-bin.nightly.latest.default.override {
        targets = ["thumbv7em-none-eabihf" "thumbv7m-none-eabi"];
        extensions = ["llvm-tools"];
      };

      # Use that toolchain to get a crane lib. Crane is used here to write the
      # nix packages that compile and test our rust code.
      craneLib = (crane.mkLib pkgs).overrideToolchain rustToolchain;

      # Our rust related sources.
      # - filterCargoSources will filter out anything not rust-related
      src = lib.cleanSourceWith {
        src = ./.;
        filter = path: type: (craneLib.filterCargoSources path type);
      };

      # For each of the classical cargo "functions" like build, doc, test, ...,
      # crane exposes a function that takes some configuration arguments.
      # Common settings that we need for all of these are grouped here.
      commonArgs = {
        inherit src;
        strictDeps = true;

        # External packages required to compile this project.
        # For normal rust applications this would contain runtime dependencies,
        # but since we are compiling for a foreign platform this is most likely
        # going to stay empty except for the linker.
        buildInputs =
          [
            pkgs.flip-link
            pkgs.cargo-outdated
            pkgs.cargo-binutils
          ]
          ++ lib.optionals pkgs.stdenv.isDarwin [
            # Additional darwin specific inputs can be set here
            pkgs.libiconv
          ];

        # BUG:: This should not be disabled, but some dependencies try to compile against
        # the test crate when it isn't available...
        # Needs further investigation.
        doCheck = false;
      };

      # Build *just* the cargo dependencies, so we can reuse
      # all of that work (e.g. via cachix) when running in CI
      cargoArtifacts = craneLib.buildDepsOnly commonArgs;

      individualCrateArgs =
        commonArgs
        // {
          inherit cargoArtifacts;
          inherit (craneLib.crateNameFromCargoToml {inherit src;}) version;
          # NB: we disable tests since we'll run them all via cargo-nextest
          doCheck = false;
        };

      fileSetForCrate = lib.fileset.toSource {
        root = ./.;
        fileset = lib.fileset.unions [
          ./Cargo.toml
          ./Cargo.lock
          ./src
        ];
      };

      w25q = craneLib.buildPackage (individualCrateArgs
        // {
          pname = "w25q";
          src = fileSetForCrate;
        });
    in {
      # Define checks that can be run with `nix flake check`
      checks =
        {
          inherit w25q;

          # Run clippy (and deny all warnings) on the crate source,
          # again, resuing the dependency artifacts from above.
          #
          # Note that this is done as a separate derivation so that
          # we can block the CI if there are issues here, but not
          # prevent downstream consumers from building our crate by itself.
          "${projectName}-clippy" = craneLib.cargoClippy (commonArgs
            // {
              inherit cargoArtifacts;
              cargoClippyExtraArgs = "-- --deny warnings --no-deps";
            });

          #"${projectName}-doc" = craneLib.cargoDoc (commonArgs
          #  // {
          #    inherit cargoArtifacts;
          #  });

          # Check formatting
          "${projectName}-fmt" = craneLib.cargoFmt {
            inherit (commonArgs) src;
          };

          # Audit dependencies
          "${projectName}-audit" = craneLib.cargoAudit {
            inherit (commonArgs) src;
            inherit advisory-db;
          };
        }
        // {
          pre-commit = pre-commit-hooks.lib.${localSystem}.run {
            src = ./.;
            hooks = {
              alejandra.enable = true;
              #cargo-check.enable = true;
              rustfmt.enable = true;
              statix.enable = true;
            };
          };
        };

      packages = {
        inherit w25q;
      };

      # `nix develop`
      devShells.default = pkgs.devshell.mkShell {
        name = projectName;
        imports = [
          "${devshell}/extra/language/c.nix"
          "${devshell}/extra/language/rust.nix"
        ];

        language.rust.enableDefaultToolchain = false;

        commands = [
          {
            package = pkgs.alejandra;
            help = "Format nix code";
          }
          {
            package = pkgs.statix;
            help = "Lint nix code";
          }
          {
            package = pkgs.deadnix;
            help = "Find unused expressions in nix code";
          }
        ];

        devshell.startup.pre-commit.text = self.checks.${localSystem}.pre-commit.shellHook;
        packages = let
          # Do not expose rust's gcc: https://github.com/oxalica/rust-overlay/issues/70
          # Create a wrapper that only exposes $pkg/bin. This prevents pulling in
          # development deps, like python interpreter + $PYTHONPATH, when adding
          # packages to a nix-shell. This is especially important when packages
          # are combined from different nixpkgs versions.
          mkBinOnlyWrapper = pkg:
            pkgs.runCommand "${pkg.pname}-${pkg.version}-bin" {inherit (pkg) meta;} ''
              mkdir -p "$out/bin"
              for bin in "${lib.getBin pkg}/bin/"*; do
                  ln -s "$bin" "$out/bin/"
              done
            '';
        in
          commonArgs.buildInputs
          ++ (with pkgs; [
            (mkBinOnlyWrapper rustToolchain)
            probe-rs
            rust-analyzer
            usbutils
          ]);
      };

      formatter = pkgs.alejandra; # `nix fmt`
    });
}
