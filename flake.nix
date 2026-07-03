{
  description = "gen-flake — the pure composition boundary of the pure-gen module ecosystem";

  # gen-flake is the SINGLE boundary of the pure-gen module stack. `.lib.compose` (this task, T5) is
  # the PURE half: it loads a gen module tree and resolves it via gen-merge's byte-mode
  # `evalModuleTree` — with ZERO nixpkgs — returning resolved VALUES + per-class deferredModules.
  # The consumer-eval half (inject those values into a real nixpkgs eval + build NixOS systems at a
  # terminal) is T6/T7 and lives OUTSIDE this library; that is where nixpkgs/flake-parts enter.
  #
  # Invariant: gen TYPES never leave the pure eval; only VALUES cross into a consumer's nixpkgs.
  # The library (./lib) is nixpkgs-lib-free — enforced by ci/tests/purity.nix. Consequently these
  # inputs are the published PURE stack only; no nixpkgs/flake-parts here (they belong to T6).
  #
  # follows wire ONE instance of each lower lib through the whole stack, so the constructors the tree
  # sees (gen-merge/gen-schema/gen-aspects) share identity — the merge protocol is duck-typed, but a
  # single instance keeps the closure minimal and the type objects self-consistent.
  inputs = {
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

    # The tree loader — the nixpkgs-lib-free fork (PR to main pending). Its output IS the callable:
    # `(import-tree.addPath <dir>).files` returns a BARE PATH LIST that feeds `evalModuleTree`
    # directly (gen-merge #20 path-leaf import). Pure builtins, no lib.
    import-tree.url = "github:denful/import-tree/a164a12202f58eb67559bd33b5592f20660d9baf";
  };

  outputs =
    {
      gen-prelude,
      gen-types,
      gen-merge,
      gen-schema,
      gen-aspects,
      import-tree,
      ...
    }:
    {
      lib = import ./lib {
        # The fork's flake output already IS the callable object (its flake `outputs = _: import ./.`).
        importTree = import-tree;
        genMerge = gen-merge.lib;
        genSchema = gen-schema.lib;
        genAspects = gen-aspects.lib;
        genTypes = gen-types.lib;
        genPrelude = gen-prelude.lib;
      };
    };
}
