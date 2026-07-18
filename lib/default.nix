# gen-flake public API — the composition boundary of the pure-gen module ecosystem.
#
# Two halves:
#   * PURE core (`compose`, `injectArgs`, `realize`, `diff`) — nixpkgs-lib-free; drives gen-merge's
#     byte-mode `evalModuleTree`, never `lib.evalModules`. `compose` resolves a gen module tree to
#     VALUES + the flat aspect registry + a per-host build projection + the engine `provenance`
#     channel; `injectArgs` packages those VALUES as a query module; `realize` folds the projection
#     through a per-class terminal into class-major artifacts; `diff` compares two compose results by
#     value, located by provenance. gen TYPES never leave this pure eval.
#   * TERMINALS (`terminals`) — the ONE sanctioned nixpkgs boundary, isolated in ./terminals.nix,
#     where `nixpkgs.lib.nixosSystem` legitimately enters. Only resolved VALUES + unforced class
#     deferredModules cross into it.
#
# This file has deps, so it is a function of named VALUES (gen convention §8):
#   importTree : the import-tree fork's callable object — `(importTree.addPath dir).files` yields a
#                bare path list (nixpkgs-lib-free tree reader).
#   genMerge   : gen-merge.lib — the byte-mode `evalModuleTree` engine + structural types.
#   genSchema  : gen-schema.lib — the pure typed registry.
#   genAspects : gen-aspects.lib — the pure aspect grammar (`mkAspectSchema` / `flatten`).
#   genTypes   : gen-types.lib — the leaf CHECKERS. Optional.
#   genPrelude : gen-prelude.lib — the pure utility base. Optional.
#   genBind    : gen-bind.lib — `wrapAll` DI for the terminal. Threaded ONLY into ./terminals.nix.
#   nixpkgs    : the full nixpkgs, threaded ONLY into ./terminals.nix as the terminal's default (a
#                `terminals.nixosSystem` call may override it). Opaque here — never `lib.evalModules`'d;
#                the PURE core (compose/inject/realize) never receives it. Optional (default null) so
#                the standalone / query paths need no nixpkgs; only a nixos build requires one.
#   flakeParts : the flake-parts flake, threaded ONLY into ./terminals.nix as the `mkFlakeTerminal` crossing
#                (its sanctioned host boundary, like nixpkgs). Opaque here — never called; the PURE core never
#                receives it. Optional (default null); only a `mkFlakeTerminal` output build requires one.
#
# Purity is enforced by ci/tests/purity.nix: compose.nix + inject.nix + realize.nix + diff.nix are
# strictly nixpkgs-free; the wiring (this file, the flakes) may NAME `nixpkgs`/`genBind` but never CALL
# a module-system function; terminals.nix is the excluded terminal.
{
  importTree,
  genMerge,
  genSchema,
  genAspects,
  genTypes ? { },
  genPrelude ? { },
  genBind,
  nixpkgs ? null,
  flakeParts ? null,
}:
let
  composeLib = import ./compose.nix {
    inherit
      importTree
      genMerge
      genSchema
      genAspects
      genTypes
      genPrelude
      ;
  };

  injectLib = import ./inject.nix;

  realizeLib = import ./realize.nix;

  diffLib = import ./diff.nix;

  terminalsLib = import ./terminals.nix {
    inherit genBind nixpkgs flakeParts;
  };
in
{
  inherit (composeLib) compose;
  inherit (injectLib) injectArgs;
  inherit (realizeLib) realize;
  inherit (diffLib) diff;
  terminals = terminalsLib;
}
