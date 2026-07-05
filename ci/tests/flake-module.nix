# `flakeModules.default` — the flake-parts ergonomics, proven end-to-end by a FIXTURE CONSUMER.
#
# This evaluates a real (in-tree) consumer flake-parts config that does exactly what a downstream
# user writes: `imports = [ gen-flake.flakeModules.default ]; gen.tree = ./…;`. From that ONE import
# it proves both halves of the value-injection invariant:
#   * QUERY   — the resolved gen VALUES are injected as a `genValues` module arg; the consumer reads
#               `genValues.hosts.<h>.addr` in its own flake modules (no manual compose/inject).
#   * SYSTEMS — `flake.nixosConfigurations.<host>` is realized (the `nixos` class) and EVALUATES.
#   * INVARIANT — the gen TYPE (`values.schema.<kind>.options.*.type`) rides along as DATA inside
#               `genValues`, yet NEVER enters the consumer's OPTIONS tree; the system builds with no
#               `substSubModules`/`getSubOptions` throw, and `options ? schema` is false.
#
# The flakeModule is a FUNCTION of the gen-flake lib; we partially apply the same `genFlake` the CI
# threads in (`import ../../flakeModule.nix genFlake`), and evaluate the consumer with
# `flakeParts.lib.evalFlakeModule` (nixpkgs `lib.evalModules` with `class = "flake"`).
{
  genFlake,
  flakeParts,
  nixpkgs,
  ...
}:
let
  flakeModule = import ../../flakeModule.nix genFlake;

  # A minimal per-host base so `nixosSystem` resolves cheaply (platform + stateVersion). Reads target
  # `.config.<option>`, never a store realisation.
  base = {
    nixpkgs.hostPlatform = "x86_64-linux";
    system.stateVersion = "24.05";
  };

  # THE FIXTURE CONSUMER — a downstream flake-parts config. Note it declares NO `options.schema`; it
  # only IMPORTS the flakeModule and READS injected values.
  consumer =
    flakeParts.lib.evalFlakeModule
      {
        inputs = {
          self = {
            outPath = toString ./_fixtures;
          };
          inherit nixpkgs;
        };
        moduleLocation = "gen-flake:ci/tests/flake-module.nix";
      }
      (
        # The consumer's own module: reads the injected `genValues` arg (the QUERY surface) and uses it.
        { genValues, ... }:
        {
          systems = [ "x86_64-linux" ];
          imports = [ flakeModule ];

          gen.tree = ./_fixtures/tree;
          gen.nixpkgs = nixpkgs;

          # QUERY → BUILD end-to-end: a queried injected value flows into a built system's config.
          gen.extraModules.igloo = [
            base
            { networking.domain = "role-${genValues.hosts.igloo.role}.local"; }
          ];

          # A plain consumer flake output that surfaces queried values (proves the arg resolved), plus
          # a peek at the gen TYPE carried AS DATA inside `genValues` (schema was NOT stripped).
          flake.genFlakeQuery = {
            igloo-addr = genValues.hosts.igloo.addr;
            iceberg-role = genValues.hosts.iceberg.role;
            schemaTypeName = genValues.schema.host.options.addr.type.name;
            schemaTypeIsAttrs = builtins.isAttrs genValues.schema.host.options.addr.type;
          };
        }
      );

  cc = consumer.config;
in
{
  flake.tests.flake-module = {
    # AC1/AC2 (query) — the injected `genValues` resolved inside the consumer's flake modules.
    test-query-injected-addr = {
      expr = cc.flake.genFlakeQuery.igloo-addr;
      expected = "10.0.1.1";
    };
    test-query-injected-default-applied = {
      expr = cc.flake.genFlakeQuery.iceberg-role;
      expected = "worker";
    };

    # AC2 (systems) — realize built per-host nixosConfigurations from the ONE compose. The output is
    # class-major and content-driven: only hosts with `nixos` content appear. `iceberg` declares no
    # aspects (empty projection), so it is NOT built (mkSystems iterated every host; realize does not).
    test-nixosconfig-hosts = {
      expr = builtins.attrNames cc.flake.nixosConfigurations;
      expected = [
        "igloo"
      ];
    };
    # The system EVALUATES: the `host` binding partial-applied through wrapAll resolved `host.name`.
    test-nixosconfig-hostname = {
      expr = cc.flake.nixosConfigurations.igloo.config.networking.hostName;
      expected = "igloo";
    };
    # END-TO-END: the queried injected value flowed into the built system's config.
    test-queried-value-in-built-system = {
      expr = cc.flake.nixosConfigurations.igloo.config.networking.domain;
      expected = "role-web.local";
    };
    # The cross-host `nodes` accessor is wired through realize (colmena-style): it is THIS class's
    # realized set. Only `igloo` is in the `nixos` class here (iceberg has no content), so `nodes`
    # holds one host.
    test-nixosconfig-cross-terminal-nodes = {
      expr = builtins.elem "peers-1" cc.flake.nixosConfigurations.igloo.config.system.nixos.tags;
      expected = true;
    };

    # AC3 (INVARIANT) — the gen TYPE rides along as DATA in `genValues` (schema NOT projected out),
    # AND the consumer's OPTIONS tree never embeds it: the system builds with no
    # substSubModules/getSubOptions throw, and no `schema` option leaked in.
    test-invariant-type-is-data-not-option = {
      expr = {
        # gen TYPE present as DATA inside the injected values (like `renderDocs` reading `.name`):
        genTypeCarriedAsData = cc.flake.genFlakeQuery.schemaTypeIsAttrs;
        genTypeName = cc.flake.genFlakeQuery.schemaTypeName;
        # …yet the consumer's nixos OPTIONS tree BUILT (forcing option merge / getSubOptions) with
        # no throw — the queried config is a plain resolved string:
        systemOptionsTreeBuilt = builtins.isString cc.flake.nixosConfigurations.igloo.config.networking.hostName;
        # …and the gen `schema` never became a consumer OPTION (not in the nixos options tree):
        noSchemaOptionInConsumerSystem = cc.flake.nixosConfigurations.igloo.options ? schema;
      };
      expected = {
        genTypeCarriedAsData = true;
        genTypeName = "string";
        systemOptionsTreeBuilt = true;
        noSchemaOptionInConsumerSystem = false;
      };
    };
  };
}
