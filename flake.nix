{
  description = "Hasala: Go server and conformance fixtures";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
  };

  outputs =
    {
      self,
      nixpkgs,
    }:
    let
      inherit (nixpkgs) lib;

      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = f: lib.genAttrs systems (system: f system nixpkgs.legacyPackages.${system});

      goFor = system: nixpkgs.legacyPackages.${system}.go_1_27;

      buildGoModuleFor = system: pkgs: pkgs.buildGoModule.override { go = goFor system; };
      goToolsFor =
        system: pkgs:
        let
          buildGoModule = buildGoModuleFor system pkgs;
        in
        [
          (pkgs.gopls.override { buildGoLatestModule = buildGoModule; })
          (pkgs.govulncheck.override { buildGoLatestModule = buildGoModule; })
          pkgs.golangci-lint
        ];

      xcodegenFor =
        pkgs:
        pkgs.stdenvNoCC.mkDerivation {
          pname = "xcodegen";
          version = "2.46.0";
          src = pkgs.fetchzip {
            url = "https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip";
            hash = "sha256-7NjCsInBjkOL1RqWSaWKGDJxp/gn71rmhTWG2ErHDqA=";
          };
          dontConfigure = true;
          dontBuild = true;
          dontFixup = true;
          installPhase = ''
            mkdir -p $out
            cp -R bin share $out/
          '';
          meta = {
            mainProgram = "xcodegen";
            platforms = lib.platforms.darwin;
            sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
          };
        };

      treefmtFor =
        system: pkgs:
        pkgs.treefmt.withConfig {
          runtimeInputs = [
            pkgs.nixfmt
            (goFor system)
          ];
          settings = {
            tree-root-file = "flake.nix";
            on-unmatched = "debug";
            formatter.nixfmt = {
              command = "nixfmt";
              includes = [ "*.nix" ];
            };
            formatter.gofmt = {
              command = "gofmt";
              options = [ "-w" ];
              includes = [ "*.go" ];
              excludes = [ "server/oracle/v1ref/*" ];
            };
          };
        };
    in
    {
      formatter = forAllSystems treefmtFor;

      packages = forAllSystems (
        system: pkgs:
        {
          hasalad = buildGoModuleFor system pkgs {
            pname = "hasalad";
            version = "0-unstable";
            src = ./server;
            vendorHash = "sha256-EJnxPJhAvGDTQuroF55AD0KG6RSEZ3oPxh3QOXnc2MA=";
            subPackages = [ "cmd/hasalad" ];
            ldflags = [ "-X main.version=${self.shortRev or self.dirtyShortRev or "dirty"}" ];
            env.CGO_ENABLED = "0";
            doCheck = false;
            meta.mainProgram = "hasalad";
          };
          postgresql = pkgs.postgresql_17;
          cloudflared =
            assert lib.versionAtLeast pkgs.cloudflared.version "2026.10.2";
            assert pkgs.cloudflared.go.outPath == (goFor system).outPath;
            pkgs.cloudflared;
          server = self.packages.${system}.hasalad;
          default = self.packages.${system}.hasalad;
        }
        // lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
          xcodegen = xcodegenFor pkgs;
        }
      );

      nixosModules.hasala = import ./infra/qa/nix/module.nix self;
      nixosModules.default = self.nixosModules.hasala;

      checks = forAllSystems (
        system: pkgs:
        {
          hasalad = self.packages.${system}.hasalad;
          ingress-lint = import ./infra/qa/nix/tests/ingress-lint.nix { inherit self nixpkgs pkgs; };
          ca-distrust = import ./infra/qa/nix/tests/ca-distrust.nix { inherit self nixpkgs pkgs; };
          ops-scripts = import ./infra/qa/nix/tests/ops-scripts.nix { inherit self nixpkgs pkgs; };
          formatting =
            pkgs.runCommand "hasala-formatting" { nativeBuildInputs = [ (treefmtFor system pkgs) ]; }
              ''
                cp -r ${self} src
                chmod -R u+w src
                cd src
                treefmt --ci
                touch $out
              '';
        }
        // lib.optionalAttrs (system == "x86_64-linux") {
          module-eval = import ./infra/qa/nix/tests/eval.nix { inherit self nixpkgs pkgs; };
          qa-vm = pkgs.testers.runNixOSTest (import ./infra/qa/nix/tests/vm.nix self);
        }
      );

      devShells = forAllSystems (
        system: pkgs: {
          default = pkgs.mkShellNoCC {
            packages = [
              (goFor system)
            ]
            ++ goToolsFor system pkgs
            ++ [
              pkgs.postgresql_17
              pkgs.bun
              pkgs.nodejs_22
              pkgs.sops
              pkgs.gh
              pkgs.nixfmt
              (treefmtFor system pkgs)
            ]
            ++ lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
              (xcodegenFor pkgs)
              pkgs.swiftlint
            ];
            env = {
              GOTOOLCHAIN = "local";
              CGO_ENABLED = "0";
            }
            // lib.optionalAttrs (system == "x86_64-linux") {
              LD_LIBRARY_PATH = lib.makeLibraryPath [ pkgs.stdenv.cc.cc.lib ];
            };
          };
        }
      );
    };
}
