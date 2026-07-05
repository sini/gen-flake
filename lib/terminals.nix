# `terminals` — the shipped terminal registry, and the ONE sanctioned nixpkgs boundary of gen-flake.
#
# This is the ONLY file in ./lib that touches nixpkgs (`nixpkgs.lib.nixosSystem`); ci/tests/purity.nix
# EXCLUDES it for exactly that reason (it replaces lib/systems.nix in that carve-out). `realize` (the
# pure fold) stays nixpkgs-free; the pure→nixpkgs crossing happens here and only here, consuming
# already-resolved VALUES + unforced class deferredModules.
#
# Deps (construction time):
#   genBind  : gen-bind.lib — `wrapAll { modules; bindings; }` partial-applies resolved bindings into
#              class module functions by inspecting their formals (`functionArgs`) — plain DI closures.
#              `.all` is the flat deferred-module list (wrapped modules ++ collision validators).
#   nixpkgs  : the full nixpkgs (for `.lib.nixosSystem`). Optional at construction (a caller may pass
#              nixpkgs per terminal instead); building a nixos system REQUIRES one.
{
  genBind,
  nixpkgs ? null,
}:
let
  defaultNixpkgs = nixpkgs;
in
{
  # `nixosSystem { nixpkgs ? <threaded default> } -> terminal`. The default nixos terminal: builds a
  # NixOS system from a host's `nixos` class deferredModules (the terminal contract in realize.nix).
  #   1. `wrapAll` hands those modules the merged `bindings` (e.g. `{ host = <instance> }`),
  #      partial-applying them as DI closures; `.all` is the flat module list for the system.
  #   2. `nixpkgs.lib.nixosSystem` evaluates `wrapped.all ++ extraModules`.
  #   3. `specialArgs.nodes` is the cross-host accessor (colmena-style): the realized `nixos` set, so
  #      a class module can read `nodes.<peer>.config.…`. LAZY — its spine is the class's host keys,
  #      so reading it forces no peer. When the host's projection carries an `osConfig` (host-owned
  #      user/home content), it is threaded into `specialArgs` too.
  #
  # `nixpkgs` is optional at construction (threaded default) and per terminal; forcing a built system
  # with neither throws — a nixos build REQUIRES nixpkgs, at the same altitude mkSystems required it.
  nixosSystem =
    {
      nixpkgs ? defaultNixpkgs,
    }:
    let
      np =
        if nixpkgs != null then
          nixpkgs
        else
          throw "gen-flake terminals.nixosSystem: `nixpkgs` is required (pass the nixpkgs flake input, or thread one at construction).";
    in
    {
      modules,
      bindings,
      nodes,
      extraModules,
      ...
    }@terminalArgs:
    let
      wrapped = genBind.wrapAll {
        inherit modules bindings;
      };
    in
    np.lib.nixosSystem {
      modules = wrapped.all ++ extraModules;
      specialArgs = {
        inherit nodes;
      }
      // (if terminalArgs ? osConfig then { inherit (terminalArgs) osConfig; } else { });
    };
}
