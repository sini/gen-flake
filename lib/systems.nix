# `mkSystems` — the TERMINAL of gen-flake, and the ONE sanctioned nixpkgs boundary.
#
# This is the ONLY file in ./lib that touches nixpkgs (`nixpkgs.lib.nixosSystem`); ci/tests/purity.nix
# EXCLUDES it for exactly that reason. compose/inject stay nixpkgs-lib-free; the pure→nixpkgs crossing
# happens here and only here, consuming already-resolved VALUES + unforced class deferredModules.
#
# Deps (construction time):
#   genBind  : gen-bind.lib — `wrapAll { modules; bindings; }` partial-applies resolved bindings into
#              class module functions by inspecting their formals (`functionArgs`) — plain DI closures.
#              `.all` is the flat deferred-module list (wrapped modules ++ collision validators).
#   nixpkgs  : the full nixpkgs (for `.lib.nixosSystem` + the NixOS module set). Optional at
#              construction (a caller may instead pass it per-call); a `mkSystems` call REQUIRES one.
{
  genBind,
  nixpkgs ? null,
}:
let
  defaultNixpkgs = nixpkgs;
in
{
  # `mkSystems { hostContent, nixpkgs ? <threaded default>, extraModules ? {} } -> { <host> = <nixosSystem>; }`
  #
  # `hostContent` is compose's per-host projection (`{ <host> = { bindings; classes = { nixos = […]; … }; }; }`).
  # Per host it builds a NixOS system from the `nixos` class deferredModules:
  #   1. `wrapAll` hands those modules the host's resolved `bindings` (e.g. `{ host = <instance>; }`),
  #      partial-applying them as DI closures; `.all` is the flat module list for the system.
  #   2. `nixpkgs.lib.nixosSystem` evaluates `wrapped.all ++ (extraModules.<host> or [])`.
  #   3. `specialArgs.nodes` is the cross-terminal accessor (colmena-style): the whole set of built
  #      systems, so a class module can read `nodes.<peer>.config.…`. Self-referential but LAZY —
  #      the spine is `hostContent`'s keys, so reading it forces no peer's config on its own. When a
  #      host content carries an `osConfig` (user/home terminals: the owner host config), that is
  #      threaded too; host systems have none.
  mkSystems =
    {
      hostContent,
      nixpkgs ? defaultNixpkgs,
      extraModules ? { },
    }:
    let
      np =
        if nixpkgs != null then
          nixpkgs
        else
          throw "gen-flake mkSystems: `nixpkgs` is required (pass the nixpkgs flake input, or thread one at construction).";

      systems = builtins.listToAttrs (
        map (hostName: {
          name = hostName;
          value =
            let
              hc = hostContent.${hostName};
              classModules = hc.classes.nixos or [ ];

              wrapped = genBind.wrapAll {
                modules = classModules;
                bindings = hc.bindings or { };
              };
            in
            np.lib.nixosSystem {
              modules = wrapped.all ++ (extraModules.${hostName} or [ ]);
              specialArgs = {
                nodes = systems;
              }
              // (if hc ? osConfig then { inherit (hc) osConfig; } else { });
            };
        }) (builtins.attrNames hostContent)
      );
    in
    systems;
}
