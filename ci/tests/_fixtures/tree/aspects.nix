# Fixture: a gen-aspects definition module — one aspect (`web`) with `nixos` class content.
#
# `mkAspectSchema { classes.nixos = {}; }` registers `nixos` as a per-class deferredModule option on
# every aspect instance; `mkAspectOption {}` declares `options.aspects` typed by that grammar WITHOUT
# needing the schema option (so this composes beside schema.nix with no `options.schema` collision).
# The `nixos` value is a deferredModule — inspectable (its `.imports` list) but NEVER forced by
# composition, so the class body crosses into the consumer's nixpkgs eval unevaluated (T6/T7).
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
    nixos = {
      services.nginx.enable = true;
    };
  };
}
