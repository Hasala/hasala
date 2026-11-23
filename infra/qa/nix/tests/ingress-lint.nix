{
  self,
  nixpkgs,
  pkgs,
}:
let
  t = import ./lib.nix { inherit self nixpkgs; };
  rendered =
    (t.evalSystem {
      services.hasala.tunnel = {
        enable = true;
        id = t.testTunnelId;
        credentialsFile = "/dev/null";
      };
    }).config.services.hasala.tunnel.renderedConfig;
in
pkgs.runCommand "hasala-ingress-lint"
  {
    nativeBuildInputs = [
      pkgs.yq-go
      self.packages.${pkgs.stdenv.hostPlatform.system}.cloudflared
    ];
    rendered = pkgs.writeText "cloudflared-hasala.yml" rendered;
  }
  ''
    export HOME="$TMPDIR"
    bash ${../../cloudflared/lint.sh} all "$rendered" ${../../cloudflared}
    touch "$out"
  ''
