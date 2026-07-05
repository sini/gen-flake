# `diff` — a PURE, lazy diff of two `compose` results.
#
# `diff a b` compares the resolved `values` of two compose results, LOCATED by their engine
# `provenance` channels (gen-merge's always-on per-loc record tree, mirroring `config`'s loc
# structure). It answers "which option locs gained / lost / changed a value between compose `a` and
# compose `b`, and which definitions are responsible?" — the query the override cold-parity oracle
# folds over.
#
#   diff a b :: { changed; added; removed; perLoc = { "<loc>" = { before; after; defs; }; }; }
#     changed  — loc strings present in BOTH `a` and `b` whose value differs (leaf comparison below).
#     added    — loc strings present only in `b`'s provenance (a def in `b` created the loc).
#     removed  — loc strings present only in `a`'s provenance.
#     perLoc   — per-loc detail for exactly the changed ∪ added ∪ removed locs:
#                  before — the value at that loc in `a.values` (null when the loc is absent in `a`).
#                  after  — the value at that loc in `b.values` (null when the loc is absent in `b`).
#                  defs   — the b-side provenance `defs` for that loc (the definitions responsible;
#                           null when the loc is absent in `b`, i.e. a removed loc).
#
# LOC ENUMERATION reads the provenance tree SPINE only. Each provenance leaf is a record — a declared
# record `{ defs; winners; priority; defaulted; }` or a freeform record with the last three null;
# every other node is a group (a nested attrset of child locs). `isProvLeaf` distinguishes them by
# the presence of all four record keys, a WHNF membership test that does NOT read `defs` (so it never
# runs the record's property-discharge, and never forces a config value). A loc is a dot-joined path,
# matching gen-merge's `showOption` convention.
#
# LEAF COMPARISON is `toJSON` equality over the two values, with functions deep-NULLED first
# (`dropFns`) so `toJSON` can cross a leaf that resolved to a function (a schema type-checker, an
# aspect deferredModule). CAVEAT (documented, not a bug): nulling makes a function↔data topology flip
# still move the bytes (null ≠ data), but two DIFFERENT functions both compare EQUAL after nulling —
# a leaf that is a function in both `a` and `b` is treated as unchanged even if the closures differ.
# `toJSON` on a resolved leaf is O(size of that leaf); it runs only for the SHARED locs, and only when
# the `changed` list (or a `perLoc` entry) is read.
#
# LAZINESS (what is forced, when):
#   * `diff a b` returns an attrset of THUNKS — building it forces nothing.
#   * reading `added` / `removed` walks both provenance SPINES (WHNF per node) and diffs the loc-string
#     sets. It forces NO config value and NO provenance `defs` field.
#   * reading `changed` additionally forces, per SHARED loc, that leaf's value in both configs (the
#     `toJSON` comparison). A loc that is added/removed (not shared) is never compared, so an
#     unrelated throwing leaf that exists in only one config never fires when `changed` is read.
#   * forcing `perLoc` — even to its KEY SET — forces the changed / added / removed partition, and
#     computing `changed` runs the `toJSON` comparison of EVERY shared leaf. So merely reaching
#     `perLoc.<loc>` pays the full shared-leaf comparison cost (a shared leaf that throws will throw
#     here regardless of WHICH entry you asked for — the coupling is intrinsic to a value-diff). An
#     individual `perLoc.<loc>` read then adds only THAT loc's `before` / `after` (a WHNF path
#     descent) and `defs` (the b-side record `defs`, discharging that loc's contributing defs to
#     WHNF per gen-merge's forcing contract) on top of that partition cost.
#
# PURE — builtins only, no nixpkgs `lib` (ci/tests/purity.nix scans this file as strict core).
{
  diff =
    a: b:
    let
      # A loc path (list) → its dot-joined string, gen-merge's `showOption` convention.
      showOption = builtins.concatStringsSep ".";

      # A provenance leaf record carries all four fields (declared: rich; freeform: last three null).
      # A group node is a nested attrset of child locs and has none. Membership forces the node to
      # WHNF only — it never reads `defs`, so it never runs the record's property-discharge. STRUCTURAL
      # ASSUMPTION (failure mode): a config GROUP whose children are literally ALL FOUR of
      # `defs`/`winners`/`priority`/`defaulted` (as declared options) would misclassify as a leaf here —
      # the record shape is the only signal the engine gives, so those four names are effectively
      # reserved at a group node. No engine surface collides with them today.
      isProvLeaf = v: builtins.isAttrs v && v ? defs && v ? winners && v ? priority && v ? defaulted;

      # Deep-replace every function with `null` so `toJSON` can cross a value whose leaves resolved to
      # functions. Functions are NULLED (not skipped): a topology change (a key gained/lost, a
      # function↔data flip) still moves the bytes; two functions compare equal (the documented caveat).
      dropFns =
        x:
        if builtins.isFunction x then
          null
        else if builtins.isList x then
          map dropFns x
        else if builtins.isAttrs x then
          builtins.mapAttrs (_: dropFns) x
        else
          x;

      # Walk a provenance tree to its LEAF locs, SPINE-only: a leaf record → one `{ path; loc; }`; a
      # group → recurse over `attrNames` (forces the group's spine, no record field). Nothing here
      # reads `defs` / a config value.
      walkProv =
        prefix: node:
        if isProvLeaf node then
          [
            {
              path = prefix;
              loc = showOption prefix;
            }
          ]
        else if builtins.isAttrs node then
          builtins.concatMap (k: walkProv (prefix ++ [ k ]) node.${k}) (builtins.attrNames node)
        else
          [ ];

      leavesA = walkProv [ ] a.provenance;
      leavesB = walkProv [ ] b.provenance;

      # A loc-string → its path (list) map. A shared loc has the same joined string on both sides, so
      # one union map suffices (b's binding overrides a's for identical keys — identical value anyway).
      pathOf = builtins.listToAttrs (
        map (l: {
          name = l.loc;
          value = l.path;
        }) (leavesA ++ leavesB)
      );

      # loc-string sets for O(1) membership.
      toSet =
        xs:
        builtins.listToAttrs (
          map (x: {
            name = x;
            value = null;
          }) xs
        );
      locsA = map (l: l.loc) leavesA;
      locsB = map (l: l.loc) leavesB;
      setA = toSet locsA;
      setB = toSet locsB;

      # A lazy WHNF path descent — foldl' forces each level to WHNF then hands back the leaf thunk; a
      # missing level yields null (never reached for an enumerated loc, whose path exists by construction).
      getByPath =
        path: attrs:
        builtins.foldl' (acc: k: if builtins.isAttrs acc && acc ? ${k} then acc.${k} else null) attrs path;

      addedLocs = builtins.filter (loc: !(setA ? ${loc})) locsB;
      removedLocs = builtins.filter (loc: !(setB ? ${loc})) locsA;
      sharedLocs = builtins.filter (loc: setB ? ${loc}) locsA;

      valueChanged =
        loc:
        let
          p = pathOf.${loc};
        in
        builtins.toJSON (dropFns (getByPath p a.values))
        != builtins.toJSON (dropFns (getByPath p b.values));

      changedLocs = builtins.filter valueChanged sharedLocs;

      # perLoc covers exactly the diff'd locs. Each field is a thunk — building the attrset descends
      # nothing; reading a field forces that field (before/after: a value descent; defs: the b-side
      # provenance record `defs`, discharging that loc's defs per the forcing contract).
      perLoc = builtins.listToAttrs (
        map (
          loc:
          let
            p = pathOf.${loc};
          in
          {
            name = loc;
            value = {
              before = if setA ? ${loc} then getByPath p a.values else null;
              after = if setB ? ${loc} then getByPath p b.values else null;
              defs = if setB ? ${loc} then (getByPath p b.provenance).defs else null;
            };
          }
        ) (changedLocs ++ addedLocs ++ removedLocs)
      );
    in
    {
      changed = changedLocs;
      added = addedLocs;
      removed = removedLocs;
      inherit perLoc;
    };
}
