{
  description = "Assam - Aggregator of lemons";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-23.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    { self
    , nixpkgs
    , flake-utils
    }:
    flake-utils.lib.eachDefaultSystem
      (system:
      let
        pkgs = nixpkgs.legacyPackages."${system}";
        selfPkgs = self.packages."${system}";
      in
      {
        devShells.default = pkgs.mkShell {
          name = "assam";

          inputsFrom = [ selfPkgs.assam ];
          packages = [ pkgs.zls ];
        };

        packages.default = selfPkgs.assam;
        packages.assam = pkgs.callPackage
          ({ stdenvNoCC
           , lib
           , zig
           , makeWrapper
           , bspwm
           , xtitle
           }:
            stdenvNoCC.mkDerivation {
              pname = "assam";
              version = "0.1.0";
              src = self;

              nativeBuildInputs = [ zig makeWrapper ];

              dontConfigure = true;

              installPhase = ''
                runHook preInstall
                zig build -Drelease-safe -Dcpu=baseline --prefix $out install
                runHook postInstall
              '';

              postInstall = ''
                wrapProgram $out/bin/assam \
                  --prefix PATH : ${lib.makeBinPath [ xtitle bspwm ]}
              '';
            })
          { };

      }
      );
}
