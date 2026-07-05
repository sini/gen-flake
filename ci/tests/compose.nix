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
}
