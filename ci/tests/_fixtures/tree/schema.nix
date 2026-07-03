# Fixture: a gen-schema definition module — a typed `host` kind + a registry with two instances.
#
# Mirrors the minimal gen-schema instance pattern (gen-schema/ci/tests/derive-plain.nix): declare the
# schema option, extend it with a `host` kind, wrap the kind in a registry, and materialize instances.
# `compose` threads `genSchema`/`genMerge` in as module args (via evalModuleTree specialArgs) — PURE,
# no nixpkgs `lib`, no `mkOption` from nixpkgs. `config` is the fixpoint config (evalModuleTree
# exposes it to module functions), so `config.schema.host` is the self-referential kind.
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
    options.role = genMerge.mkOption {
      type = genMerge.types.str;
      default = "worker";
    };
  };

  config.hosts.igloo = {
    addr = "10.0.1.1";
    role = "web";
  };
  config.hosts.iceberg = {
    addr = "10.0.2.1";
  };
}
