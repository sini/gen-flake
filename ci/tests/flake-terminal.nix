# The FLAKE-PARTS TERMINAL — `mkFlakeTerminal`, the flake-parts crossing BESIDE `mkSystemTerminal`. It calls
# `flake-parts.lib.evalFlakeModule` as a LIBRARY over a flake-parts module tree and returns the transposed
# `config.flake` outputs, so a consumer can cross a flake-parts module set to real flake outputs. A PURE
# ADDITION — `mkSystemTerminal` (the `{ modules; specialArgs } -> system`
# shape) is untouched. The full output-crossing re-scope (per-family terminals, the `nixosConfigurations`
# hardcode in flakeModule/realize) is a later arc, out of scope here.
{
  genFlake,
  flakeParts,
  nixpkgs,
  ...
}:
let
  # a minimal self-referential input set — flake-parts reads `self.inputs`; the fixture flake-parts module
  # emits a top-level `flake.<key>` output AND a perSystem output (to witness the per-system transposition).
  baseInputs = {
    flake-parts = flakeParts;
    inherit nixpkgs;
  };
  self = {
    inputs = baseInputs;
  };
  inputs = baseInputs // {
    inherit self;
  };
  outputs = genFlake.terminals.mkFlakeTerminal {
    inherit inputs self;
    systems = [ "x86_64-linux" ];
    modules = [
      {
        flake.myOutput = "HELLO-FLAKE";
        perSystem =
          { pkgs, ... }:
          {
            packages.trivial = pkgs.emptyFile;
          };
      }
    ];
  };
in
{
  flake.tests.flake-terminal = {
    # mkFlakeTerminal evaluates a flake-parts module as a library → the transposed `config.flake` outputs; a
    # top-level `flake.<key>` output surfaces verbatim.
    test-flake-terminal-surfaces-flake-output = {
      expr = outputs.myOutput or "<absent>";
      expected = "HELLO-FLAKE";
    };
    # a perSystem output TRANSPOSES to `config.flake.<output>.<system>` (flake-parts' per-system transposition,
    # run as a library through the terminal) — the trivial derivation surfaces per-system.
    test-flake-terminal-transposes-persystem = {
      expr = (outputs.packages.x86_64-linux.trivial.type or null) == "derivation";
      expected = true;
    };
  };
}
