# gen-flake public API — the PURE composition boundary of the pure-gen module ecosystem.
#
# This file has deps, so it is a function of named VALUES (gen convention §8):
#   importTree : the import-tree fork's callable object — `(importTree.addPath dir).files` yields a
#                bare path list (nixpkgs-lib-free tree reader).
#   genMerge   : gen-merge.lib — the byte-mode `evalModuleTree` engine (the `lib.evalModules`
#                replacement) plus the structural types.
#   genSchema  : gen-schema.lib — the pure typed registry (definition modules declare
#                `config.schema.<kind>` and materialize instances via `mkInstanceRegistry`).
#   genAspects : gen-aspects.lib — the pure aspect grammar (`mkAspectSchema` / `flatten`; aspect
#                trees carry per-class `nixos`/… deferredModule content).
#   genTypes   : gen-types.lib — the leaf CHECKERS (threaded to the tree for completeness; gen-merge
#                already carries them via `genMerge.types`). Optional.
#   genPrelude : gen-prelude.lib — the pure utility base. Optional.
#
# The library is nixpkgs-lib-free (ci/tests/purity.nix): it drives gen-merge's engine, never
# `lib.evalModules`. nixpkgs is pulled ONLY in ci/ (the nix-unit harness).
{
  importTree,
  genMerge,
  genSchema,
  genAspects,
  genTypes ? { },
  genPrelude ? { },
}:
{
  inherit
    (import ./compose.nix {
      inherit
        importTree
        genMerge
        genSchema
        genAspects
        genTypes
        genPrelude
        ;
    })
    compose
    ;
}
