# The scripts behind the reusable workflows in .github/workflows (host-check,
# host-deploy, host-promote, update-nixpkgs, refresh-keys, bump-modules,
# cve-scan, kernel-series, nixos-release). A host repo's workflow runs the
# ones its own flake.lock pins:
#   nix run --inputs-from . nixos-modules#host-deploy -- --host <host> --sha <commit>
# so they move with the repo's nixos-modules lock, not with the workflow's
# pin. They use the runner's nix and git, so the checkout's credentials and
# Nix settings apply.
{ pkgs, lib }:
let
  script =
    name: runtimeInputs:
    pkgs.writeShellApplication {
      inherit name;
      # lib.sh has functions not every script calls.
      excludeShellChecks = [ "SC2329" ];
      runtimeInputs =
        with pkgs;
        [
          coreutils
          gawk
          gnugrep
          gnused
          jq
        ]
        ++ runtimeInputs;
      text = ''
        ${builtins.readFile ./lib.sh}
        ${builtins.readFile (./. + "/${name}.sh")}
      '';
    };
  update-nixpkgs = script "update-nixpkgs" [ pkgs.gh ];
  # The promoter (rollout/promoter): Python's standard library, read-only
  # kubectl, gh for check runs, and ssh-keygen for `git verify-commit`.
  host-promote = pkgs.writeShellApplication {
    name = "host-promote";
    runtimeInputs = with pkgs; [
      python3 # urllib with TLS, for Discord and Grafana
      kubectl
      gh
      openssh
    ];
    text = ''
      exec python3 ${../rollout/promoter}/promote.py "$@"
    '';
  };
  cve-evidence = script "cve-evidence" [ ];
in
{
  inherit update-nixpkgs cve-evidence host-promote;
  host-check = script "host-check" [ ];
  host-deploy = script "host-deploy" [ ];
  refresh-keys = script "refresh-keys" (
    with pkgs;
    [
      gh
      curl
      openssh
      diffutils
    ]
  );
  bump-modules = script "bump-modules" [ pkgs.gh ];
  cve-scan = script "cve-scan" (
    with pkgs;
    [
      gh
      curl
      vulnix
      python3Minimal # tomllib, to read the whitelist
      update-nixpkgs
      cve-evidence
    ]
  );
  kernel-series = script "kernel-series" [ pkgs.gh ];
  nixos-release = script "nixos-release" [ pkgs.gh ];
}
