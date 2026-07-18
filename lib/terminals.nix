# `terminals` — the system-terminal constructor, and the ONE sanctioned nixpkgs boundary of gen-flake.
#
# `mkSystemTerminal { evaluator }` is GENERIC: it names no system class and touches no nixpkgs /
# nix-darwin. It performs the wrap contract and hands the wrapped modules to `evaluator` — the
# consumer-supplied `{ modules, specialArgs } -> system` builder (the `nixpkgs.lib.nixosSystem` /
# nix-darwin `lib.darwinSystem` SHAPE). System knowledge lives ENTIRELY on the consumer's side, in the
# evaluator it passes.
#
# EXTENSION RECIPE (why gen-flake never grows a system class): a new target — darwin, a droid image,
# any `{ modules, specialArgs } -> artifact` builder — is a new CONSUMER-SIDE evaluator handed to
# `mkSystemTerminal`. gen-flake does not change. The only place here that touches a real system builder
# is the `nixosSystem` sugar below, kept for the published v1.0.0 API; ci/tests/purity.nix carves out
# exactly that `nixpkgs.lib.nixosSystem` call.
#
# Deps (construction time):
#   genBind  : gen-bind.lib — `wrapAll { modules; bindings; }` partial-applies resolved bindings into
#              class module functions by inspecting their formals (`functionArgs`) — plain DI closures.
#              `.all` is the flat deferred-module list (wrapped modules ++ collision validators).
#   nixpkgs  : the full nixpkgs — used ONLY by the `nixosSystem` sugar (for `.lib.nixosSystem`).
#              Optional at construction (a caller may pass nixpkgs per terminal instead).
{
  genBind,
  nixpkgs ? null,
  flakeParts ? null,
}:
let
  defaultNixpkgs = nixpkgs;

  # mkSystemTerminal — the GENERIC system terminal. PURE: zero system names, zero nixpkgs/nix-darwin.
  #   1. `wrapAll` hands the class modules the merged `bindings` (e.g. `{ host = <instance> }`),
  #      partial-applying them as DI closures; `.all` is the flat module list (wrapped ++ validators).
  #   2. `evaluator` (the caller's `{ modules, specialArgs } -> system`) evaluates `wrapped.all ++
  #      extraModules`.
  #   3. `specialArgs.nodes` is the cross-host accessor (colmena-style): the realized class set, so a
  #      class module can read `nodes.<peer>.config.…`. LAZY — its spine is the class's host keys, so
  #      reading it forces no peer. When the host's projection carries an `osConfig` (host-owned
  #      user/home content), it is threaded into `specialArgs` too.
  #
  # `name` (the member's scope-node id) rides the terminal contract but is unused here (it addresses the
  # realized entry in `realize`, not the built system), so it is absorbed by `...`.
  mkSystemTerminal =
    { evaluator }:
    {
      modules,
      bindings,
      nodes,
      extraModules,
      ...
    }@terminalArgs:
    let
      wrapped = genBind.wrapAll {
        inherit modules bindings;
      };
    in
    evaluator {
      modules = wrapped.all ++ extraModules;
      specialArgs = {
        inherit nodes;
      }
      // (if terminalArgs ? osConfig then { inherit (terminalArgs) osConfig; } else { });
    };
in
{
  inherit mkSystemTerminal;

  # mkFlakeTerminal — the FLAKE-PARTS crossing, BESIDE `mkSystemTerminal` (a PURE ADDITION; the system
  # terminal is untouched). Where `mkSystemTerminal` crosses a class's modules to a single `{ modules;
  # specialArgs } -> system`, this crosses a flake-parts MODULE SET to the transposed flake outputs: it calls
  # `flake-parts.lib.evalFlakeModule` as a LIBRARY over `modules` with the consumer's `inputs` + `self`, and
  # returns `config.flake` (perSystem folded to per-system). flake-parts is the crossing here, threaded at
  # construction — the same posture `nixpkgs` holds for `nixosSystem` (and, like it, one of gen-flake's
  # sanctioned host boundaries, carved out by ci/tests/purity.nix). flake-parts reads `self.inputs`, so the
  # caller supplies a `self` carrying `.inputs`; `self` is injected into the eval's `inputs`. `flakeParts`
  # is optional at construction (a standalone/pure consumer needs none); forcing an output with it null throws
  # (LAZY — constructing the terminal never forces it, only building an output does), at the same altitude the
  # flake-parts eval itself requires the host. This is the thin slice; the full output-crossing re-scope
  # (per-family terminals + the `nixosConfigurations` hardcode in flakeModule/realize) is a later arc.
  mkFlakeTerminal =
    {
      inputs,
      self,
      modules,
      systems ? [ ],
    }:
    let
      fp =
        if flakeParts != null then
          flakeParts
        else
          throw "gen-flake terminals.mkFlakeTerminal: `flakeParts` is required (thread the flake-parts flake at construction).";
    in
    (fp.lib.evalFlakeModule
      {
        inputs = inputs // {
          inherit self;
        };
      }
      {
        imports = modules;
        inherit systems;
      }
    ).config.flake;

  # nixosSystem — compatibility SUGAR (the published v1.0.0 API): `mkSystemTerminal` instantiated with
  # `nixpkgs.lib.nixosSystem` as the evaluator. This is the lib's ONE remaining nixpkgs touch (the
  # ci/tests/purity.nix carve-out). Behavior is byte-identical to a direct `mkSystemTerminal { evaluator
  # = nixpkgs.lib.nixosSystem; }` — the terminal-nixos suite proves it. `nixpkgs` is optional at
  # construction (threaded default) and per terminal; forcing a built system with neither throws (a
  # nixos build REQUIRES nixpkgs, at the same altitude the build itself does — the throw stays lazy,
  # inside the evaluator, so constructing the terminal registry never forces it).
  nixosSystem =
    {
      nixpkgs ? defaultNixpkgs,
    }:
    let
      np =
        if nixpkgs != null then
          nixpkgs
        else
          throw "gen-flake terminals.nixosSystem: `nixpkgs` is required (pass the nixpkgs flake input, or thread one at construction).";
    in
    mkSystemTerminal { evaluator = np.lib.nixosSystem; };
}
