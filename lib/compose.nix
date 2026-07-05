# `compose` — the PURE composition entry point of gen-flake.
#
# Loads a gen module tree and resolves it PURELY via gen-merge's byte-mode `evalModuleTree` (the
# nixpkgs-free `lib.evalModules` replacement), then projects the result to what a consumer eval needs:
# resolved VALUES + the flat aspect registry + a per-host build projection + the engine `provenance`
# channel (VERBATIM — the per-loc record tree `lib.diff` locates its value diff over). No nixpkgs is
# touched here.
#
#   importTree : the import-tree fork's callable object. `(importTree.addPath dir).files` returns a
#                BARE PATH LIST; gen-merge imports each path leaf (path-leaf import, #20), so a tree
#                directory feeds `evalModuleTree` directly with no glue.
#   genMerge   : the merge engine — `evalModuleTree { modules; specialArgs; }`.
#   genSchema  : threaded into the tree so definition modules declare `config.schema.<kind>` and
#                materialize instances purely.
#   genAspects : threaded into the tree; `flatten` projects the resolved aspect tree to the flat
#                aspect registry.
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

  # `projectHosts` — the host-keyed reshape of the FLAT aspect registry. For each host instance,
  # gather the deferredModules of each class across the aspects the host declares membership in
  # (`host.aspects`). `selectHosts` names WHICH resolved attrset holds the host instances — a nested
  # registry layout (`fleet.hosts`) would otherwise project empty under a hardcoded `values.hosts`
  # read. Yields
  #   { <host> = { bindings = { host = <resolved instance>; }; classes = { <class> = [ <deferredModule> ]; }; }; }
  # `bindings` are the resolved VALUES a class module is partial-applied with at the terminal (via
  # gen-bind's `wrapAll`); `classes.<c>` is the ordered deferredModule list fed to that class's system.
  # PURE — no nixpkgs; the deferredModules stay unforced (opaque) until the terminal imports them.
  projectHosts =
    selectHosts: values: aspects:
    let
      hosts = selectHosts values;
      # `selectHosts` is caller-supplied; a non-attrset result would die inside `mapAttrs` as an
      # anonymous "expected a set" — name compose, the arg, and the contract instead.
      _hostsCheck =
        if builtins.isAttrs hosts then
          null
        else
          throw "compose: selectHosts must return an attrset of host instances ({ <host> = <instance>; }), got ${builtins.typeOf hosts}";
    in
    builtins.seq _hostsCheck (
      builtins.mapAttrs (
        _hostName: inst:
        let
          memberAspects = builtins.filter (a: aspects ? ${a}) (inst.aspects or [ ]);
          classNames = dedup (builtins.concatMap (a: classFieldsOf aspects.${a}) memberAspects);
          collectClass =
            class:
            builtins.concatMap (
              a:
              let
                entry = aspects.${a};
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
      ) hosts
    );

  # `mergeComposeArgs` — the merge law of the cold `override` handle. `override edits` re-invokes
  # `compose` with the ORIGINAL args merged with `edits` (an attrset of the SAME shape as compose
  # args), per clause:
  #   modules      APPENDED to the originals — new module defs join the existing ones (module-system
  #                natural). Retraction of an existing def is `mkForce` in an appended module, NOT
  #                list removal.
  #   specialArgs  shallow-merged over the originals (`orig // edit`) — an edited key wins, untouched
  #                keys survive.
  #   engineArgs   shallow-merged over the originals (`orig // edit`), same as specialArgs.
  #   tree         REPLACED when `edits` provides it, else the original is kept.
  #   selectHosts  REPLACED when `edits` provides it, else the original is kept.
  # `orig // edits` gives the tree/selectHosts REPLACE for free (the edit wins when present, the
  # original survives otherwise); the three explicit keys re-derive the APPEND / shallow-merge clauses.
  mergeComposeArgs =
    orig: edits:
    orig
    // edits
    // {
      modules = (orig.modules or [ ]) ++ (edits.modules or [ ]);
      specialArgs = (orig.specialArgs or { }) // (edits.specialArgs or { });
      engineArgs = (orig.engineArgs or { }) // (edits.engineArgs or { });
    };

  compose =
    # `args@` keeps the ORIGINAL caller args attrset in scope for `override`'s cold re-compose
    # (mergeComposeArgs reads them); the destructured formals below stay the working defaults.
    args@{
      # A directory of gen definition modules, loaded as a bare path list. `null` ⇒ no tree.
      tree ? null,
      # Extra inline modules, appended after the tree (own defs win at equal priority — nixpkgs order).
      modules ? [ ],
      # Extra module args, merged over the threaded gen libs.
      specialArgs ? { },
      # Threaded VERBATIM into gen-merge's `evalModuleTree` (e.g. `check = false` to disable the
      # unknown-key orphan check, `prefix` to nest). `modules`/`specialArgs` are OWNED by compose —
      # carrying either here THROWS (an explicit collision beats a silent override).
      engineArgs ? { },
      # `values → { <host> = instance; }` — names which resolved attrset holds the host instances.
      # Defaults to the flat `values.hosts`; a nested registry passes `selectHosts = v: v.fleet.hosts`.
      selectHosts ? (values: values.hosts or { }),
    }:
    let
      # `(importTree.addPath dir).files` is the fork's bare-path-list accessor (NOT `importTree dir`,
      # which yields a `{ imports = …; }` module). import-tree skips any `/_`-prefixed path, so an
      # `_fixtures`-style subtree is auto-excluded from a sibling test load but still loadable here.
      treeModules = if tree == null then [ ] else (importTree.addPath tree).files;

      # `modules`/`specialArgs` are compose's to set; an engineArgs key colliding with them would be
      # silently overridden by the `//` below, so name the offender(s) and throw instead.
      engineArgsCollisions = builtins.filter (k: engineArgs ? ${k}) [
        "modules"
        "specialArgs"
      ];
      _engineArgsCheck =
        if engineArgsCollisions != [ ] then
          throw "compose: engineArgs must not carry ${builtins.concatStringsSep ", " engineArgsCollisions} — compose owns these engine keys"
        else
          null;

      result = builtins.seq _engineArgsCheck (
        genMerge.evalModuleTree (
          engineArgs
          // {
            modules = treeModules ++ modules;
            specialArgs = genLibs // specialArgs;
          }
        )
      );

      cfg = result.config;

      # The flat aspect registry (keyed by aspect path). Absent an `aspects` surface, empty.
      aspects = if cfg ? aspects then genAspects.flatten cfg.aspects else { };
    in
    {
      # Resolved config VALUES — a thin read of the fixpoint config: instances, id_hash, resolved
      # refs, flattened surfaces. This is what a consumer eval injects into nixpkgs. gen TYPES stay
      # behind in this pure eval; only these values cross the boundary.
      values = cfg;

      # The FLAT aspect registry (keyed by aspect path): each entry carries its per-class
      # deferredModule fields (e.g. `.nixos`). The deferredModules are inspectable but unforced, so
      # class bodies cross into nixpkgs unevaluated. This is the flat QUERY surface (gen-graph /
      # gen-select queries over aspects); the per-host build shape is `hosts` below. Absent an
      # `aspects` surface, this is empty.
      inherit aspects;

      # The per-host build projection — a host-keyed reshape of the flat registry,
      # `{ <host> = { bindings; classes = { <class> = [ deferredModule ]; }; }; }`, driven by each
      # host's `aspects` membership. This is what the terminal builds: per host, `wrapAll`
      # partial-applies `bindings` into `classes.<class>` and hands the result to a system. PURE —
      # the deferredModules remain unforced until the terminal's nixpkgs eval imports them.
      hosts = projectHosts selectHosts cfg aspects;

      # The engine PROVENANCE channel, projected VERBATIM — gen-merge's always-on lazy per-loc record
      # tree, mirroring `values`'s loc structure (a declared record `{ defs; winners; priority;
      # defaulted; }` per declared-option loc, a reduced record per freeform loc). Costs nothing until
      # read; reading a declared record's fields discharges that loc's contributing defs to WHNF but
      # never forces the merged value (gen-merge README §Provenance). `lib.diff` locates its value diff
      # over this channel; the override cold-parity oracle folds its digest.
      provenance = result.provenance;

      # `override edits` → a fresh `compose` of the ORIGINAL args merged with `edits` (the merge law
      # in mergeComposeArgs). COLD: literally re-invoke `compose`, so the result carries `override`
      # again (chainable at every depth) and there is nothing to keep in sync — the re-eval IS the
      # result. A later memoized implementation swaps THIS body behind the same byte-for-byte contract.
      override = edits: compose (mergeComposeArgs args edits);
    };
in
{
  inherit compose;
}
