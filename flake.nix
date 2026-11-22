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

      # The QA host and the Apple-silicon Mac share one devShell.
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = f: lib.genAttrs systems (system: f system nixpkgs.legacyPackages.${system});

      # One Go for everything: the devShell, buildGoModule and gofmt. It must
      # stay at or above the `toolchain` line in server/go.mod, which
      # scripts/check.sh enforces.
      #
      # 26.05's go_1_27, not its default go, which is the 1.26 line and below
      # that floor.
      goFor = system: nixpkgs.legacyPackages.${system}.go_1_27;

      # 26.05's buildGoModule, driven by that Go. The server is built with it,
      # and so are gopls and govulncheck: 26.05 compiles them with Go 1.26, and
      # a tool built with an older go/types cannot load 1.27's standard library
      # (govulncheck fails outright on it). They are still 26.05's packages,
      # compiled locally rather than fetched from the cache. 26.05 already
      # builds golangci-lint with go_1_27, so it comes from the cache as is.
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

      # XcodeGen 2.46.0 exactly (spec 06 §1; ios/scripts/generate-project.sh says
      # why): 26.05 ships 2.44.1, whose projects build an app with no asset
      # catalog and no privacy manifest. nixpkgs builds XcodeGen from source with
      # its Swift 5.10 toolchain, and 2.46.0 needs XcodeProj 9.14.0, whose
      # manifest requires swift-tools-version 6.0; so this is the release's own macOS
      # binary (yonaskolb/XcodeGen, asset xcodegen.zip, upstream sha256
      # 4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806),
      # pinned by hash. Darwin only; the ios CI job runs it with `nix build`.
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
              # Byte-frozen v1 reference code (see its README): a formatter
              # must never be the thing that edits it.
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
          # Spec 02 §3.1 names it packages.<system>.hasalad; `server` is kept as
          # an alias for anything that still says .#server.
          hasalad = buildGoModuleFor system pkgs {
            pname = "hasalad";
            # Static on purpose: the go-modules fixed-output derivation is named
            # after it, so a per-commit version would re-fetch every module.
            version = "0-unstable";
            src = ./server;
            vendorHash = "sha256-EJnxPJhAvGDTQuroF55AD0KG6RSEZ3oPxh3QOXnc2MA=";
            subPackages = [ "cmd/hasalad" ];
            # `hasalad version` prints the commit (05 §4.2). ldflags do not reach
            # the go-modules derivation, so this does not re-fetch modules.
            ldflags = [ "-X main.version=${self.shortRev or self.dirtyShortRev or "dirty"}" ];
            env.CGO_ENABLED = "0";
            # Not stripped (no `-s -w`), on purpose: `govulncheck -mode=binary`
            # needs the symbol table to tell which packages are linked in. On a
            # stripped binary it falls back to whole-module matches and reports
            # x/crypto's unfixable, unused openpgp advisory (GO-2026-5932).
            # The test suite needs a Postgres cluster, bun and the conformance
            # fixtures outside server/; scripts/check.sh is the gate that runs it.
            doCheck = false;
            meta.mainProgram = "hasalad";
          };
          # 05 §4.2: the same PostgreSQL the devShell's test clusters use, so CI
          # and the QA host run one major and minor.
          postgresql = pkgs.postgresql_17;
          # 05 §4.2, R-09: nixos-26.05's cloudflared, built with the Go above.
          # It is the only internet-facing process on the QA host. The ingress
          # lint (infra/qa/cloudflared/lint.sh) and the host run this same
          # binary. Releases before 2026.10.2 trust eight eMudhra (emSign)
          # intermediates with weak private keys (Cloudflare advisory, 2026-10-20).
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

      # services.hasala, the QA backend (spec 05 §5): Hasala's own PostgreSQL,
      # `hasalad serve` and `hasalad console` on loopback, the tunnel, backups.
      nixosModules.hasala = import ./infra/qa/nix/module.nix self;
      nixosModules.default = self.nixosModules.hasala;

      checks = forAllSystems (
        system: pkgs:
        {
          hasalad = self.packages.${system}.hasalad;
          # Spec 05 §7.4: the module's rendered tunnel config against the golden
          # file (G1), the structural rules L1–L9, the routing table, and every
          # negative fixture rejected.
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
          # Spec 05 §14 AT-E*: the module's assertions fire on every misuse, and
          # the units carry exactly the environment and credentials the specs fix.
          module-eval = import ./infra/qa/nix/tests/eval.nix { inherit self nixpkgs pkgs; };
          # Spec 05 §14 AT-V*: boots the module in a VM. Needs KVM; CI runs it in
          # its own job (nixos-vm), and the gate job builds every other check.
          qa-vm = pkgs.testers.runNixOSTest (import ./infra/qa/nix/tests/vm.nix self);
        }
      );

      devShells = forAllSystems (
        system: pkgs: {
          # NoCC: on darwin the cc-wrapper stdenv exports SDKROOT/DEVELOPER_DIR
          # pointing into the Nix store, which breaks Xcode's own toolchain.
          # Nothing here needs cgo, so there is no C compiler on Linux either.
          default = pkgs.mkShellNoCC {
            packages = [
              (goFor system)
            ]
            ++ goToolsFor system pkgs
            ++ [
              pkgs.postgresql_17 # initdb/pg_ctl/postgres for internal/pgtest
              pkgs.bun
              # web/: wrangler (`bun run deploy`) is unreliable under Bun's
              # runtime; `bun run` starts its `#!/usr/bin/env node` bin with this.
              pkgs.nodejs_22
              pkgs.sops
              pkgs.gh
              pkgs.nixfmt
              (treefmtFor system pkgs)
              pkgs.gitleaks
              pkgs.shellcheck
              pkgs.jq
            ]
            ++ lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
              (xcodegenFor pkgs)
              pkgs.swiftlint
            ];
            env = {
              # Never let `go` fetch a different toolchain than the pinned one.
              GOTOOLCHAIN = "local";
              CGO_ENABLED = "0";
            }
            # web/'s `bun run build`: sharp's prebuilt libvips needs libstdc++,
            # which NixOS (the QA host) has nowhere on the default search path.
            # Linux only; the darwin shell is untouched.
            // lib.optionalAttrs (system == "x86_64-linux") {
              LD_LIBRARY_PATH = lib.makeLibraryPath [ pkgs.stdenv.cc.cc.lib ];
            };
            shellHook = ''
              bash ${./scripts/install-hooks.sh}
            '';
          };
        }
      );
    };
}
