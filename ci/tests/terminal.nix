# The TERMINAL half — `injectArgs` (PURE query surface) + `mkSystems` (nixpkgs boundary).
#
# `compose { tree = ./_fixtures/tree; }` resolves the fixture (a `host` kind with aspect membership +
# a `web` aspect whose `nixos` class is a `{ host, nodes, ... }` module). From that one compose:
#   * `injectArgs` packages the resolved VALUES as a `_module.args` query module (no nixpkgs, no type).
#   * `mkSystems` projects per-host class content through gen-bind's `wrapAll` into `nixosSystem`.
{ genFlake, nixpkgs, ... }:
let
  composed = genFlake.compose { tree = ./_fixtures/tree; };

  # --- injectArgs (PURE) ---
  injected = genFlake.injectArgs composed;

  # --- mkSystems (TERMINAL) ---
  # A minimal per-host base: a platform (so `nixosSystem` resolves) + a stateVersion. Kept trivial so
  # the fixture systems evaluate cheaply — reads target `.config.<option>`, not a store realisation.
  base = [
    {
      nixpkgs.hostPlatform = "x86_64-linux";
      system.stateVersion = "24.05";
    }
  ];

  systems = genFlake.mkSystems {
    inherit (composed) hostContent;
    inherit nixpkgs;
    extraModules = {
      igloo = base;
      iceberg = base;
    };
  };
in
{
  # AC1 — injectArgs sets ONLY _module.args, from resolved values, with no gen type crossing.
  flake.tests.terminal-inject = {
    test-sets-only-module-args = {
      expr = builtins.attrNames injected;
      expected = [ "_module" ];
    };
    # Injected values equal a direct compose.
    test-values-equal-compose = {
      expr = injected._module.args.genValues == composed.values;
      expected = true;
    };
    # The injected args are resolved DATA (a plain string), not a type object.
    test-injected-is-resolved-data = {
      expr = {
        addr = injected._module.args.genValues.hosts.igloo.addr;
        isString = builtins.isString injected._module.args.genValues.hosts.igloo.addr;
      };
      expected = {
        addr = "10.0.1.1";
        isString = true;
      };
    };
  };

  # AC2/AC3/AC4 — mkSystems builds per-host nixosSystems via wrapAll, with the cross-terminal
  # accessor wired, and they EVALUATE.
  flake.tests.terminal-systems = {
    test-returns-per-host = {
      expr = builtins.attrNames systems;
      expected = [
        "iceberg"
        "igloo"
      ];
    };

    # AC4 — the host system evaluates. `wrapAll` partial-applied the `host` binding into the `nixos`
    # class module, so `host.name` resolved to the projected instance's name.
    test-igloo-hostname-from-binding = {
      expr = systems.igloo.config.networking.hostName;
      expected = "igloo";
    };

    # AC3 — the cross-terminal `nodes` accessor is present in specialArgs and resolves: the class
    # module counted the fleet's nodes (colmena-style).
    test-igloo-reads-cross-terminal-nodes = {
      expr = builtins.elem "peers-2" systems.igloo.config.system.nixos.tags;
      expected = true;
    };

    # A host with empty aspect membership projects to empty class content and still evaluates.
    test-iceberg-empty-projection-evaluates = {
      expr = builtins.isString systems.iceberg.config.networking.hostName;
      expected = true;
    };
  };

  # The per-host projection shape compose now finalizes (the input mkSystems builds on).
  flake.tests.terminal-projection = {
    test-hostcontent-keys = {
      expr = builtins.attrNames composed.hostContent;
      expected = [
        "iceberg"
        "igloo"
      ];
    };
    # igloo's `web` membership projects the aspect's `nixos` class into a one-module list.
    test-igloo-nixos-class-count = {
      expr = builtins.length composed.hostContent.igloo.classes.nixos;
      expected = 1;
    };
    # The resolved instance is handed to the class module as the `host` binding.
    test-igloo-binding-is-resolved-instance = {
      expr = composed.hostContent.igloo.bindings.host.addr;
      expected = "10.0.1.1";
    };
    # iceberg (no membership) projects to empty class content.
    test-iceberg-empty-classes = {
      expr = composed.hostContent.iceberg.classes;
      expected = { };
    };
  };
}
