{ self, nixpkgs }:
rec {
  testTunnelId = "00000000-0000-4000-8000-000000000000";

  base = {
    nixpkgs.hostPlatform = "x86_64-linux";
    boot.loader.grub.enable = false;
    fileSystems."/" = {
      device = "/dev/vda";
      fsType = "ext4";
    };
    system.stateVersion = "26.05";
    services.hasala.enable = true;
  };

  evalSystem =
    extra:
    nixpkgs.lib.nixosSystem {
      modules = [
        self.nixosModules.hasala
        base
        extra
      ];
    };
}
