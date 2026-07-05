# `lib.diff` — a pure, lazy value diff of two compose results, located by the engine provenance
# channel. Also pins the shape of `compose`'s projected `provenance` field: the rich engine record at
# a declared loc, the reduced record (nulls) at a freeform loc.
{ genFlake, genMerge, ... }:
let
  inherit (genMerge) mkOption mkForce types;

  # A schema of plain declared scalar options → clean, predictable provenance leaves (one record per
  # option, loc = the dot-joined option path). Defaults so every leaf resolves without a def.
  baseSchema = {
    options.alpha = mkOption {
      type = types.str;
      default = "a0";
    };
    options.beta = mkOption {
      type = types.str;
      default = "b0";
    };
    options.grp.inner = mkOption {
      type = types.str;
      default = "i0";
    };
  };

  # A disjoint edit: force `alpha` only (a real `_file` so `perLoc.alpha.defs` can NAME it). `beta` /
  # `grp.inner` untouched.
  forceAlpha = {
    _file = "force-alpha.nix";
    config.alpha = mkForce "a1";
  };

  # A NEW declared option present only on the b-side → an ADDED loc: a declared leaf appears in
  # provenance iff its option is declared, so a fresh option is the clean added / removed signal.
  extraOpt.options.gamma = mkOption {
    type = types.str;
    default = "g0";
  };

  # A NEW declared option whose VALUE throws — the unrelated throwing leaf. Enumerating its
  # provenance loc reads only the record spine (`? defs`), never the value, so it lands in `added`
  # without firing; only reading `perLoc.boom.after` forces the throw.
  boomOpt = {
    options.boom = mkOption { type = types.str; };
    config.boom = throw "boom leaf forced";
  };

  # A freeform schema + an undeclared key it absorbs → a freeform provenance loc (reduced record).
  freeformSchema = {
    freeformType = types.lazyAttrsOf types.str;
    options.alpha = mkOption {
      type = types.str;
      default = "a0";
    };
  };
  freeformVal.freeKey = "fv";

  cBase = genFlake.compose { modules = [ baseSchema ]; };
  cAlpha = genFlake.compose {
    modules = [
      baseSchema
      forceAlpha
    ];
  };
  cExtra = genFlake.compose {
    modules = [
      baseSchema
      extraOpt
    ];
  };
  cBoom = genFlake.compose {
    modules = [
      baseSchema
      forceAlpha
      boomOpt
    ];
  };
  cFreeform = genFlake.compose {
    modules = [
      freeformSchema
      freeformVal
    ];
  };

  dChanged = genFlake.diff cBase cAlpha;
  dAdded = genFlake.diff cBase cExtra;
  dRemoved = genFlake.diff cExtra cBase;
  dLazy = genFlake.diff cBase cBoom;
in
{
  # ── provenance projection shape ──────────────────────────────────────────────────────────────────
  # `compose` projects the engine provenance channel VERBATIM: a DECLARED loc carries the rich record
  # (defs / winners / priority / defaulted), a FREEFORM loc the reduced record (winners / priority /
  # defaulted all null — "freeform / not observable", never "no override present").
  flake.tests.diff-provenance-shape = {
    # A declared leaf → the rich record; `alpha` here is default-only, so `defaulted` is true.
    test-declared-record-fields = {
      expr = {
        hasDefs = cFreeform.provenance.alpha ? defs;
        winnersIsList = builtins.isList cFreeform.provenance.alpha.winners;
        defaulted = cFreeform.provenance.alpha.defaulted;
      };
      expected = {
        hasDefs = true;
        winnersIsList = true;
        defaulted = true;
      };
    };
    # A freeform leaf → the reduced record: winners / priority / defaulted null, defs present.
    test-freeform-reduced-record = {
      expr = {
        winners = cFreeform.provenance.freeKey.winners;
        priority = cFreeform.provenance.freeKey.priority;
        defaulted = cFreeform.provenance.freeKey.defaulted;
        hasDefs = cFreeform.provenance.freeKey ? defs;
      };
      expected = {
        winners = null;
        priority = null;
        defaulted = null;
        hasDefs = true;
      };
    };
  };

  # ── diff: a single disjoint def-change ───────────────────────────────────────────────────────────
  flake.tests.diff-changed = {
    # One disjoint def-change (`alpha` forced) → `changed` is EXACTLY that loc; the untouched `beta` /
    # `grp.inner` (compared equal by toJSON) do not appear.
    test-changed-is-exact-loc = {
      expr = dChanged.changed;
      expected = [ "alpha" ];
    };
    test-nothing-added-removed = {
      expr = {
        added = dChanged.added;
        removed = dChanged.removed;
      };
      expected = {
        added = [ ];
        removed = [ ];
      };
    };
    # before / after are the resolved values (default "a0" → forced "a1").
    test-perloc-before-after = {
      expr = {
        before = dChanged.perLoc.alpha.before;
        after = dChanged.perLoc.alpha.after;
      };
      expected = {
        before = "a0";
        after = "a1";
      };
    };
    # `perLoc.<loc>.defs` are the b-side provenance defs — they NAME the responsible module's file.
    test-perloc-defs-names-file = {
      expr = builtins.any (d: d.file == "force-alpha.nix") dChanged.perLoc.alpha.defs;
      expected = true;
    };
  };

  # ── diff: added / removed ────────────────────────────────────────────────────────────────────────
  flake.tests.diff-added-removed = {
    # A new declared option on the b-side → `added`; nothing changed / removed.
    test-added-new-loc = {
      expr = dAdded.added;
      expected = [ "gamma" ];
    };
    test-added-no-removed = {
      expr = dAdded.removed;
      expected = [ ];
    };
    # `perLoc.<added>.before` is null (absent in `a`); `after` is the b-side value.
    test-added-perloc = {
      expr = {
        before = dAdded.perLoc.gamma.before;
        after = dAdded.perLoc.gamma.after;
      };
      expected = {
        before = null;
        after = "g0";
      };
    };
    # The mirror: diffing the SAME pair swapped → the loc is `removed`, its `after` null, `defs` null
    # (no b-side loc to attribute).
    test-removed-mirror = {
      expr = {
        removed = dRemoved.removed;
        after = dRemoved.perLoc.gamma.after;
        defs = dRemoved.perLoc.gamma.defs;
      };
      expected = {
        removed = [ "gamma" ];
        after = null;
        defs = null;
      };
    };
  };

  # ── diff: laziness ───────────────────────────────────────────────────────────────────────────────
  # `cBoom` carries an unrelated throwing leaf (`boom`, present only on the b-side → an ADDED loc).
  # Reading `changed` for a DISJOINT edit compares only SHARED leaves (alpha / beta / grp.inner),
  # never the added `boom`, so deep-forcing `changed` succeeds — the throw fires only if `perLoc.boom`
  # is read.
  flake.tests.diff-lazy = {
    # Building the diff result forces NOTHING: reading its key SET (the WHNF spine) touches no field
    # thunk, so even a diff carrying a throwing leaf yields its shape without firing.
    test-building-result-forces-nothing = {
      expr = builtins.attrNames dLazy;
      expected = [
        "added"
        "changed"
        "perLoc"
        "removed"
      ];
    };
    # `changed` is `[ "alpha" ]`; deep-forcing it does not force the throwing `boom` leaf.
    test-changed-does-not-force-unrelated-throw = {
      expr = builtins.deepSeq dLazy.changed dLazy.changed;
      expected = [ "alpha" ];
    };
    # `boom` lands in `added` (its loc STRING only) without firing; deep-forcing `added` is safe.
    test-added-loc-without-forcing-value = {
      expr = builtins.deepSeq dLazy.added dLazy.added;
      expected = [ "boom" ];
    };
    # The throw is REAL: reading the added loc's VALUE fires it (tryEval — the guard is that reading
    # `perLoc.boom.after` throws where reading `changed` / `added` above did not).
    test-perloc-value-read-throws = {
      expr =
        (builtins.tryEval (builtins.deepSeq dLazy.perLoc.boom.after dLazy.perLoc.boom.after)).success;
      expected = false;
    };
  };
}
