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

  # The class fields of a flat-registry aspect entry: keys whose value is a deferredModule (an
  # attrset carrying an `imports` LIST). Structural — no hardcoded class-name list, so any class
  # registered via `mkAspectSchema { classes.<c> = {}; }` is discovered. Reading `? imports` on an
  # unforced deferredModule is cheap and does NOT force the class body.
  classFieldsOf =
    entry:
    builtins.filter (
      k:
      let
        v = entry.${k};
      in
      builtins.isAttrs v && v ? imports && builtins.isList v.imports
    ) (builtins.attrNames entry);

  # `dedup` — order-preserving unique over a string list, builtins-only (listToAttrs collapses dups).
  dedup =
    xs:
    builtins.attrNames (
      builtins.listToAttrs (
        map (x: {
          name = x;
          value = null;
        }) xs
      )
    );

  # `projectHosts` — the (class, host) reshape T5 deferred. Projects the FLAT aspect registry to
  # per-host class content: for each host instance, gather the deferredModules of each class across
  # the aspects the host declares membership in (`host.aspects`). Yields
  #   { <host> = { bindings = { host = <resolved instance>; }; classes = { <class> = [ <deferredModule> ]; }; }; }
  # `bindings` are the resolved VALUES a class module is partial-applied with at the terminal (via
  # gen-bind's `wrapAll`); `classes.<c>` is the ordered deferredModule list fed to that class's system.
  # PURE — no nixpkgs; the deferredModules stay unforced (opaque) until the terminal imports them.
  projectHosts =
    values: classContent:
    let
      hosts = values.hosts or { };
    in
    builtins.mapAttrs (
      _hostName: inst:
      let
        memberAspects = builtins.filter (a: classContent ? ${a}) (inst.aspects or [ ]);
        classNames = dedup (builtins.concatMap (a: classFieldsOf classContent.${a}) memberAspects);
        collectClass =
          class:
          builtins.concatMap (
            a:
            let
              entry = classContent.${a};
            in
            if builtins.elem class (classFieldsOf entry) then [ entry.${class} ] else [ ]
          ) memberAspects;
      in
      {
        bindings = {
          host = inst;
        };
        classes = builtins.listToAttrs (
          map (c: {
            name = c;
            value = collectClass c;
          }) classNames
        );
      }
    ) hosts;
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

      # The flat aspect registry (keyed by aspect path). Absent an `aspects` surface, empty.
      classContent = if cfg ? aspects then genAspects.flatten cfg.aspects else { };
    in
    {
      # Resolved config VALUES — a thin read of the fixpoint config: instances, id_hash, resolved
      # refs, flattened surfaces. This is what a consumer eval injects into nixpkgs (T6/T7). gen TYPES
      # stay behind in this pure eval; only these values cross the boundary.
      values = cfg;

      # Per-class deferredModule content: the flat aspect registry (keyed by aspect path), where each
      # entry carries its per-class deferredModule fields (e.g. `.nixos`). The deferredModules are
      # inspectable but unforced, so class bodies cross into nixpkgs unevaluated. This stays the flat
      # QUERY surface (gen-graph/gen-select queries over aspects); the per-host build shape is
      # `hostContent` below. Absent an `aspects` surface, this is empty.
      inherit classContent;

      # The (class, host) reshape T5 deferred, finalized here (T6). Host-keyed projection of the flat
      # registry — `{ <host> = { bindings; classes = { <class> = [ deferredModule ]; }; }; }` — driven
      # by each host's `aspects` membership. This is what the terminal (`mkSystems`) builds: per host,
      # `wrapAll` partial-applies `bindings` into `classes.<class>` and hands the result to a system.
      # PURE — the deferredModules remain unforced until the terminal's nixpkgs eval imports them.
      hostContent = projectHosts cfg classContent;
    };
}
