# Fixture: a gen-aspects definition module — one aspect (`web`) with `nixos` class content.
#
# `mkAspectSchema { classes.nixos = {}; }` registers `nixos` as a per-class deferredModule option on
# every aspect instance; `mkAspectOption {}` declares `options.aspects` typed by that grammar WITHOUT
# needing the schema option (so this composes beside schema.nix with no `options.schema` collision).
#
# The `nixos` value is a deferredModule — inspectable (its `.imports` list) but NEVER forced by
# composition, so the class body crosses into the consumer's nixpkgs eval unevaluated (at the terminal).
# Here it is a FUNCTION module so the terminal can exercise the two injection styles:
#   * `host`  — a resolved-VALUE binding partial-applied by gen-bind's `wrapAll` at wrap time; and
#   * `nodes` — the cross-terminal accessor supplied by the system's `specialArgs` (colmena-style),
#               left as a remaining arg for the module system to fill during the nixpkgs eval.
{
  genAspects,
  genMerge,
  ...
}:
let
  aspectSchema = genAspects.mkAspectSchema {
    classes.nixos = { };
  };
in
{
  options.aspects = aspectSchema.mkAspectOption { };

  config.aspects.web = {
    tags = [
      "web"
      "frontend"
    ];
    nixos =
      {
        host,
        nodes,
        ...
      }:
      {
        networking.hostName = host.name;
        # Reads the cross-terminal `nodes` accessor — proves it resolves in the terminal eval.
        system.nixos.tags = [ "peers-${toString (builtins.length (builtins.attrNames nodes))}" ];
      };
  };
}
