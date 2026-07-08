{
  # Throwaway: a STOCK nixpkgs netboot node, to prove the QEMU harness + the
  # iPXE->HTTP->closure chain before our BC-250 kernel is involved.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  outputs = { self, nixpkgs }:
    let
      sys = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ({ modulesPath, ... }: {
            imports = [ "${modulesPath}/installer/netboot/netboot-minimal.nix" ];
            # Serial console so -nographic shows the whole boot.
            boot.kernelParams = [ "console=ttyS0" ];
            system.stateVersion = "24.11";
          })
        ];
      };
    in
    {
      packages.x86_64-linux = {
        kernel = sys.config.system.build.kernel;
        ramdisk = sys.config.system.build.netbootRamdisk;
        ipxe = sys.config.system.build.netbootIpxeScript;
      };
    };
}
