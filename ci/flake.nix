{
  # nixpkgs is the CI runner's dependency (nix-unit harness, treefmt) and supplies the `lib` the
  # purity test uses. The gen-flake library itself (../lib) is nixpkgs-lib-free — ci/tests/purity.nix
  # enforces this. The pure stack (gen-merge/gen-schema/gen-aspects/import-tree) tracks the same
  # branches as the root flake, with follows collapsing each lower lib to a single instance.
  inputs = {
    gen.url = "github:sini/gen";

    gen-prelude.url = "github:sini/gen-prelude";
    gen-types.url = "github:sini/gen-types";

    gen-merge.url = "github:sini/gen-merge";
    gen-merge.inputs.gen-prelude.follows = "gen-prelude";
    gen-merge.inputs.gen-types.follows = "gen-types";

    gen-schema.url = "github:sini/gen-schema";
    gen-schema.inputs.gen-prelude.follows = "gen-prelude";
    gen-schema.inputs.gen-types.follows = "gen-types";
    gen-schema.inputs.gen-merge.follows = "gen-merge";

    gen-aspects.url = "github:sini/gen-aspects";
    gen-aspects.inputs.gen-prelude.follows = "gen-prelude";
    gen-aspects.inputs.gen-merge.follows = "gen-merge";
    gen-aspects.inputs.gen-schema.follows = "gen-schema";

    import-tree.url = "github:denful/import-tree/a164a12202f58eb67559bd33b5592f20660d9baf";

    # Terminal dep: gen-bind's `wrapAll`, tracking the same branch as the root flake.
    gen-bind.url = "github:sini/gen-bind";
    gen-bind.inputs.gen-prelude.follows = "gen-prelude";

    nixpkgs.url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz";

    # flake-parts: the host used to EVALUATE the fixture consumer flake in
    # ci/tests/flake-module.nix (`flakeParts.lib.evalFlakeModule`). Same input the root flake pins.
    flake-parts.url = "github:hercules-ci/flake-parts";
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
      gen-bind,
      nixpkgs,
      flake-parts,
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
        genBind = gen-bind.lib;
        inherit nixpkgs;
        flakeParts = flake-parts;
      };
    in
    gen.lib.mkCi {
      inherit inputs;
      name = "gen-flake";
      testModules = ./tests;
      specialArgs = {
        inherit genFlake nixpkgs;
        genMerge = gen-merge.lib;
        genSchema = gen-schema.lib;
        genAspects = gen-aspects.lib;
        genBind = gen-bind.lib;
        # flake-parts, so ci/tests/flake-module.nix can evaluate a fixture consumer flake.
        flakeParts = flake-parts;
      };
    };
}
