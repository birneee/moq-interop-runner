{
  description = "moq-interop-runner devShell - bash, make, jq, openssl for the build/test scripts";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      perSystem =
        { pkgs, ... }:
        {
          devShells.default = pkgs.mkShell {
            # bashInteractive so SHELL := $(shell command -v bash) in the
            # Makefile resolves to a real bash (this repo's scripts and the
            # Makefile itself assume bash; there's no /bin/bash on NixOS).
            packages = with pkgs; [
              bashInteractive
              gnumake
              jq
              openssl
              git
              docker-compose
            ];
          };
        };
    };
}
