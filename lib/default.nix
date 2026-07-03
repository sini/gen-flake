# gen-flake public API — the composition boundary of the pure-gen module ecosystem.
#
# Two halves:
#   * PURE core (`compose`, `injectArgs`) — nixpkgs-lib-free; drives gen-merge's byte-mode
#     `evalModuleTree`, never `lib.evalModules`. `compose` resolves a gen module tree to VALUES +
#     per-host class content; `injectArgs` packages those VALUES as a query module. gen TYPES never
#     leave this pure eval.
#   * TERMINAL (`mkSystems`) — the ONE sanctioned nixpkgs boundary, isolated in ./systems.nix, where
#     `nixpkgs.lib.nixosSystem` legitimately enters. Only resolved VALUES + unforced class
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
#   genBind    : gen-bind.lib — `wrapAll` DI for the terminal. Threaded ONLY into ./systems.nix.
#   nixpkgs    : the full nixpkgs, threaded ONLY into ./systems.nix as the terminal's default (a
#                `mkSystems` call may override it). Opaque here — never `lib.evalModules`'d; the PURE
#                core (compose/inject) never receives it. Optional (default null) so the standalone /
#                query paths need no nixpkgs; only `mkSystems` requires one.
#
# Purity is enforced by ci/tests/purity.nix: compose.nix + inject.nix are strictly nixpkgs-free; the
# wiring (this file, the flakes) may NAME `nixpkgs`/`genBind` but never CALL a module-system function;
# systems.nix is the excluded terminal.
{
  importTree,
  genMerge,
  genSchema,
  genAspects,
  genTypes ? { },
  genPrelude ? { },
  genBind,
  nixpkgs ? null,
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

  systemsLib = import ./systems.nix {
    inherit genBind nixpkgs;
  };
in
{
  inherit (composeLib) compose;
  inherit (injectLib) injectArgs;
  inherit (systemsLib) mkSystems;
}
