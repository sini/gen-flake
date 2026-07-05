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

  # `composeAt ctx args` — the engine invocation + the SHARED result projection. `ctx` records HOW this
  # compose was reached, so a base compose and an override build the identical surface from one place:
  #   warmFrom       previous FULL engine result to warm-splice against (null ⇒ the engine's cold path;
  #                  gen-merge README §"Warm re-eval"). Threaded WHOLE — the engine's memo is its
  #                  `config`/`provenance`/`freeformConfig`/`freeformProv`, so a projection would not do.
  #   editedModules  the appended module LIST of a fired warm override (the engine flattens it itself —
  #                  the flattened count is not caller-computable, `imports` expansion is config-dependent).
  #   traced         attach the decision `trace` — override results carry it, a base compose does not.
  # Base compose = `composeAt { }`; `override` re-enters with the warm decision + `traced = true`.
  composeAt =
    {
      warmFrom ? null,
      editedModules ? [ ],
      traced ? false,
    }:
    # `args@` keeps the ORIGINAL caller args attrset in scope for `override`'s re-compose
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

      # `modules`/`specialArgs` are compose's to set; the warm knobs (`warmFrom`/`editedModules`) are
      # compose-owned too — only `override` supplies them. An engineArgs key colliding with any would be
      # silently overridden by the `//` below, so name the offender(s) and throw instead.
      engineArgsCollisions = builtins.filter (k: engineArgs ? ${k}) [
        "modules"
        "specialArgs"
        "warmFrom"
        "editedModules"
      ];
      _engineArgsCheck =
        if engineArgsCollisions != [ ] then
          throw "compose: engineArgs must not carry ${builtins.concatStringsSep ", " engineArgsCollisions} — compose owns these engine keys"
        else
          null;

      # The warm knobs reach the engine ONLY on a fired warm override (`warmFrom` non-null); a base
      # compose and a cold override pass neither ⇒ the engine's documented zero-behaviour-change default
      # (README §"Warm re-eval"). `editedModules` is the appended LIST, threaded whole (engine flattens).
      warmKnobs = if warmFrom == null then { } else { inherit warmFrom editedModules; };

      result = builtins.seq _engineArgsCheck (
        genMerge.evalModuleTree (
          engineArgs
          // {
            modules = treeModules ++ modules;
            specialArgs = genLibs // specialArgs;
          }
          // warmKnobs
        )
      );

      cfg = result.config;

      # The flat aspect registry (keyed by aspect path). Absent an `aspects` surface, empty.
      aspects = if cfg ? aspects then genAspects.flatten cfg.aspects else { };

      # ── the SHARED compose projection (values/aspects/hosts/provenance/override). Cold and warm build
      # this IDENTICAL shape from one place; only `trace` (below, override-only) differs by call site.
      projection = {
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

        # `override edits` → a fresh compose of the ORIGINAL args merged with `edits` (mergeComposeArgs).
        # WARM-FIRE condition (design spec §1) — SYNTACTIC on the edit KEYS: warm fires iff `edits`
        # carries ONLY `modules`. In that case mergeComposeArgs recomputes `orig.specialArgs // { }`,
        # `orig.engineArgs // { }`, and the tree/selectHosts REPLACE-when-present clause as
        # value-preserving no-ops (same keys, shared thunks), so the key check IS the proof that
        # everything but the module list is unchanged and the engine's warm splice is sound. The
        # captured `result` (this eval's FULL engine result — config/provenance/freeform memo) becomes
        # the warmFrom and `edits.modules` the appended list. Any other edit key ⇒ warmFrom stays null ⇒
        # cold (today's re-compose), stated in the trace. (A general `==` over specialArgs is not
        # decidable/safe in Nix and is explicitly not attempted.) Override results are `traced`; the
        # re-compose carries `override` again — chainable, and a chained warm threads THIS result as its
        # own warmFrom (the engine reuses its freeform memo directly).
        override =
          edits:
          let
            warmFires = builtins.attrNames edits == [ "modules" ];
          in
          composeAt (
            if warmFires then
              {
                warmFrom = result;
                editedModules = edits.modules;
                traced = true;
              }
            else
              { traced = true; }
          ) (mergeComposeArgs args edits);
      };

      # ── the memoization decision trace (design spec §4) — the engine's `warmDecision` projected
      # VERBATIM. Present ONLY on override results (`traced`); a base compose omits it. Laziness cost:
      # `mode` and `modules` are cheap (classification only); `reused` and `remerged` are
      # O(declared-locs) spine-forcing when read — they enumerate the loc partition, never leaf values
      # (gen-merge README §"Warm re-eval"). `mode = "cold"` (with a `reason`) when the fallback fired —
      # no warmFrom (non-modules edit) or the engine's own disabledModules refusal.
      trace =
        let
          d = result.warmDecision;
        in
        {
          inherit (d)
            mode
            reason
            reused
            remerged
            modules
            ;
        };
    in
    if traced then projection // { inherit trace; } else projection;

  # The public entry: a base compose — no warm context, no `trace`. `override` re-enters `composeAt`
  # with the warm decision + `traced = true`, so the warm path lands BEHIND the standing byte-for-byte
  # cold-parity oracle (warm ≡ cold on `values` AND `provenance`).
  compose = composeAt { };
in
{
  inherit compose;
}
