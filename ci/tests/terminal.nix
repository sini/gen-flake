# The TERMINAL half — `realize` (the pure class-major fold), the shipped `terminals.nixosSystem`
# boundary, and `injectArgs` (the pure query surface).
#
# `realize { composed; terminals; bindings ? {}; extraModules ? {}; }` folds a compose result plus a
# per-class terminal into class-major artifacts `{ <class>.<host> = artifact; }`. The abstraction is
# proven two ways:
#   * a pure DATA terminal (a ci fixture, NOT shipped surface) that reflects the terminal contract as
#     plain data — this is what makes the shape / bindings-merge / nodes-laziness / osConfig / multi
#     class assertions expressible without nixpkgs; and
#   * the shipped `terminals.nixosSystem { nixpkgs; }` — the ONE sanctioned nixpkgs boundary — driven
#     through `realize` over the standard tree fixture (the mkSystems-parity path).
{
  genFlake,
  nixpkgs,
  genMerge,
  genSchema,
  genAspects,
  ...
}:
let
  # ── fixture builders (inline gen definition modules) ──────────────────────
  # A typed `host` kind + a registry of instances. Each instance carries an `aspects` membership list
  # (the terminal projects it against the flat aspect registry to build per-host class content).
  mkHostSchema =
    instances:
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
      config.hosts = instances;
    };

  # An aspect grammar declaring ONLY a `data` class (so an aspect never carries a class it does not
  # set). One aspect `srv` with a trivial `data` deferredModule (its body is never forced — the data
  # terminal reflects the module list opaquely).
  dataAspects =
    { genAspects, ... }:
    let
      aspectSchema = genAspects.mkAspectSchema { classes.data = { }; };
    in
    {
      options.aspects = aspectSchema.mkAspectOption { };
      config.aspects.srv.data = { ... }: { };
    };

  # An aspect grammar declaring BOTH `nixos` and `data`, with one aspect `both` that SETS both — the
  # multi-class case (a single aspect delivering two classes to a host).
  bothAspects =
    { genAspects, ... }:
    let
      aspectSchema = genAspects.mkAspectSchema {
        classes.nixos = { };
        classes.data = { };
      };
    in
    {
      options.aspects = aspectSchema.mkAspectOption { };
      config.aspects.both = {
        nixos = { ... }: { };
        data = { ... }: { };
      };
    };

  # ── terminals ─────────────────────────────────────────────────────────────
  # The DATA terminal — a pure ci FIXTURE (not a shipped surface). It reflects the pinned terminal
  # contract back as plain data so `realize`'s fold is fully assertable without nixpkgs. It reads
  # `nodes`'s KEYS only (the class spine), never a peer's value.
  dataTerminal =
    {
      name,
      modules,
      bindings,
      nodes,
      extraModules,
      ...
    }@args:
    {
      inherit
        name
        modules
        bindings
        extraModules
        ;
      peers = builtins.attrNames nodes;
      hasOsConfig = args ? osConfig;
      osConfig = args.osConfig or null;
    };

  # ── fixtures + realizations ────────────────────────────────────────────────
  # Shape: `srv` (data) on one host, none on the other → only the first realizes under `data`.
  composedShape = genFlake.compose {
    modules = [
      (mkHostSchema {
        alpha = {
          addr = "10.0.0.1";
          aspects = [ "srv" ];
        };
        bravo = {
          addr = "10.0.0.2";
        };
      })
      dataAspects
    ];
  };
  realizedShape = genFlake.realize {
    composed = composedShape;
    terminals.data = dataTerminal;
  };

  # Bindings: two `data` hosts. `base` uses the empty hook (composed's `{ host = <instance> }`
  # survives); `hook` overrides `host` globally for all and refines `host`/`extra` per-host for `y`.
  composedBind = genFlake.compose {
    modules = [
      (mkHostSchema {
        x = {
          addr = "10.0.1.1";
          aspects = [ "srv" ];
        };
        y = {
          addr = "10.0.1.2";
          aspects = [ "srv" ];
        };
      })
      dataAspects
    ];
  };
  realizedBindBase = genFlake.realize {
    composed = composedBind;
    terminals.data = dataTerminal;
  };
  realizedBindHook = genFlake.realize {
    composed = composedBind;
    terminals.data = dataTerminal;
    bindings = {
      host = "GLOBAL-HOST";
      extra = "global-extra";
      y = {
        host = "Y-HOST";
        extra = "y-extra";
      };
    };
  };

  # Laziness: two `data` hosts; the terminal THROWS for `frost`. Realizing `sun` reads the class
  # spine (its keys include `frost`) but must not force `frost`'s throwing artifact.
  composedLazy = genFlake.compose {
    modules = [
      (mkHostSchema {
        sun = {
          addr = "10.0.2.1";
          aspects = [ "srv" ];
        };
        frost = {
          addr = "10.0.2.2";
          aspects = [ "srv" ];
        };
      })
      dataAspects
    ];
  };
  lazyTerminal =
    { name, nodes, ... }:
    if name == "frost" then
      throw "gen-flake test: peer `frost` artifact forced"
    else
      {
        inherit name;
        peers = builtins.attrNames nodes;
      };
  realizedLazy = genFlake.realize {
    composed = composedLazy;
    terminals.data = lazyTerminal;
  };

  # osConfig pass-through: a hand-built projection (realize consumes only `.hosts`). One host carries
  # an `osConfig`, the other does not — the field rides the contract IFF the entry has it.
  composedOs = {
    hosts = {
      owned = {
        bindings.host = "owned-inst";
        classes.data = [ { imports = [ ]; } ];
        osConfig = {
          marker = "OWNER-CONFIG";
        };
      };
      plain = {
        bindings.host = "plain-inst";
        classes.data = [ { imports = [ ]; } ];
      };
    };
  };
  realizedOs = genFlake.realize {
    composed = composedOs;
    terminals.data = dataTerminal;
  };

  # Multi-class: one aspect delivering `nixos` + `data` to one host, realized by two terminals.
  composedMulti = genFlake.compose {
    modules = [
      (mkHostSchema {
        node = {
          addr = "10.0.3.1";
          aspects = [ "both" ];
        };
      })
      bothAspects
    ];
  };
  realizedMulti = genFlake.realize {
    composed = composedMulti;
    terminals = {
      nixos = dataTerminal;
      data = dataTerminal;
    };
  };

  # ── the shipped nixosSystem terminal, through realize (mkSystems-parity path) ──
  composedTree = genFlake.compose { tree = ./_fixtures/tree; };

  # A minimal per-host base so `nixosSystem` resolves cheaply (platform + stateVersion). Reads target
  # `.config.<option>`, never a store realisation.
  base = [
    {
      nixpkgs.hostPlatform = "x86_64-linux";
      system.stateVersion = "24.05";
    }
  ];

  realizedTree = genFlake.realize {
    composed = composedTree;
    terminals.nixos = genFlake.terminals.nixosSystem { inherit nixpkgs; };
    extraModules = {
      igloo = base;
    };
  };
  systems = realizedTree.nixos;

  # Same tree, a `nixpkgs = null` terminal — proves the missing-nixpkgs throw altitude (constructing
  # the registry is fine; only FORCING a built system throws, exactly as mkSystems required one).
  realizedNoNixpkgs = genFlake.realize {
    composed = composedTree;
    terminals.nixos = genFlake.terminals.nixosSystem { nixpkgs = null; };
  };

  # injectArgs (PURE query surface) — unchanged; packages resolved VALUES as `_module.args`.
  injected = genFlake.injectArgs composedTree;
in
{
  # ── realize: shape (class-major; host under a class IFF non-empty module list) ──
  flake.tests.realize-shape = {
    test-output-is-class-major = {
      expr = builtins.attrNames realizedShape;
      expected = [ "data" ];
    };
    # Only the host with `srv` (data) content realizes; the aspect-less host is absent under `data`.
    test-host-under-class-iff-nonempty = {
      expr = builtins.attrNames realizedShape.data;
      expected = [ "alpha" ];
    };
    test-empty-projection-host-absent = {
      expr = realizedShape.data ? bravo;
      expected = false;
    };
    # The data terminal received THIS class's module list (reflected opaquely).
    test-terminal-receives-class-modules = {
      expr = builtins.length realizedShape.data.alpha.modules;
      expected = 1;
    };
  };

  # ── realize: bindings merge order — `{ host = inst }` < global < `bindings.<host>` ──
  flake.tests.realize-bindings = {
    # Empty hook: composed's resolved instance IS the `host` binding (a plain-data instance).
    test-base-host-is-resolved-instance = {
      expr = {
        isAttrs = builtins.isAttrs realizedBindBase.data.x.bindings.host;
        addr = realizedBindBase.data.x.bindings.host.addr;
      };
      expected = {
        isAttrs = true;
        addr = "10.0.1.1";
      };
    };
    # Global layer beats the composed base (x has no per-host refinement), and adds a global key.
    test-global-beats-base = {
      expr = {
        host = realizedBindHook.data.x.bindings.host;
        extra = realizedBindHook.data.x.bindings.extra;
      };
      expected = {
        host = "GLOBAL-HOST";
        extra = "global-extra";
      };
    };
    # Per-host layer (`bindings.y`) beats the global layer (most specific wins).
    test-perhost-beats-global = {
      expr = {
        host = realizedBindHook.data.y.bindings.host;
        extra = realizedBindHook.data.y.bindings.extra;
      };
      expected = {
        host = "Y-HOST";
        extra = "y-extra";
      };
    };
  };

  # ── realize: nodes laziness — reading one host's artifact forces no peer artifact ──
  flake.tests.realize-nodes = {
    # `sun` reads the class spine (keys include the THROWING `frost`) and realizes fine.
    test-reads-spine-without-forcing-peer = {
      expr = realizedLazy.data.sun.peers;
      expected = [
        "frost"
        "sun"
      ];
    };
    # …and the peer genuinely throws when forced — so the success above is real laziness, not a peer
    # that happened to be cheap.
    test-peer-artifact-throws-when-forced = {
      expr =
        (builtins.tryEval (builtins.deepSeq realizedLazy.data.frost realizedLazy.data.frost)).success;
      expected = false;
    };
  };

  # ── realize: osConfig pass-through (present IFF the projection entry carries one) ──
  flake.tests.realize-osconfig = {
    test-osconfig-threaded-when-present = {
      expr = {
        hasOsConfig = realizedOs.data.owned.hasOsConfig;
        marker = realizedOs.data.owned.osConfig.marker;
      };
      expected = {
        hasOsConfig = true;
        marker = "OWNER-CONFIG";
      };
    };
    test-osconfig-absent-when-not-present = {
      expr = realizedOs.data.plain.hasOsConfig;
      expected = false;
    };
  };

  # ── realize: multi-class host → two artifacts, one per terminal ──
  flake.tests.realize-multi-class = {
    test-both-classes-realized = {
      expr = builtins.attrNames realizedMulti;
      expected = [
        "data"
        "nixos"
      ];
    };
    test-host-under-both-classes = {
      expr = {
        nixos = realizedMulti.nixos.node.name;
        data = realizedMulti.data.node.name;
      };
      expected = {
        nixos = "node";
        data = "node";
      };
    };
  };

  # ── the shipped nixosSystem terminal, through realize ──
  flake.tests.terminal-nixos = {
    # Class-major output: only hosts with `nixos` content realize (the aspect-less `iceberg` — empty
    # projection — is NOT built, unlike mkSystems which iterated every host).
    test-realizes-only-nixos-hosts = {
      expr = builtins.attrNames systems;
      expected = [ "igloo" ];
    };
    # The system EVALUATES: `wrapAll` partial-applied the `host` binding, so `host.name` resolved.
    test-hostname-from-binding = {
      expr = systems.igloo.config.networking.hostName;
      expected = "igloo";
    };
    # The cross-host `nodes` accessor is THIS class's realized set (colmena-style) — one host here,
    # since the empty-projection host is not part of the `nixos` class.
    test-cross-host-nodes-is-this-class = {
      expr = builtins.elem "peers-1" systems.igloo.config.system.nixos.tags;
      expected = true;
    };
    # Missing-nixpkgs throw altitude: FORCING a built system throws (a nixos build requires nixpkgs)…
    test-missing-nixpkgs-forcing-throws = {
      expr =
        (builtins.tryEval (
          let
            s = realizedNoNixpkgs.nixos.igloo;
          in
          builtins.seq s.config.networking.hostName s
        )).success;
      expected = false;
    };
    # …yet constructing the registry (reading the class spine) does NOT force nixpkgs.
    test-missing-nixpkgs-construction-ok = {
      expr = builtins.attrNames realizedNoNixpkgs.nixos;
      expected = [ "igloo" ];
    };
  };

  # ── injectArgs (PURE) — unchanged: sets ONLY `_module.args`, from resolved values ──
  flake.tests.terminal-inject = {
    test-sets-only-module-args = {
      expr = builtins.attrNames injected;
      expected = [ "_module" ];
    };
    test-values-equal-compose = {
      expr = injected._module.args.genValues == composedTree.values;
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
}
