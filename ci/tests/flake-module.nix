# `flakeModules.default` — the flake-parts ergonomics, proven end-to-end by FIXTURE CONSUMERS.
#
# Each `evalFlakeModule` below is a real (in-tree) consumer flake-parts config that does exactly what
# a downstream user writes: `imports = [ gen-flake.flakeModules.default ]; gen.tree = ./…;`. Together
# they prove the v1 option surface:
#   * QUERY   — the resolved gen VALUES are injected as a `genValues` module arg; the consumer reads
#               `genValues.hosts.<h>.addr` in its own flake modules (no manual compose/inject). The
#               top-level injection is UNconditional; the perSystem injection is opt-in
#               (`gen.injectPerSystem`).
#   * SYSTEMS — `flake.nixosConfigurations.<host>` is the `nixos` class realized from `gen.terminals`
#               (a `nixos` terminal defaults in from `gen.nixpkgs`), and EVALUATES.
#   * TERMINALS — `gen.terminals` is the class-keyed registry `realize` consumes; `gen.realized` is the
#               full class-major result. A consumer maps non-nixos classes off `gen.realized`, and may
#               override the default `nixos` terminal.
#   * NO-SYSTEMS — with `gen.injectPerSystem` false (default) the module emits NO `perSystem`
#               definition, so a consumer that never declares `systems` still evaluates.
#   * INVARIANT — the gen TYPE (`values.schema.<kind>.options.*.type`) rides along as DATA inside
#               `genValues`, yet NEVER enters the consumer's OPTIONS tree; the system builds with no
#               `substSubModules`/`getSubOptions` throw, and `options ? schema` is false.
#
# The flakeModule is a FUNCTION of the gen-flake lib; we partially apply the same `genFlake` the CI
# threads in (`import ../../flakeModule.nix genFlake`), and evaluate each consumer with
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

  # A consumer flake-parts eval — `self.outPath` points at the fixtures dir, `nixpkgs` is threaded in.
  mkConsumer =
    module:
    flakeParts.lib.evalFlakeModule {
      inputs = {
        self = {
          outPath = toString ./_fixtures;
        };
        inherit nixpkgs;
      };
      moduleLocation = "gen-flake:ci/tests/flake-module.nix";
    } module;

  # ── data-class fixtures (inline gen modules) — reused for the custom-terminal case ──
  # A typed `host` kind + a registry with one instance carrying an `aspects` membership list.
  dataHostSchema =
    {
      config,
      genSchema,
      genMerge,
      ...
    }:
    {
      options.schema = genSchema.mkSchemaOption { };
      options.hosts = genSchema.mkInstanceRegistry config.schema.host { };
      config.schema.host = {
        options.addr = genMerge.mkOption { type = genMerge.types.str; };
        options.aspects = genMerge.mkOption {
          type = genMerge.types.listOf genMerge.types.str;
          default = [ ];
        };
      };
      config.hosts.depot = {
        addr = "10.0.9.1";
        aspects = [ "srv" ];
      };
    };

  # An aspect grammar declaring ONLY a `data` class; one aspect `srv` with a trivial `data` module.
  dataAspects =
    { genAspects, ... }:
    let
      aspectSchema = genAspects.mkAspectSchema { classes.data = { }; };
    in
    {
      options.aspects = aspectSchema.mkAspectOption { };
      config.aspects.srv.data = { ... }: { };
    };

  # The DATA terminal — a pure fixture reflecting the terminal contract as plain data (no nixpkgs).
  dataTerminal =
    {
      name,
      modules,
      nodes,
      ...
    }:
    {
      inherit name modules;
      peers = builtins.attrNames nodes;
    };

  # A marker `nixos` terminal — proves a consumer-provided terminal OVERRIDES the default nixosSystem
  # one (its output carries `marker`, which the real nixosSystem terminal never would).
  markerTerminal =
    { name, ... }:
    {
      inherit name;
      marker = "CONSUMER-TERMINAL";
    };

  # ── THE MAIN FIXTURE CONSUMER — a downstream flake-parts config. Declares NO `options.schema`; it
  #    only IMPORTS the flakeModule and READS injected values. `injectPerSystem` is left at its
  #    default (false), so the module emits no perSystem definition. ──
  consumer = mkConsumer (
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

      # A plain consumer flake output that surfaces queried values (proves the arg resolved), plus a
      # peek at the gen TYPE carried AS DATA inside `genValues` (schema was NOT stripped).
      flake.genFlakeQuery = {
        igloo-addr = genValues.hosts.igloo.addr;
        iceberg-role = genValues.hosts.iceberg.role;
        schemaTypeName = genValues.schema.host.options.addr.type.name;
        schemaTypeIsAttrs = builtins.isAttrs genValues.schema.host.options.addr.type;
      };
    }
  );
  cc = consumer.config;

  # ── NO-SYSTEMS CONSUMER — identical to the main consumer but declares NO `systems`. With
  #    injectPerSystem false (default) the module emits no perSystem definition, so this evaluates. ──
  noSystemsConsumer = mkConsumer (
    { genValues, ... }:
    {
      imports = [ flakeModule ];
      gen.tree = ./_fixtures/tree;
      gen.nixpkgs = nixpkgs;
      gen.extraModules.igloo = [ base ];
      flake.genFlakeQuery.igloo-addr = genValues.hosts.igloo.addr;
    }
  );
  ccNo = noSystemsConsumer.config;

  # ── injectPerSystem CONSUMER — opts in, so the resolved values ALSO ride the perSystem args. ──
  perSystemConsumer = mkConsumer (
    { ... }:
    {
      systems = [ "x86_64-linux" ];
      imports = [ flakeModule ];
      gen.tree = ./_fixtures/tree;
      gen.nixpkgs = nixpkgs;
      gen.injectPerSystem = true;
    }
  );
  ccPs = perSystemConsumer.config;

  # ── CUSTOM-TERMINAL CONSUMER — supplies its own `data` terminal over inline data-class modules, and
  #    sets `gen.nixpkgs = null` so NO default nixos terminal is added (terminals = { data } only). ──
  dataTerminalConsumer = mkConsumer (
    { ... }:
    {
      systems = [ "x86_64-linux" ];
      imports = [ flakeModule ];
      gen.modules = [
        dataHostSchema
        dataAspects
      ];
      gen.nixpkgs = null;
      gen.terminals.data = dataTerminal;
    }
  );
  ccData = dataTerminalConsumer.config;

  # ── OVERRIDE CONSUMER — provides its own `nixos` terminal; the default nixosSystem one must NOT be
  #    added (the consumer's marker terminal runs instead). ──
  overrideConsumer = mkConsumer (
    { ... }:
    {
      systems = [ "x86_64-linux" ];
      imports = [ flakeModule ];
      gen.tree = ./_fixtures/tree;
      gen.nixpkgs = nixpkgs;
      gen.terminals.nixos = markerTerminal;
    }
  );
  ccOverride = overrideConsumer.config;
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
    # aspects (empty projection), so it is NOT built.
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

    # `gen.realized` — the full class-major realize result is exposed as a read handle; the default
    # nixos terminal (from `gen.nixpkgs`) realized `igloo` under `nixos`.
    test-realized-handle-mirrors-nixosconfigs = {
      expr = builtins.attrNames cc.gen.realized.nixos;
      expected = [ "igloo" ];
    };

    # perSystem injection is OPT-IN: with `injectPerSystem` at its default (false), the module emits no
    # perSystem definition, so `genValues` is NOT among a system's perSystem args. `allSystems.<sys>` is
    # flake-parts' evaluated per-system config; `.allModuleArgs` is its surfaced `config._module.args`.
    test-persystem-not-injected-by-default = {
      expr = cc.allSystems."x86_64-linux".allModuleArgs ? genValues;
      expected = false;
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

    # NO-SYSTEMS — a consumer that never declares `systems` evaluates: the top-level inject resolved,
    # and the systems still built. This is the forced-`systems`-declaration trap, pinned closed.
    test-nosystems-top-level-inject-resolves = {
      expr = ccNo.flake.genFlakeQuery.igloo-addr;
      expected = "10.0.1.1";
    };
    test-nosystems-systems-still-built = {
      expr = builtins.attrNames ccNo.flake.nixosConfigurations;
      expected = [ "igloo" ];
    };

    # injectPerSystem=true — the resolved values DO ride the perSystem args (the opt-in half).
    test-persystem-injected-when-opted-in = {
      expr = ccPs.allSystems."x86_64-linux".allModuleArgs ? genValues;
      expected = true;
    };
    test-persystem-injected-value = {
      expr = ccPs.allSystems."x86_64-linux".allModuleArgs.genValues.hosts.igloo.addr;
      expected = "10.0.1.1";
    };

    # gen.terminals — a consumer-supplied `data` terminal realizes its class off `gen.realized`. With
    # `gen.nixpkgs = null` no default nixos terminal is added, so the registry is `{ data }` only.
    test-terminals-custom-data-realized = {
      expr = {
        classes = builtins.attrNames ccData.gen.realized;
        host = ccData.gen.realized.data.depot.name;
        peers = ccData.gen.realized.data.depot.peers;
      };
      expected = {
        classes = [ "data" ];
        host = "depot";
        peers = [ "depot" ];
      };
    };
    # …and with no nixos terminal in the registry, `flake.nixosConfigurations` is the empty `or {}`.
    test-terminals-no-nixos-empty-nixosconfigs = {
      expr = builtins.attrNames ccData.flake.nixosConfigurations;
      expected = [ ];
    };

    # gen.terminals — a consumer-provided `nixos` terminal OVERRIDES the default nixosSystem one (the
    # marker terminal ran; the real one would never produce a `marker` field).
    test-terminals-nixos-override = {
      expr = ccOverride.gen.realized.nixos.igloo.marker;
      expected = "CONSUMER-TERMINAL";
    };
  };
}
