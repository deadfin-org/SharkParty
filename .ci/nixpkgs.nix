builtins.fetchTarball {
  # Match Deadfin's checked-in shell.nix. The hash makes this usable without
  # mutable channels or a machine-wide Nix configuration change.
  url = "https://github.com/NixOS/nixpkgs/archive/335f0738cb2fa9708f3f428e39d2eae975d1338d.tar.gz";
  sha256 = "sha256-THPEF2po0fsoH8gNtp+Ae0XFDJH3N/ol7xO3v6VMTJU=";
}
