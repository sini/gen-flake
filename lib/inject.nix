# `injectArgs` — the PURE query surface of gen-flake's terminal.
#
# Given a `compose` result, produces a plain nixpkgs MODULE (an attrset) that ONLY sets
# `_module.args`, exposing the resolved config VALUES to a consumer's nixpkgs eval so its modules can
# QUERY them (`{ genValues, ... }: … genValues.hosts.<h>.addr …`). This is distinct from `mkSystems`:
# it injects DATA for querying, not class deferredModules for building.
#
# It is PURE — pure packaging of already-resolved values; no nixpkgs `lib` is touched and NO gen TYPE
# crosses the boundary (`composed.values` is the resolved fixpoint config: plain data — instances,
# id_hash, resolved refs — not type objects). Argument-less (gen convention): a bare attrset value.
#
# Note: the spec sketched the injected arg as `genSchema`; it is named `genValues` here because the
# payload is the resolved config VALUES, not the gen-schema constructor library.
{
  # `composed` — the result of `compose { … }`, carrying `.values` (the resolved config).
  injectArgs = composed: {
    _module.args.genValues = composed.values;
  };
}
