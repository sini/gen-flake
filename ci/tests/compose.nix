# `.lib.compose` — the pure composition entry point.
#
# `compose { tree = ./_fixtures/tree; }` loads the fixture gen tree (a schema kind + instances, and
# an aspect with `nixos` class content) purely via gen-merge's `evalModuleTree` and projects:
#   values       — a thin read of the resolved config (instances / id_hash / flattened surfaces).
#   classContent — the flattened aspect registry (genAspects.flatten): each entry carries its
#                  per-class deferredModule content (e.g. `.nixos`), the raw material T6/T7 inject
#                  into a consumer's nixpkgs eval.
{ genFlake, ... }:
let
  result = genFlake.compose { tree = ./_fixtures/tree; };
in
{
  flake.tests.compose = {
    # AC1 — resolved instance data reaches `values`.
    test-instance-addr-resolved = {
      expr = result.values.hosts.igloo.addr;
      expected = "10.0.1.1";
    };
    test-instance-default-applied = {
      expr = result.values.hosts.iceberg.role;
      expected = "worker";
    };
    # Each instance is stamped with a stable id_hash by the registry.
    test-instance-id-hash-present = {
      expr = builtins.isString result.values.hosts.igloo.id_hash;
      expected = true;
    };

    # AC1 — classContent carries at least one class deferredModule.
    test-classcontent-has-web-aspect = {
      expr = result.classContent ? web;
      expected = true;
    };
    test-aspect-name-resolved = {
      expr = result.classContent.web.name;
      expected = "web";
    };
    # `nixos` is a deferredModule: its `.imports` is a list, and reading it does NOT force the body.
    test-classcontent-nixos-is-deferred-module = {
      expr = builtins.isList result.classContent.web.nixos.imports;
      expected = true;
    };
  };

  # An empty compose (no tree, no modules) is well-formed: empty values, empty classContent.
  flake.tests.compose-empty = {
    test-empty-values = {
      expr = (genFlake.compose { }).values;
      expected = { };
    };
    test-empty-classcontent = {
      expr = (genFlake.compose { }).classContent;
      expected = { };
    };
  };
}
