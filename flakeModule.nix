# flakeModule.nix — gen-flake's flake-parts ergonomics ("no manual threading").
#
# Exposed as `gen-flake.flakeModules.default`. A consumer writes, with NO manual
# compose/inject/mkSystems threading:
#
#     imports = [ gen-flake.flakeModules.default ];
#     gen.tree = ./gen-modules;                       # a directory of gen definition modules
#     gen.extraModules.<host> = [ ./hardware.nix ];   # per-host platform/base modules
#
# and gets, from ONE `compose`:
#   * QUERY   — the resolved gen VALUES injected as consumer module args under `config.gen.inject`
#               names (default `genValues`), into BOTH the top-level flake module args AND every
#               `perSystem` arg, so any consumer module reads `{ genValues, ... }: … genValues.hosts.<h>.addr …`.
#   * SYSTEMS — `flake.nixosConfigurations = mkSystems { … }`, built per host from compose's `hosts`
#               projection (each host's `nixos` class deferredModules, with the resolved instance
#               partial-applied as the `host` binding by gen-bind's `wrapAll`).
#
# This file is the FLAKE-PARTS / TERMINAL side of gen-flake. Unlike the pure core
# (lib/compose.nix, lib/inject.nix) it legitimately uses nixpkgs `lib` (mkOption/types — supplied by
# the consumer's flake-parts eval) and closes over `mkSystems` (the nixpkgs boundary). So
# ci/tests/purity.nix EXCLUDES it, for the same reason it excludes lib/systems.nix.
#
# It is a FUNCTION of the constructed gen-flake lib (compose / injectArgs / mkSystems), partially
# applied in flake.nix so `flakeModules.default` is a ready-to-`imports` module.
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
      # across both the top-level and perSystem arg scopes below.
      default = (genFlake.injectArgs composed)._module.args;
      defaultText = lib.literalExpression "{ genValues = <the resolved gen config values>; }";
      description = ''
        The resolved gen VALUES to inject as consumer module args, keyed by arg NAME. Defaults to
        `{ genValues = <the resolved config values>; }`; a consumer may rename the arg or add
        further derived values. The set is injected into BOTH the top-level flake module args and
        every `perSystem` arg, so consumer modules read them as `{ genValues, ... }: …`.

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

    nixpkgs = mkOption {
      type = types.nullOr types.raw;
      default = inputs.nixpkgs or null;
      defaultText = lib.literalExpression "inputs.nixpkgs or null";
      description = ''
        The nixpkgs used to BUILD the per-host NixOS systems (`mkSystems`). Defaults to the
        consumer's own `inputs.nixpkgs`, so systems pin to the consumer's nixpkgs, not gen-flake's.
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
  };

  config = {
    # QUERY — inject the resolved VALUES under the `inject` names, into BOTH arg scopes.
    _module.args = cfg.inject;
    perSystem = _: {
      _module.args = cfg.inject;
    };

    # SYSTEMS — build per-host NixOS systems from compose's per-host projection.
    flake.nixosConfigurations = genFlake.mkSystems {
      hostContent = composed.hosts;
      nixpkgs = cfg.nixpkgs;
      extraModules = cfg.extraModules;
    };
  };
}
