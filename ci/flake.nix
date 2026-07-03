{
  # nixpkgs is the CI runner's dependency (nix-unit harness, treefmt) and supplies the `lib` the
  # purity test uses. The gen-flake library itself (../lib) is nixpkgs-lib-free — ci/tests/purity.nix
  # enforces this. The pure stack (gen-merge/gen-schema/gen-aspects/import-tree) is pinned to the same
  # revs as the root flake, with follows collapsing each lower lib to a single instance.
  inputs = {
    gen.url = "github:sini/gen";

    gen-prelude.url = "github:sini/gen-prelude/62c2500";
    gen-types.url = "github:sini/gen-types/887ad87";

    gen-merge.url = "github:sini/gen-merge/fa5d5cc";
    gen-merge.inputs.gen-prelude.follows = "gen-prelude";
    gen-merge.inputs.gen-types.follows = "gen-types";

    gen-schema.url = "github:sini/gen-schema/39d3d5d";
    gen-schema.inputs.gen-prelude.follows = "gen-prelude";
    gen-schema.inputs.gen-types.follows = "gen-types";
    gen-schema.inputs.gen-merge.follows = "gen-merge";

    gen-aspects.url = "github:sini/gen-aspects/64c3c25";
    gen-aspects.inputs.gen-prelude.follows = "gen-prelude";
    gen-aspects.inputs.gen-merge.follows = "gen-merge";
    gen-aspects.inputs.gen-schema.follows = "gen-schema";

    import-tree.url = "github:denful/import-tree/a164a12202f58eb67559bd33b5592f20660d9baf";

    nixpkgs.url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz";
  };

  outputs =
    inputs@{
      gen,
      gen-prelude,
      gen-types,
      gen-merge,
      gen-schema,
      gen-aspects,
      import-tree,
      ...
    }:
    let
      genFlake = import ../lib {
        importTree = import-tree;
        genMerge = gen-merge.lib;
        genSchema = gen-schema.lib;
        genAspects = gen-aspects.lib;
        genTypes = gen-types.lib;
        genPrelude = gen-prelude.lib;
      };
    in
    gen.lib.mkCi {
      inherit inputs;
      name = "gen-flake";
      testModules = ./tests;
      specialArgs = {
        inherit genFlake;
        genMerge = gen-merge.lib;
        genSchema = gen-schema.lib;
        genAspects = gen-aspects.lib;
      };
    };
}
