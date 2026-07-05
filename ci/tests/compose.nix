# `.lib.compose` — the pure composition entry point.
#
# `compose { tree = ./_fixtures/tree; }` loads the fixture gen tree (a schema kind + instances, and
# an aspect with `nixos` class content) purely via gen-merge's `evalModuleTree` and projects:
#   values  — a thin read of the resolved config (instances / id_hash / flattened surfaces).
#   aspects — the flattened aspect registry (genAspects.flatten): each entry carries its per-class
#             deferredModule content (e.g. `.nixos`), the raw material a consumer injects into its
#             nixpkgs eval. This is the flat QUERY surface.
#   hosts   — the per-host build projection driven by each host's `aspects` membership.
{ genFlake, ... }:
let
  result = genFlake.compose { tree = ./_fixtures/tree; };

  # A NESTED host registry: instances live at `fleet.hosts.<h>`, NOT the flat `hosts.<h>`. The
  # default `selectHosts` (`v: v.hosts or {}`) reads the wrong path and projects EMPTY — the trap
  # `selectHosts` exists to fix. `selectHosts = v: v.fleet.hosts` names the real location.
  nestedSchema =
    {
      config,
      genSchema,
      genMerge,
      ...
    }:
    {
      options.schema = genSchema.mkSchemaOption { };
      options.fleet.hosts = genSchema.mkInstanceRegistry config.schema.host { };
      config.schema.host = {
        options.addr = genMerge.mkOption { type = genMerge.types.str; };
        options.aspects = genMerge.mkOption {
          type = genMerge.types.listOf genMerge.types.str;
          default = [ ];
        };
      };
      config.fleet.hosts.node1 = {
        addr = "10.9.9.9";
        aspects = [ "web" ];
      };
    };

  # An aspect with a `nixos` class deferredModule, so the nested host's `web` membership projects a
  # one-module class list — proving the FULL projection shape flows from a nested registry.
  nestedAspect =
    { genAspects, ... }:
    let
      aspectSchema = genAspects.mkAspectSchema { classes.nixos = { }; };
    in
    {
      options.aspects = aspectSchema.mkAspectOption { };
      config.aspects.web.nixos =
        { host, ... }:
        {
          networking.hostName = host.name;
        };
    };

  nested = genFlake.compose {
    modules = [
      nestedSchema
      nestedAspect
    ];
    selectHosts = v: v.fleet.hosts;
  };

  # SAME nested modules, DEFAULT selectHosts (flat `v.hosts`, absent here) — the silent-empty trap.
  nestedDefault = genFlake.compose {
    modules = [
      nestedSchema
      nestedAspect
    ];
  };

  # ---- override fixture ----------------------------------------------------------------------------
  # A base compose whose args each `override` clause edits, one clause per test. The schema carries
  # TWO host registries (`hosts` / `spares`) so a `selectHosts` REPLACE re-projects; a top-level
  # `marker` reads specialArgs so a specialArgs shallow-merge is observable in `values`; the `web`
  # aspect gives projected hosts a `nixos` class.
  ovSchema =
    {
      config,
      genSchema,
      genMerge,
      ...
    }:
    {
      options.schema = genSchema.mkSchemaOption { };
      options.hosts = genSchema.mkInstanceRegistry config.schema.host { };
      options.spares = genSchema.mkInstanceRegistry config.schema.host { };
      options.marker = genMerge.mkOption {
        type = genMerge.types.str;
        default = "none";
      };
      config.schema.host = {
        options.addr = genMerge.mkOption { type = genMerge.types.str; };
        options.aspects = genMerge.mkOption {
          type = genMerge.types.listOf genMerge.types.str;
          default = [ ];
        };
      };
      config.hosts.n1 = {
        addr = "10.0.0.1";
        aspects = [ "web" ];
      };
      config.spares.s1 = {
        addr = "10.0.0.2";
        aspects = [ "web" ];
      };
    };

  ovAspect =
    { genAspects, ... }:
    let
      aspectSchema = genAspects.mkAspectSchema { classes.nixos = { }; };
    in
    {
      options.aspects = aspectSchema.mkAspectOption { };
      config.aspects.web.nixos =
        { host, ... }:
        {
          networking.hostName = host.name;
        };
    };

  # Reads two specialArgs and surfaces them at top-level `marker` — makes a specialArgs merge (the
  # edited key wins, the untouched key survives) observable in `values`.
  ovMarker =
    {
      markerArg ? "none",
      keepArg ? "none",
      ...
    }:
    {
      config.marker = "${markerArg}/${keepArg}";
    };

  # An appended module that mkForce's n1's addr — proves modules APPEND (the base def and this force
  # coexist; the force wins) and is the cold-parity tooth's edit.
  ovForceAddr =
    { genMerge, ... }:
    {
      config.hosts.n1.addr = genMerge.mkForce "10.9.9.9";
    };

  # Appended modules that add fresh instances — used by the chain test (modules APPEND, in order).
  ovAddN2 = {
    config.hosts.n2 = {
      addr = "10.0.0.20";
      aspects = [ ];
    };
  };
  ovAddN3 = {
    config.hosts.n3 = {
      addr = "10.0.0.30";
      aspects = [ ];
    };
  };

  ovBaseArgs = {
    modules = [
      ovSchema
      ovAspect
      ovMarker
    ];
    specialArgs = {
      markerArg = "m0";
      keepArg = "k0";
    };
  };
  ovBase = genFlake.compose ovBaseArgs;

  # Chain fixtures — e1 then e2, each editing a different clause (modules + specialArgs). The chained
  # result must byte-equal `compose` of the hand-merged args: modules APPENDED in order, specialArgs
  # shallow-merged left-to-right ({m0,k0} // {keepArg=k1} // {markerArg=m2} = {markerArg=m2,keepArg=k1}).
  ovE1 = {
    modules = [ ovAddN2 ];
    specialArgs = {
      keepArg = "k1";
    };
  };
  ovE2 = {
    modules = [ ovAddN3 ];
    specialArgs = {
      markerArg = "m2";
    };
  };
  ovChained = (ovBase.override ovE1).override ovE2;
  ovManualChain = genFlake.compose {
    modules = ovBaseArgs.modules ++ [
      ovAddN2
      ovAddN3
    ];
    specialArgs = {
      markerArg = "m2";
      keepArg = "k1";
    };
  };

  # Cold-parity fixtures — override with an mkForce edit vs `compose` of the hand-appended module list.
  ovColdOverride = ovBase.override { modules = [ ovForceAddr ]; };
  ovColdManual = genFlake.compose (
    ovBaseArgs // { modules = ovBaseArgs.modules ++ [ ovForceAddr ]; }
  );

  # `dropFns` — deep-replace every function in a value with `null`, so `toJSON` can cross the whole
  # resolved `values` (schema option type-checkers, aspect `nixos` deferredModules). Functions are
  # NULLED, not skipped, so a topology change (a key gained/lost, a function↔data flip) still moves
  # the byte output. This lets the cold-parity teeth compare the FULL resolved config, not a slice —
  # a corruption confined to the aspects registry or schema topology cannot slip past.
  dropFns =
    x:
    if builtins.isFunction x then
      null
    else if builtins.isList x then
      map dropFns x
    else if builtins.isAttrs x then
      builtins.mapAttrs (_: dropFns) x
    else
      x;
in
{
  flake.tests.compose = {
    # AC1 — resolved instance data reaches `values`.
    test-instance-addr-resolved = {
      expr = result.values.hosts.igloo.addr;
      expected = "10.0.1.1";
    };
    test-instance-default-applied = {
      expr = result.values.hosts.iceberg.role;
      expected = "worker";
    };
    # Each instance is stamped with a stable id_hash by the registry.
    test-instance-id-hash-present = {
      expr = builtins.isString result.values.hosts.igloo.id_hash;
      expected = true;
    };

    # AC1 — the flat aspect registry carries at least one class deferredModule.
    test-aspects-has-web = {
      expr = result.aspects ? web;
      expected = true;
    };
    test-aspect-name-resolved = {
      expr = result.aspects.web.name;
      expected = "web";
    };
    # `nixos` is a deferredModule: its `.imports` is a list, and reading it does NOT force the body.
    test-aspects-nixos-is-deferred-module = {
      expr = builtins.isList result.aspects.web.nixos.imports;
      expected = true;
    };
  };

  # An empty compose (no tree, no modules) is well-formed: empty values, empty aspects, empty hosts.
  flake.tests.compose-empty = {
    test-empty-values = {
      expr = (genFlake.compose { }).values;
      expected = { };
    };
    test-empty-aspects = {
      expr = (genFlake.compose { }).aspects;
      expected = { };
    };
    test-empty-hosts = {
      expr = (genFlake.compose { }).hosts;
      expected = { };
    };
  };

  # `selectHosts` — which resolved attrset holds the host instances. Pins the nested-registry trap:
  # a `fleet.hosts` layout projects the SAME per-host shape a flat layout does, and the default read
  # projects EMPTY (silently), so a nested consumer MUST pass `selectHosts`.
  flake.tests.compose-select-hosts = {
    # selectHosts reads the nested registry — the host projects (non-empty), keyed by instance name.
    test-nested-hosts-keys = {
      expr = builtins.attrNames nested.hosts;
      expected = [ "node1" ];
    };
    # The projection shape flows: the host's `web` membership yields a one-module `nixos` class list.
    test-nested-host-class-count = {
      expr = builtins.length nested.hosts.node1.classes.nixos;
      expected = 1;
    };
    # The resolved instance is the `host` binding (resolved VALUE, a plain string, not a type).
    test-nested-host-binding = {
      expr = nested.hosts.node1.bindings.host.addr;
      expected = "10.9.9.9";
    };
    # THE TRAP — the default `selectHosts` reads flat `v.hosts`, absent in a nested layout → empty.
    test-nested-default-selecthosts-empty = {
      expr = nestedDefault.hosts;
      expected = { };
    };
    # A selector returning a non-attrset dies with a NAMED contract error (compose + selectHosts +
    # the required shape), not an anonymous "expected a set" from mapAttrs. (tryEval idiom — Nix
    # cannot introspect the message, so the guard is pinned by the throw itself.)
    test-nonattrset-selecthosts-throws = {
      expr =
        (builtins.tryEval (
          let
            h = (genFlake.compose { selectHosts = _: 42; }).hosts;
          in
          builtins.deepSeq h h
        )).success;
      expected = false;
    };
  };

  # `engineArgs` — threaded VERBATIM into gen-merge's `evalModuleTree`. `modules`/`specialArgs` are
  # compose's to set, so carrying either in engineArgs THROWS (an explicit collision beats a silent
  # override); a non-owned key (e.g. `check`) reaches the engine. Throw-tests use the ecosystem
  # `tryEval`/`deepSeq` idiom (Nix cannot introspect a `throw` message, so the guard is pinned by
  # WHICH keys throw vs pass, not by the message string).
  flake.tests.compose-engine-args = {
    # Collision: `modules` is compose-owned — carrying it in engineArgs throws.
    test-engineargs-modules-collision = {
      expr =
        (builtins.tryEval (
          let
            v = (genFlake.compose { engineArgs.modules = [ ]; }).values;
          in
          builtins.deepSeq v v
        )).success;
      expected = false;
    };
    # …the same guard covers `specialArgs`, the other compose-owned engine key.
    test-engineargs-specialargs-collision = {
      expr =
        (builtins.tryEval (
          let
            v = (genFlake.compose { engineArgs.specialArgs = { }; }).values;
          in
          builtins.deepSeq v v
        )).success;
      expected = false;
    };
    # Pass-through: a non-owned key (`check = false`) reaches the engine — an undeclared config key
    # (no freeform to absorb it) is DROPPED instead of throwing the orphan error, so `.values` is
    # empty and forcing it does NOT throw.
    test-engineargs-check-false-passthrough = {
      expr =
        (genFlake.compose {
          modules = [ { config.undeclaredKey = "x"; } ];
          engineArgs.check = false;
        }).values;
      expected = { };
    };
    # …and with `check` unset (default true) the SAME undeclared key throws the orphan error —
    # proving `check = false` above was load-bearing (the engine received it), not a freeform
    # silently absorbing the key.
    test-engineargs-check-default-throws = {
      expr =
        (builtins.tryEval (
          let
            v = (genFlake.compose { modules = [ { config.undeclaredKey = "x"; } ]; }).values;
          in
          builtins.deepSeq v v
        )).success;
      expected = false;
    };
  };

  # `override` — the cold re-compose handle. `composed.override edits` re-invokes `compose` with the
  # original args merged with `edits` per the merge law: modules APPEND, specialArgs/engineArgs
  # shallow-merge (edit wins), tree/selectHosts REPLACE. Cold = literally re-run compose, so the
  # result carries `override` again (chainable). The cold-parity tooth (`override` ≡ `compose` of the
  # hand-merged args, byte-equal) is the STANDING gate a later memoized `override` must still pass.
  flake.tests.compose-override = {
    # Baseline: no override — the base n1 addr stands.
    test-base-addr = {
      expr = ovBase.values.hosts.n1.addr;
      expected = "10.0.0.1";
    };
    # modules APPEND — the base def and an appended mkForce coexist; the force wins. (Removal would
    # drop the base/schema defs and break eval, so a resolved forced value proves APPEND, not REPLACE.)
    test-modules-append-force-wins = {
      expr = (ovBase.override { modules = [ ovForceAddr ]; }).values.hosts.n1.addr;
      expected = "10.9.9.9";
    };
    # specialArgs shallow-merge — the edited key (`markerArg`) wins, the untouched key (`keepArg`)
    # survives: `{m0,k0} // {markerArg=m1}` = `{markerArg=m1, keepArg=k0}` → marker "m1/k0".
    test-specialargs-shallow-merge = {
      expr =
        (ovBase.override {
          specialArgs = {
            markerArg = "m1";
          };
        }).values.marker;
      expected = "m1/k0";
    };
    # engineArgs shallow-merge — a base with default `check` (true) throws on an undeclared key; an
    # override setting `check = false` (edit wins) flips it, so `values` forces to empty, not a throw.
    test-engineargs-shallow-merge = {
      expr =
        ((genFlake.compose { modules = [ { config.undeclaredKey = "x"; } ]; }).override {
          engineArgs.check = false;
        }).values;
      expected = { };
    };
    # selectHosts REPLACE — an override selecting the OTHER registry (`spares`) re-projects the host
    # set (from `hosts`→`spares`), keyed by the spare instance name.
    test-selecthosts-replace = {
      expr = builtins.attrNames (ovBase.override { selectHosts = v: v.spares; }).hosts;
      expected = [ "s1" ];
    };
    # Baseline projection reads the default (`hosts`) registry.
    test-base-hosts-default = {
      expr = builtins.attrNames ovBase.hosts;
      expected = [ "n1" ];
    };
    # tree REPLACE — no second tree fixture exists, so a two-tree swap is not cheaply fixturable; the
    # REPLACE clause is the SAME `orig // edits` path `selectHosts` above exercises. This pins that
    # the `tree` clause flows through `override` by REPLACING a null tree with the fixture (null →
    # tree), after which the fixture's `hosts` surface appears in `values`.
    test-tree-replace = {
      expr = ((genFlake.compose { }).override { tree = ./_fixtures/tree; }).values ? hosts;
      expected = true;
    };
    # Chain — `(base.override e1).override e2` is byte-equal to `compose` of the hand-merged args
    # (modules APPENDED in order, specialArgs shallow-merged left-to-right). Compared over the FULL
    # resolved `values` with functions dropped to `null` (`dropFns`): `toJSON` cannot cross the
    # schema type-checkers / aspect `nixos` deferredModules, so they are nulled — but nulled (not
    # skipped) means any topology change still surfaces in the byte output.
    test-chain-equals-manual-merge = {
      expr = builtins.toJSON (dropFns ovChained.values);
      expected = builtins.toJSON (dropFns ovManualChain.values);
    };
    # COLD-PARITY TOOTH (standing gate) — `override`'s FULL resolved `values` are byte-equal to
    # `compose` of the hand-appended module list for an mkForce edit. A later memoized `override` must
    # still pass THIS. Compared over the whole `values` with functions dropped to `null` (`dropFns`),
    # so a corruption anywhere — instances, aspects registry, or schema topology — moves the bytes;
    # functions are nulled (not skipped) because `toJSON` cannot cross them.
    test-cold-parity-force = {
      expr = builtins.toJSON (dropFns ovColdOverride.values);
      expected = builtins.toJSON (dropFns ovColdManual.values);
    };
    # `override`'s result carries `override` AGAIN — the chainability shape (cold re-compose provides
    # it naturally at every depth).
    test-override-is-chainable = {
      expr = builtins.isFunction (ovBase.override { }).override;
      expected = true;
    };
  };
}
