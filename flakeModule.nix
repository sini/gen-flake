# flakeModule.nix — gen-flake's flake-parts ergonomics ("no manual threading").
#
# Exposed as `gen-flake.flakeModules.default`. A consumer writes, with NO manual
# compose/inject/realize threading:
#
#     imports = [ gen-flake.flakeModules.default ];
#     gen.tree = ./gen-modules;                       # a directory of gen definition modules
#     gen.extraModules.<host> = [ ./hardware.nix ];   # per-host platform/base modules
#     gen.terminals.<class> = <terminal>;             # extra class terminals (a `nixos` one defaults
#                                                     #   in from `gen.nixpkgs`); map others off
#                                                     #   `gen.realized.<class>`
#     gen.injectPerSystem = true;                     # ALSO inject the values into perSystem args
#
# and gets, from ONE `compose`:
#   * QUERY   — the resolved gen VALUES injected as consumer module args under `config.gen.inject`
#               names (default `genValues`) into the top-level flake module args, so any consumer
#               module reads `{ genValues, ... }: … genValues.hosts.<h>.addr …`. The same values are
#               ALSO injected into every `perSystem` arg IFF `gen.injectPerSystem` is set — opt-in, so
#               the default emits NO `perSystem` definition: the perSystem arg-scope stays clean (no
#               values a perSystem module never named), and the module stays robust against flake-parts
#               versions that force a `systems` declaration once any `perSystem` definition exists.
#   * SYSTEMS — `flake.nixosConfigurations = (realize { terminals; … }).nixos or { }`, the `nixos`
#               class realized per host from compose's `hosts` projection (each host's `nixos` class
#               deferredModules, with the resolved instance partial-applied as the `host` binding by
#               gen-bind's `wrapAll`). A host with no `nixos` content is not built (class-major); a
#               registry with no `nixos` class at all yields the empty `or { }`.
#   * TERMINALS — `gen.terminals` is the class-keyed registry `realize` consumes; `gen.realized` is the
#               full class-major result (`{ <class>.<host> = artifact; }`), so a consumer wires
#               non-nixos classes into their own flake outputs off `gen.realized.<class>`.
#
# This file is the FLAKE-PARTS / TERMINAL side of gen-flake. Unlike the pure core
# (lib/compose.nix, lib/inject.nix, lib/realize.nix) it legitimately uses nixpkgs `lib`
# (mkOption/types — supplied by the consumer's flake-parts eval) and closes over the `terminals`
# nixpkgs boundary. So ci/tests/purity.nix EXCLUDES it, for the same reason it excludes
# lib/terminals.nix.
#
# It is a FUNCTION of the constructed gen-flake lib (compose / injectArgs / realize / terminals),
# partially applied in flake.nix so `flakeModules.default` is a ready-to-`imports` module.
genFlake:
{
  config,
  lib,
  inputs,
  ...
}:
let
  inherit (lib) mkOption types;
  cfg = config.gen;

  # The ONE compose for this flake — driven by the consumer's `gen.tree`/`gen.modules`. Pure
  # (gen-merge's byte-mode evalModuleTree); reads only `tree`/`modules`/`specialArgs`, never any of
  # the injected/built config below, so it introduces no fixpoint cycle.
  composed = genFlake.compose {
    tree = cfg.tree;
    modules = cfg.modules;
    specialArgs = cfg.specialArgs;
  };

  # The effective terminal registry `realize` consumes: the consumer's `gen.terminals`, plus a default
  # `nixos` terminal wired to `gen.nixpkgs` UNLESS `gen.nixpkgs` is null or the consumer already
  # supplied their own `nixos` terminal (in which case theirs wins). A consumer replacing terminals
  # entirely (custom classes, `gen.nixpkgs = null`) gets exactly their registry — no default nixos.
  terminals =
    cfg.terminals
    // lib.optionalAttrs (cfg.nixpkgs != null && !(cfg.terminals ? nixos)) {
      nixos = genFlake.terminals.nixosSystem { nixpkgs = cfg.nixpkgs; };
    };

  # The class-major realize result (`{ <class>.<host> = artifact; }`). Reads only `composed`, the
  # terminals above, and per-host extras — never the injected/built config below, so no cycle. Shared
  # by the `gen.realized` handle and `flake.nixosConfigurations`.
  realized = genFlake.realize {
    inherit composed terminals;
    extraModules = cfg.extraModules;
  };
in
{
  options.gen = {
    tree = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        A directory of gen definition modules, composed once via gen-merge's `evalModuleTree`
        (loaded as a bare path list by the import-tree fork). `null` ⇒ no tree; use `modules`.
      '';
    };

    modules = mkOption {
      # `raw`, NOT `deferredModule`: these modules are fed to the PURE gen-merge engine, not to
      # nixpkgs. nixpkgs `deferredModule` coercion would wrap them in a nixpkgs-flavored module and
      # is a category error at the gen boundary; pass them through untouched.
      type = types.listOf types.raw;
      default = [ ];
      description = "Extra inline gen modules appended to the tree (fed to gen-merge, not nixpkgs).";
    };

    specialArgs = mkOption {
      type = types.attrsOf types.raw;
      default = { };
      description = "Extra module args merged over the threaded gen libs during `compose`.";
    };

    inject = mkOption {
      type = types.attrsOf types.raw;
      # The default REUSES `injectArgs` (the pure query surface): its `_module.args` attrset is
      # exactly `{ genValues = composed.values; }`. The flakeModule then spreads that same attrset
      # across the top-level (always) and perSystem (opt-in) arg scopes below.
      default = (genFlake.injectArgs composed)._module.args;
      defaultText = lib.literalExpression "{ genValues = <the resolved gen config values>; }";
      description = ''
        The resolved gen VALUES to inject as consumer module args, keyed by arg NAME. Defaults to
        `{ genValues = <the resolved config values>; }`; a consumer may rename the arg or add
        further derived values. The set is injected into the top-level flake module args, and — when
        `injectPerSystem` is set — every `perSystem` arg, so consumer modules read them as
        `{ genValues, ... }: …`.

        INVARIANT — do NOT project `schema` out of the injected values. `composed.values` includes
        the schema sub-tree, whose `values.schema.<kind>.options.*.type` are inert gen TYPE objects.
        This is invariant-SAFE here: the payload lands in `_module.args`, which nixpkgs does NOT
        type-walk. The failure this design avoids — nixpkgs walking a gen type embedded in an
        OPTIONS tree via `substSubModules`/`getSubOptions` — cannot occur for a plain `_module.args`
        value. `renderDocs` legitimately reads `values.schema.<kind>.options.*.type.name` (a
        string). A consumer that instead uses `values.schema.<kind>` AS AN OPTION `type` is doing
        the explicitly out-of-scope thing (non-goal §11) and owns that hazard.
      '';
    };

    injectPerSystem = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether to ALSO inject the resolved values (`inject`) into every `perSystem` arg, not just the
        top-level flake args. Default `false`: the module emits NO `perSystem` definition, keeping the
        perSystem arg-scope clean (no values a perSystem module never named) and the module robust
        against flake-parts versions that force a `systems` declaration once any `perSystem` definition
        exists. Set `true` when a `perSystem` module needs to read `genValues`.
      '';
    };

    nixpkgs = mkOption {
      type = types.nullOr types.raw;
      default = inputs.nixpkgs or null;
      defaultText = lib.literalExpression "inputs.nixpkgs or null";
      description = ''
        The nixpkgs used to BUILD the per-host NixOS systems (the default `nixos` terminal). Defaults
        to the consumer's own `inputs.nixpkgs`, so systems pin to the consumer's nixpkgs, not
        gen-flake's. `null` (or a consumer-supplied `terminals.nixos`) suppresses the default `nixos`
        terminal.
      '';
    };

    terminals = mkOption {
      # `raw`: each value is a terminal FUNCTION (the realize contract), fed to the pure fold — not a
      # nixpkgs module. A default `nixos` terminal is merged in from `nixpkgs` below unless overridden.
      type = types.attrsOf types.raw;
      default = { };
      description = ''
        The class-keyed terminal registry `realize` consumes: `{ <class> = <terminal>; }`. A default
        `nixos` terminal (`terminals.nixosSystem { nixpkgs = config.gen.nixpkgs; }`) is added unless
        `gen.nixpkgs` is null or this set already carries a `nixos` terminal. Read the realized
        artifacts back off `gen.realized.<class>` to wire non-nixos classes into flake outputs.
      '';
    };

    extraModules = mkOption {
      # `deferredModule` here IS correct: these are nixpkgs NixOS modules handed to
      # `nixpkgs.lib.nixosSystem`.
      type = types.attrsOf (types.listOf types.deferredModule);
      default = { };
      description = ''
        Per-host extra NixOS modules appended to each built system, e.g.
        `{ <host> = [ ./hardware.nix { system.stateVersion = "24.05"; } ]; }`.
      '';
    };

    composed = mkOption {
      type = types.raw;
      readOnly = true;
      internal = true;
      default = composed;
      defaultText = lib.literalExpression "compose { inherit (config.gen) tree modules specialArgs; }";
      description = "The single `compose` result (`values` / `aspects` / `hosts`). Internal read handle.";
    };

    realized = mkOption {
      type = types.raw;
      readOnly = true;
      internal = true;
      default = realized;
      defaultText = lib.literalExpression "realize { inherit composed terminals; extraModules = config.gen.extraModules; }";
      description = ''
        The full class-major realize result (`{ <class>.<host> = artifact; }`) over `gen.terminals`.
        `flake.nixosConfigurations` is `realized.nixos or { }`; a consumer maps any other class off
        `realized.<class>`. Internal read handle.
      '';
    };
  };

  config = {
    # QUERY — inject the resolved VALUES under the `inject` names into the top-level flake args
    # (always), and into every `perSystem` arg IFF opted in (default emits no `perSystem` definition,
    # keeping the perSystem arg-scope clean).
    _module.args = cfg.inject;
    perSystem = lib.mkIf cfg.injectPerSystem (_: {
      _module.args = cfg.inject;
    });

    # SYSTEMS — the `nixos` class of the realized registry. `or { }` because a consumer may replace
    # terminals entirely without a `nixos` class (e.g. `gen.nixpkgs = null` + custom terminals).
    flake.nixosConfigurations = realized.nixos or { };
  };
}
