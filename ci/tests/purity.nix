# Purity invariant, with a documented terminal carve-out.
#
# gen-flake is the SINGLE nixpkgs boundary of a pure-gen ecosystem. That boundary is DELIBERATELY
# narrow — it lives in exactly one file (lib/systems.nix, the terminal), and everything else stays
# nixpkgs-lib-free. This test enforces the split three ways:
#
#   * STRICT  (lib/compose.nix, lib/inject.nix, + any future pure lib file): the PURE core. It drives
#             gen-merge's byte-mode `evalModuleTree` (the `lib.evalModules` replacement) + injected gen
#             libs — it must NEVER name `nixpkgs` nor CALL a nixpkgs module-system function. A stray
#             `nixpkgs`/`lib.types`/`evalModules` tether here fails CI.
#   * RELAXED (lib/default.nix, root flake.nix, root default.nix): WIRING. These thread `nixpkgs`/
#             `genBind` as OPAQUE values into the terminal, so they may NAME `nixpkgs` — but they must
#             still never CALL a module-system function (`lib.evalModules`/`lib.types`/…).
#   * EXCLUDED (lib/systems.nix, ./flakeModule.nix): the sanctioned nixpkgs / flake-parts boundary.
#             `lib/systems.nix` is where `nixpkgs.lib.nixosSystem` enters. `./flakeModule.nix` is the
#             flake-parts ergonomics host (T7): it declares options with nixpkgs `lib.mkOption`/
#             `lib.types` (supplied by the CONSUMER's flake-parts eval) and closes over `mkSystems`,
#             so it is classified terminal-side exactly like systems.nix. It lives at the repo ROOT
#             (not ./lib) and is intentionally absent from both the ./lib walk and `rootScans` below,
#             so it is never strict-scanned. The pure→nixpkgs crossing happens at these files only.
#
# Comments are stripped before scanning, so this note's own tokens do not trip it.
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

  read = p: stripComments (builtins.readFile p);

  # The nixpkgs module-system CALL tether — forbidden EVERYWHERE in the library (even the wiring may
  # not call these). `evalModules` is safe to forbid — it is not an infix of gen-merge's
  # `evalModuleTree`.
  callTokens = [
    "lib.types"
    "lib.mkOption"
    "lib.mkMerge"
    "lib.evalModules"
    "evalModules"
  ];
  # The nixpkgs-IMPORT tether — additionally forbidden in the STRICT core (the pure files must not so
  # much as name nixpkgs). The wiring is allowed these because it threads nixpkgs opaquely.
  importTokens = [
    "nixpkgs"
    "{ lib }"
    "{ lib,"
  ];
  strictForbidden = callTokens ++ importTokens;

  # Classify each lib/*.nix file: systems.nix is the excluded terminal; default.nix is wiring; every
  # other lib file is strict pure core (so a NEW pure file is guarded by default).
  classify =
    p:
    let
      base = baseNameOf (toString p);
    in
    if base == "systems.nix" then
      null # EXCLUDED — the sanctioned nixpkgs boundary
    else if base == "default.nix" then
      "relaxed"
    else
      "strict";

  libScans = lib.concatMap (
    p:
    let
      cls = classify p;
      forbidden = if cls == "strict" then strictForbidden else callTokens;
    in
    if cls == null then
      [ ]
    else
      map (tok: "${toString p}: '${tok}'") (lib.filter (tok: lib.hasInfix tok (read p)) forbidden)
  ) (walk libDir);

  # Root wiring files: NAME nixpkgs/gen-bind as inputs, but must not CALL a module-system function.
  # NOTE: flakeModule.nix is deliberately NOT listed here — it is the flake-parts terminal-side host
  # (EXCLUDED, like lib/systems.nix); it legitimately uses lib.mkOption/lib.types.
  rootScans =
    lib.concatMap
      (
        rel:
        map (tok: "${rel}: '${tok}'") (
          lib.filter (tok: lib.hasInfix tok (read (../.. + "/${rel}"))) callTokens
        )
      )
      [
        "flake.nix"
        "default.nix"
      ];

  violations = libScans ++ rootScans;
in
{
  flake.tests.purity.test-library-core-is-nixpkgs-free = {
    expr = violations;
    expected = [ ];
  };
}
