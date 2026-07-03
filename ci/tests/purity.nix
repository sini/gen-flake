# Purity invariant: the gen-flake library (./lib) is nixpkgs-lib-free. `compose` drives gen-merge's
# byte-mode `evalModuleTree` (the `lib.evalModules` replacement) + the injected gen libs — it must
# never CALL nixpkgs `lib.evalModules`/`lib.types`. A stray `lib.`/`evalModules`/`nixpkgs` tether in
# the library source fails CI.
#
# Scope: lib/**.nix + the root flake.nix + default.nix. NOT ci/ (the harness legitimately uses
# nixpkgs.lib). Comments are stripped before scanning, so this note's own tokens do not trip it.
{ lib, ... }:
let
  libDir = ../../lib;

  stripComments =
    text:
    lib.concatStringsSep "\n" (
      map (line: lib.head (lib.splitString "#" line)) (lib.splitString "\n" text)
    );

  walk =
    dir:
    lib.concatLists (
      lib.mapAttrsToList (
        name: type:
        if type == "directory" then
          walk (dir + "/${name}")
        else if lib.hasSuffix ".nix" name then
          [ (dir + "/${name}") ]
        else
          [ ]
      ) (builtins.readDir dir)
    );

  sources =
    map (p: {
      name = toString p;
      code = stripComments (builtins.readFile p);
    }) (walk libDir)
    ++
      map
        (rel: {
          name = rel;
          code = stripComments (builtins.readFile (../.. + "/${rel}"));
        })
        [
          "flake.nix"
          "default.nix"
        ];

  # The nixpkgs / module-system tether. gen-flake does not DEFINE any module-system API of its own
  # (it delegates entirely to gen-merge), so every nixpkgs token below is genuinely forbidden.
  # `evalModules` is safe to forbid — it is not an infix of gen-merge's `evalModuleTree`.
  forbidden = [
    "nixpkgs"
    "lib.types"
    "lib.mkOption"
    "lib.mkMerge"
    "lib.evalModules"
    "evalModules"
    "{ lib }"
    "{ lib,"
  ];

  violations = lib.concatMap (
    src: map (tok: "${src.name}: '${tok}'") (lib.filter (tok: lib.hasInfix tok src.code) forbidden)
  ) sources;
in
{
  flake.tests.purity.test-library-source-is-nixpkgs-free = {
    expr = violations;
    expected = [ ];
  };
}
