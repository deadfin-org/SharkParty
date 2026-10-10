{ pkgs ? import (import ./nixpkgs.nix) {} }:

pkgs.mkShell {
  packages = with pkgs; [
    swiftformat
    swiftlint
  ];
}
