{
  description = "SSMP - Silksong Multiplayer Server";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    {
      self,
      nixpkgs,
    }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      pkgsFor = system: nixpkgs.legacyPackages.${system};
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          isDarwin = pkgs.stdenv.hostPlatform.isDarwin;

          ssmp-server = pkgs.buildDotnetModule {
            pname = "ssmp-server";
            version = "0.1.0";

            src = ./.;

            projectFile = "SSMPServer/SSMPServer.csproj";
            nugetDeps = ./deps.json;

            dotnet-sdk = pkgs.dotnetCorePackages.sdk_9_0;
            dotnet-runtime = pkgs.dotnetCorePackages.runtime_9_0;

            executables = [ "SSMPServer" ];

            postPatch = ''
              rm -f SSMP/packages.lock.json
              substituteInPlace SSMP/SSMP.csproj \
                --replace-fail '<RestorePackagesWithLockFile>true</RestorePackagesWithLockFile>' \
                               '<RestorePackagesWithLockFile>false</RestorePackagesWithLockFile>'
            '';

            # Normally dotnet publish includes all runtime deps and no postInstall
            # is needed (see e.g. tshock, scarab in nixpkgs). However, the Unity
            # stubs are reference-only assemblies that publish deliberately excludes.
            # SSMP loads them at runtime via reflection, so we must copy them manually
            # from the NuGet packages already fetched by deps.json.
            postInstall = ''
              local found=0
              for dep in $buildInputs; do
                if [[ -d "$dep/share/nuget/packages/unityengine.modules" ]]; then
                  find "$dep/share/nuget/packages/unityengine.modules" \
                    -path '*/netstandard2.0/UnityEngine*.dll' \
                    -exec cp {} "$out/lib/ssmp-server/" \;
                  found=1
                  break
                fi
              done
              (( found )) || { echo "ERROR: UnityEngine stubs not found in buildInputs"; exit 1; }
            '';

            meta = with pkgs.lib; {
              description = "Standalone multiplayer server for Hollow Knight: Silksong";
              homepage = "https://github.com/Extremelyd1/SSMP";
              license = licenses.lgpl21Plus;
              mainProgram = "SSMPServer";
            };
          };

          # Wrapper that copies server files to a writable directory.
          # The server writes TLS certs and config next to its assembly,
          # which fails in the read-only Nix store.
          ssmp-server-wrapped = pkgs.writeShellScriptBin "ssmp-server" (
            ''
              set -euo pipefail
              DEFAULT_DIR="''${XDG_DATA_HOME:-$HOME/.local/share}/ssmp-server"
              DATA_DIR="''${SSMP_DATA_DIR:-$DEFAULT_DIR}"
              STORE_LIB="${ssmp-server}/lib/ssmp-server"

              mkdir -p "$DATA_DIR"
            ''
            + pkgs.lib.optionalString isDarwin ''
              # macOS system ICU conflicts with the Nix-provided one, causing
              # missing symbol errors (e.g. u_charsToUChars). Invariant mode
              # makes .NET use built-in globalization instead of ICU.
              export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
            ''
            + ''
              # Sync store files into writable directory (runtime-created config/certs are untouched)
              ${pkgs.rsync}/bin/rsync -a --chmod=u+w "$STORE_LIB/" "$DATA_DIR/"

              cd "$DATA_DIR"
              exec ${ssmp-server.dotnet-runtime}/bin/dotnet "$DATA_DIR/SSMPServer.dll" "$@"
            ''
          );
        in
        {
          default = ssmp-server-wrapped;
        }
      );

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/ssmp-server";
        };
      });
    };
}
