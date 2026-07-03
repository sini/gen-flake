# Standalone (non-flake) entry. Flake consumers should use the `.lib` output.
#
# gen-flake composes the published pure stack. The defaults fetch the flake-locked revs
# (content-addressed via narHash, so the plain-import path stays pure and in lockstep with the flake
# output) and construct ONE consistent instance of each lib — the SAME gen-prelude/gen-merge are
# threaded into gen-schema/gen-aspects, matching the flake's follows. Pass any explicitly to override.
{
  lock ? builtins.fromJSON (builtins.readFile ./flake.lock),
  fetch ? name: builtins.fetchTree lock.nodes.${lock.nodes.root.inputs.${name}}.locked,
  genPrelude ? import "${fetch "gen-prelude"}/lib",
  genTypes ? import "${fetch "gen-types"}/lib" { prelude = genPrelude; },
  genMerge ? import "${fetch "gen-merge"}/lib" {
    prelude = genPrelude;
    types = genTypes;
  },
  genSchema ? import "${fetch "gen-schema"}" {
    prelude = genPrelude;
    merge = genMerge;
  },
  genAspects ? import "${fetch "gen-aspects"}" {
    prelude = genPrelude;
    merge = genMerge;
    schema = genSchema;
  },
  importTree ? import (fetch "import-tree"),
}:
import ./lib {
  inherit
    importTree
    genMerge
    genSchema
    genAspects
    genTypes
    genPrelude
    ;
}
