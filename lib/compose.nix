# `compose` — the PURE composition entry point of gen-flake.
#
# Loads a gen module tree and resolves it PURELY via gen-merge's byte-mode `evalModuleTree` (the
# nixpkgs-free `lib.evalModules` replacement), then projects the result to the two things a consumer
# eval needs: resolved VALUES + per-class deferredModule content. No nixpkgs is touched here.
#
#   importTree : the import-tree fork's callable object. `(importTree.addPath dir).files` returns a
#                BARE PATH LIST; gen-merge imports each path leaf (path-leaf import, #20), so a tree
#                directory feeds `evalModuleTree` directly with no glue.
#   genMerge   : the merge engine — `evalModuleTree { modules; specialArgs; }`.
#   genSchema  : threaded into the tree so definition modules declare `config.schema.<kind>` and
#                materialize instances purely.
#   genAspects : threaded into the tree; `flatten` projects the resolved aspect tree to class content.
#   genTypes / genPrelude : threaded for completeness (definition modules may reach for them).
{
  importTree,
  genMerge,
  genSchema,
  genAspects,
  genTypes ? { },
  genPrelude ? { },
}:
let
  # The gen constructors handed to EVERY module in the tree. evalModuleTree exposes `specialArgs` to
  # module functions by their static formals (so a `{ genSchema, ... }: …` module receives it), the
  # same way the demos thread these via `_module.args` — replicated purely here. `specialArgs` from
  # the caller is merged LAST so a caller can override or extend the arg set.
  genLibs = {
    inherit
      genMerge
      genSchema
      genAspects
      genTypes
      genPrelude
      ;
  };
in
{
  compose =
    {
      # A directory of gen definition modules, loaded as a bare path list. `null` ⇒ no tree.
      tree ? null,
      # Extra inline modules, appended after the tree (own defs win at equal priority — nixpkgs order).
      modules ? [ ],
      # Extra module args, merged over the threaded gen libs.
      specialArgs ? { },
    }:
    let
      # `(importTree.addPath dir).files` is the fork's bare-path-list accessor (NOT `importTree dir`,
      # which yields a `{ imports = …; }` module). import-tree skips any `/_`-prefixed path, so an
      # `_fixtures`-style subtree is auto-excluded from a sibling test load but still loadable here.
      treeModules = if tree == null then [ ] else (importTree.addPath tree).files;

      result = genMerge.evalModuleTree {
        modules = treeModules ++ modules;
        specialArgs = genLibs // specialArgs;
      };

      cfg = result.config;
    in
    {
      # Resolved config VALUES — a thin read of the fixpoint config: instances, id_hash, resolved
      # refs, flattened surfaces. This is what a consumer eval injects into nixpkgs (T6/T7). gen TYPES
      # stay behind in this pure eval; only these values cross the boundary.
      values = cfg;

      # Per-class deferredModule content: the flat aspect registry (keyed by aspect path), where each
      # entry carries its per-class deferredModule fields (e.g. `.nixos`). The deferredModules are
      # inspectable but unforced, so class bodies cross into nixpkgs unevaluated. The exact
      # `(class, host)` reshape is finalized downstream (T6/T8) against the real demos — kept minimal
      # here on purpose. Absent an `aspects` surface, this is empty.
      classContent = if cfg ? aspects then genAspects.flatten cfg.aspects else { };
    };
}
