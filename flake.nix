{
    description = "Signal bot";

    inputs = {
        nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
        flake-utils.url = "github:numtide/flake-utils";
    };

    outputs = { self, nixpkgs, flake-utils }:
        flake-utils.lib.eachDefaultSystem (system:
            let
                pkgs = import nixpkgs { inherit system; };
            in
            {
                devShells.default = pkgs.mkShell {
                    packages = with pkgs; [
                        zig_0_15
                        zls
                        signal-cli
                        sqlite
                    ];
                    shellHook = ''
                        if [ -n "$NIX_CFLAGS_COMPILE" ]; then
                            export NIX_CFLAGS_COMPILE="$(
                                printf '%s\n' "$NIX_CFLAGS_COMPILE" \
                                | tr ' ' '\n' \
                                | grep -v '^-fmacro-prefix-map=' \
                                | paste -sd' ' -
                            )"
                        fi
                    '';
                };
            });
}
