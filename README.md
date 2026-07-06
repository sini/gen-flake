# gen-flake — the nixpkgs boundary of the pure-gen module ecosystem

[![CI](https://github.com/sini/gen-flake/actions/workflows/ci.yml/badge.svg)](https://github.com/sini/gen-flake/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT) [![Sponsor](https://img.shields.io/badge/Sponsor-%E2%9D%A4-pink?logo=github)](https://github.com/sponsors/sini)

## Overview

gen-flake is the **single nixpkgs boundary** of the pure-gen module ecosystem. It has two halves and
one crossing between them:

- **Compose (PURE, `nixpkgs.lib`-free).** `compose` loads a gen module tree and resolves it with
  `gen-merge`'s byte-mode `evalModuleTree` — the tree folded over the `gen-schema`/`gen-aspects`
  grammar, checked by `gen-types`, with **no nixpkgs**. The result is resolved **values**, a flat
  **aspect** registry, a per-host build projection (**hosts**), and an always-on **provenance**
  channel. `compose`, `injectArgs`, `realize`, and `diff` are all nixpkgs-lib-free (enforced by
  `ci/tests/purity.nix`).
- **Realize (TERMINAL, nixpkgs).** `realize` folds the per-host projection through a per-class
  **terminal** into class-major artifacts. The shipped `terminals.nixosSystem` is the ONE sanctioned
  crossing where `nixpkgs.lib.nixosSystem` enters; only resolved values + unforced class
  `deferredModule`s cross into it.

```
gen tree (definition modules)
  │  compose  ── gen-merge evalModuleTree (PURE) ─────►  { values; aspects; hosts; provenance; override; }
  │                                                          │       │           │
  │  injectArgs (PURE) ── _module.args.genValues = values ─► QUERY   │           │
  │                                                                  │           └─► provenance / diff
  └  realize (TERMINAL) ── terminal (e.g. nixosSystem) ────────────► { <class>.<host> = artifact; }
```

This is **value-injection, not type-driving**: a gen type rides as inert data inside `_module.args`
and never enters the consumer's options tree, so nixpkgs never type-walks it. That one-way trade is
what lets the pure engine terminate at nixpkgs without a foreign module library driving it.

**Invariant:** gen *types* never leave the pure eval; only *values* cross into nixpkgs.

## Gen Ecosystem

| Library | Role |
|---------|------|
| [gen-prelude](https://github.com/sini/gen-prelude) | Pure nixpkgs-lib-free utility base (builtins re-exports + vendored lib utils) |
| [gen-algebra](https://github.com/sini/gen-algebra) | Pure primitives (record, search monad, either, intensional identity) |
| [gen-types](https://github.com/sini/gen-types) | Clean-room MIT structural type checker (leaf/poly checkers; `verify: v → null\|err`) |
| [gen-merge](https://github.com/sini/gen-merge) | Byte-mode module merge engine (`evalModuleTree`, byte-identical to nixpkgs `lib.evalModules` over the priority subset) + the provenance channel |
| [gen-schema](https://github.com/sini/gen-schema) | Typed registries (kinds, instances, collections, refs); re-hosted on gen-merge |
| [gen-aspects](https://github.com/sini/gen-aspects) | Aspect type system (traits, classification, dispatch); re-hosted on gen-merge |
| [gen-scope](https://github.com/sini/gen-scope) | HOAG scope-graph evaluator (demand-driven, \_eval memoization, circular attributes) |
| [gen-graph](https://github.com/sini/gen-graph) | Accessor-based graph query combinators (traversal, condensation, phaseOrder) |
| [gen-select](https://github.com/sini/gen-select) | Selector algebra (pattern matching over graph positions) |
| [gen-bind](https://github.com/sini/gen-bind) | Module binding (inject external args into NixOS modules) |
| [gen-dispatch](https://github.com/sini/gen-dispatch) | Relational rule dispatch STEP (stratified phases, conflict resolution) |
| [gen-resolve](https://github.com/sini/gen-resolve) | Demand-driven RAG evaluator over scope graphs (attribute schedule + convergence loop) |
| [gen-class](https://github.com/sini/gen-class) | Class-share mechanism (partition / contract / apply / gate), byte-gated; tier-2 fixed-input via gen-merge |
| [gen-rebuild](https://github.com/sini/gen-rebuild) | Pure-Nix incremental rebuilder (change propagation, AFFECTED set) |
| [gen-vars](https://github.com/sini/gen-vars) | Pure-Nix vars/secrets (den-agnostic) |
| [gen-flake](https://github.com/sini/gen-flake) | **This lib** — the nixpkgs boundary — compose purely, inject resolved values, realize NixOS systems (value-injection) |

## Usage

Import the flake module into a flake-parts flake and point `gen.tree` at a directory of gen
definition modules. From one `compose` you get both the resolved VALUES (injected as `genValues`)
and the built `nixosConfigurations`:

```nix
{
  imports = [ gen-flake.flakeModules.default ];

  gen.tree = ./gen-modules;                    # a directory of gen definition modules
  gen.extraModules.myhost = [ ./hardware.nix ]; # per-host platform/base NixOS modules

  # the resolved gen VALUES are injected as `genValues` into the top-level flake args:
  flake.myOutput = { addr = config.gen.composed.values.hosts.myhost.addr; };
}
```

`lib.compose` / `lib.realize` are the entry points for consumers **not** on flake-parts, or on
flake-parts but needing knobs the flake module does not surface (`selectHosts`, realize `bindings`).

## `lib.compose`

`compose` loads a gen module tree and resolves it purely via `gen-merge.evalModuleTree`:

```nix
compose ::
  { tree ? <path>, modules ? [ ], specialArgs ? { }, engineArgs ? { }, selectHosts ? (v: v.hosts or { }) }
  -> { values; aspects; hosts; provenance; override; }
```

**Arguments**

- `tree` — a directory of gen definition modules, loaded as a **bare path list** via the
  import-tree fork: `(importTree.addPath tree).files`. Each path is imported by `evalModuleTree`
  (gen-merge path-leaf import; `/_`-prefixed paths are skipped).
- `modules` — extra inline modules appended to the tree (own defs win at equal priority).
- `specialArgs` — extra module args, merged over the threaded gen libs.
- `engineArgs` — threaded **verbatim** into `gen-merge.evalModuleTree` (e.g. `check = false` to
  disable the unknown-key orphan check, `prefix` to nest). Carrying `modules`/`specialArgs` here
  **throws** — compose owns those engine keys.
- `selectHosts` — `values → { <host> = instance; }`, names which resolved attrset holds the host
  instances (default `v: v.hosts or { }`; a nested registry passes `v: v.fleet.hosts`). A
  non-attrset result throws, naming compose and the contract rather than dying anonymously inside a
  `mapAttrs`.

The gen constructors (`genMerge`, `genSchema`, `genAspects`, `genTypes`, `genPrelude`) are threaded
into every module via `evalModuleTree`'s `specialArgs`, so definition modules declare their typed
surfaces purely — no nixpkgs `lib`.

**Result**

- `values` — a thin read of the resolved config (`result.config`): instances, `id_hash`, resolved
  refs, flattened surfaces. This is the injection payload — VALUES, not gen types.
- `aspects` — `genAspects.flatten result.config.aspects`: the flat aspect registry (keyed by aspect
  path), where each entry carries its per-class `deferredModule` content (e.g. `.nixos`), inspectable
  but unforced. This is the flat **query** surface (gen-graph/gen-select queries over aspects).
- `hosts` — the per-host `(class, host)` build projection driven by each host's `aspects` membership:
  `{ <host> = { bindings = { host = <resolved instance>; }; classes = { <class> = [ <deferredModule> ]; }; }; }`.
  `classFieldsOf` discovers class fields **structurally** (an attrset with a list `imports`) — no
  hardcoded class-name list. This is the **build** surface `realize` consumes; the deferredModules
  stay unforced until the terminal imports them.
- `provenance` — the engine provenance channel projected **verbatim** (see
  [Observability](#observability)). Costs nothing until read; `lib.diff` locates its value diff over
  it.
- `override` — `edits → a fresh compose result`. Re-invokes `compose` with the original args merged
  with `edits` per the merge law — `modules` **appended**, `specialArgs`/`engineArgs` shallow-merged
  (edit wins), `tree`/`selectHosts` **replaced** when given. The result carries `override` again —
  **chainable**: `(composed.override e1).override e2`. An override result also carries a `trace`
  (below); a plain compose does not.

### Warm override + `trace`

A **modules-append** override (the edit carries **only** `modules`) runs the engine's *warm* path:
`compose` threads the previous engine result as `warmFrom` and the appended list as `editedModules`,
and the engine re-merges only the locs the edit's dirty footprint touches, splicing the rest from the
previous result (gen-merge's [warm re-eval](https://github.com/sini/gen-merge#warm-re-eval-memoized-override) —
sound under the config fixpoint; a `pureModule`-marked definition module recovers clean-module reuse
past the function-module default). The firing condition is **syntactic on the edit keys** (`attrNames edits == [ "modules" ]`): mergeComposeArgs then recomputes everything but the module list as a
value-preserving no-op, so the key check *is* the proof that only the modules changed. **Any other
edit key ⇒ cold** — a literal re-compose, exactly the prior behaviour, stated in the trace.

Warm is transparent: it lands **behind** the standing cold-parity oracle — `composed.override e` is
byte-identical to `compose` of the hand-merged args over both `values` and `provenance`
(`ci/tests/compose.nix`, `test-cold-parity-force` + the chained-warm tooth). The warm path is an
optimization, never a semantics change.

The override result's **`trace`** is the memoization decision, projected verbatim from the engine's
`warmDecision`:

```nix
trace = {
  mode     = "warm" | "cold";        # cold = the fallback fired (reason stated)
  reason   = <string|null>;          # why cold (non-modules edit / a disabledModules refusal)
  reused   = [ <loc-string> … ];     # declared leaves spliced from the previous result
  remerged = { <loc-string> = <reason>; };   # "edited-def" | "dirty-def <f>" | "dirty-decl <f>" | "freeform-dirty <f>"
  modules  = { clean = [ … ]; dirty = [ … ]; edited = [ … ]; };  # the source classification
};
```

**Laziness cost:** `mode`/`modules` are cheap (classification only); `reused`/`remerged` are
`O(declared-locs)` spine-forcing when read — they enumerate the loc partition, never leaf values.

Exercised by `ci/tests/compose.nix` (values/aspects/hosts + the provenance cold-parity tooth, the
warm/chained-warm byte teeth, the trace shape + cold-fallback tests, and the `selectHosts`
nested-registry fixture) against the fixture tree under `ci/tests/_fixtures/tree/`.

## `lib.realize` + terminals

`realize` folds a compose result's `hosts` projection through a per-class terminal into class-major
artifacts:

```nix
realize ::
  { composed, terminals, bindings ? { }, extraModules ? { } }
  -> { <class>.<host> = artifact; }
```

- `composed` — a compose result; only `.hosts` is consumed.
- `terminals` — `{ <class> = terminal; }`. The output keys are exactly these class names.
- `bindings` — the extra-bindings hook: a global attrset applied to every host, optionally carrying
  per-host refinements under `<host>` keys.
- `extraModules` — `{ <host> = [ module ]; }`, per-host extras handed to the terminal.

**Class-major, content-driven (iff-non-empty).** For each class that has a terminal, a host is
realized **iff** its projection carries a NON-EMPTY module list for that class — a host with no
content for a class does not appear under it, and `extraModules` supplement a build, never create
one. So `flake.nixosConfigurations = (realize { … }).nixos or { }`, and a registry with no `nixos`
class at all yields the empty `or { }`.

**Terminal contract** (every field pinned; the terminal is `terminalArgs -> artifact`):

| field | meaning |
|---|---|
| `name` | the host's registry key (string) |
| `modules` | `composed.hosts.<name>.classes.<class>` — this class's `deferredModule` list, opaque and unforced |
| `bindings` | the merged binding set (below); `bindings.host` IS the resolved instance — there is no separate `host` field |
| `nodes` | the `realized.<class>` set itself — a lazy cross-host accessor whose spine is the class's host keys, so reading the keys forces no peer artifact |
| `extraModules` | the per-host extras for this host (`[]` when absent) |
| `osConfig` | present IFF the host's projection entry carries one (host-owned user/home content); passed through verbatim |

**Bindings law** (most specific wins): `{ host = <instance> }` (compose always emits this) < global
`bindings` < per-host `bindings.<name>`. The global layer splats WHOLESALE, so a host-named key also
rides into every host's bindings as a literal binding — harmless (`wrapAll` injects only the args a
module's formals name), but surprising if a formal happens to share a host name. This hook is what
lets a consumer push reader-computed values (e.g. a resolved settings cascade) into class modules —
the retro-fix for terminals that could not bind more than `{ host }`.

**Terminals.**

- `terminals.nixosSystem { nixpkgs ? <threaded default> }` — the shipped default `nixos` terminal and
  the ONE sanctioned nixpkgs boundary (isolated in `lib/terminals.nix`; `ci/tests/purity.nix` excludes
  it). Per host it `genBind.wrapAll`s the class `deferredModule`s with the merged `bindings`, then
  `nixpkgs.lib.nixosSystem { modules = wrapped.all ++ extraModules; specialArgs = { nodes; } // (osConfig?); }`.
  A build with neither a threaded nor a per-terminal nixpkgs throws.
- A **data terminal** is any pure `terminalArgs -> artifact` builder (no nixpkgs package set / no nixosSystem) — e.g.
  `genBind.wrapAll` + a bare `lib.evalModules` over stub options. Used by the tests and the gen-aspects
  demo to assert resolved values without a full NixOS eval.

Exercised by `ci/tests/terminal.nix` (the `hosts` projection, class-major output shape, bindings merge
order, per-host bindings, the data terminal, and the `nixosSystem` terminal).

## `lib.diff`

`diff a b` compares the resolved `values` of two compose results, located by their `provenance`
channels, and reports which option **locs** gained / lost / changed a value:

```nix
diff a b ::
  { changed; added; removed; perLoc = { "<loc>" = { before; after; defs; }; }; }
```

- `changed` — loc strings present in **both** whose value differs; `added` / `removed` — loc strings
  present only in `b` / only in `a` (a loc = a dot-joined option path, gen-merge's `showOption`
  convention).
- `perLoc.<loc>` — for each changed / added / removed loc: the `before` value (in `a`, `null` when
  absent), the `after` value (in `b`, `null` when absent), and the b-side provenance `defs` (the
  definitions responsible; `null` for a removed loc).

```nix
diff cBase cAlpha
# ⇒ { changed = [ "alpha" ]; added = [ ]; removed = [ ];
#     perLoc.alpha = { before = "a0"; after = "a1"; defs = [ { file = "…"; priority = 50; } … ]; }; }
```

Leaves are compared by `toJSON` equality with functions deep-nulled, so a `function ↔ data` flip
still registers, but two **different** functions compare equal (documented caveat — a leaf that is a
function on both sides is treated as unchanged).

**Forcing contract.** `diff` is **lazy**, but a value diff has an intrinsic coupling: building the
result forces nothing; reading `added` / `removed` walks the two provenance spines only (no config
value); reading `changed` `toJSON`-compares the **shared** leaves. Forcing `perLoc` — even just its
key set — forces the `changed`/`added`/`removed` partition, so it pays that full shared-leaf
comparison (a shared leaf that throws will throw when any `perLoc.<loc>` is reached, whichever entry
you asked for); an individual `perLoc.<loc>` read then adds only that loc's `before`/`after`/`defs`
on top. An unrelated throwing leaf present on **only one** side never fires when `changed` (or
`added`/`removed`) is read. Exercised by `ci/tests/diff.nix`.

## `lib.injectArgs`

```nix
injectArgs :: composed -> { _module.args.genValues = composed.values; }
```

Given a `compose` result, produces a plain nixpkgs MODULE that ONLY sets `_module.args`, exposing the
resolved VALUES to a consumer's nixpkgs eval so its modules can QUERY them
(`{ genValues, ... }: … genValues.hosts.<h>.addr …`). Pure packaging of already-resolved data — no
nixpkgs `lib` touched, no gen TYPE crosses. Distinct from `realize`: it injects DATA for querying,
not class `deferredModule`s for building. The flake module reuses it to derive the default `inject`
set. (The injected arg is `genValues`, not `genSchema` — the payload is the resolved config VALUES,
not the gen-schema constructor library.)

## `flakeModules.default` — flake-parts ergonomics

The "no manual threading" front door. A consumer imports it and gets, from **one** `compose`, both
the query surface and the built systems:

```nix
{
  imports = [ gen-flake.flakeModules.default ];

  gen.tree = ./gen-modules;                     # a directory of gen definition modules
  gen.extraModules.myhost = [ ./hardware.nix ]; # per-host platform/base NixOS modules
  # gen.terminals.<class> = <terminal>;         # extra class terminals (a `nixos` one defaults in)
  # gen.injectPerSystem = true;                 # ALSO inject the values into perSystem args

  flake.myOutput = { addr = config.gen.composed.values.hosts.myhost.addr; };
  # or, in a module body: { genValues, ... }: { … genValues.hosts.myhost.addr … }
}
```

From that one import the module:

- runs `compose { inherit (config.gen) tree modules specialArgs; }` **once**;
- injects the resolved values under `config.gen.inject` names (default `{ genValues = <values>; }`,
  derived by reusing `injectArgs`) into the top-level flake args, and — when `injectPerSystem` is set
  — every `perSystem` arg. Opt-in: the default emits no `perSystem` definition, keeping the perSystem
  arg-scope clean and the module robust against flake-parts versions that force a `systems`
  declaration once any `perSystem` definition exists;
- sets `flake.nixosConfigurations = (realize { composed; terminals; extraModules; }).nixos or { }` —
  the `nixos` class realized per host from compose's `hosts` projection (class-major: a host with no
  `nixos` content is not built). `terminals` is `gen.terminals` with a default `nixos` terminal from
  `gen.nixpkgs`; read other classes off `gen.realized.<class>`.

`options.gen`:

| option | type | default | purpose |
| --- | --- | --- | --- |
| `tree` | `nullOr path` | `null` | directory of gen definition modules (composed once) |
| `modules` | `listOf raw` | `[ ]` | extra inline gen modules (fed to gen-merge, **not** nixpkgs) |
| `specialArgs` | `attrsOf raw` | `{ }` | extra args merged over the gen libs during compose |
| `inject` | `attrsOf raw` | `{ genValues = <values>; }` | resolved values to inject, keyed by arg name |
| `injectPerSystem` | `bool` | `false` | also inject `inject` into perSystem args (opt-in) |
| `nixpkgs` | `nullOr raw` | `inputs.nixpkgs or null` | nixpkgs used to **build** the systems (default `nixos` terminal) |
| `terminals` | `attrsOf raw` | `{ }` | class-keyed terminal registry (a `nixos` one defaults in from `nixpkgs`; `gen.nixpkgs = null` or your own `terminals.nixos` suppresses it) |
| `extraModules` | `attrsOf (listOf deferredModule)` | `{ }` | per-host extra NixOS modules |
| `composed` | `raw` (read-only) | the compose result | `values` / `aspects` / `hosts` handle |
| `realized` | `raw` (read-only) | the realize result | class-major `{ <class>.<host> = artifact; }` handle |

### Invariant

`composed.values` (hence the injected `genValues`) includes the schema sub-tree, whose
`values.schema.<kind>.options.*.type` are inert gen **type** objects. This is **invariant-safe**:
the payload lands in `_module.args`, which nixpkgs does **not** type-walk. The failure the design
avoids — nixpkgs walking a gen type embedded in an *options* tree via `substSubModules`/
`getSubOptions` — cannot occur for a plain `_module.args` value. `renderDocs` legitimately reads
`values.schema.<kind>.options.*.type.name` (a string). Using `values.schema.<kind>` **as an option
`type`** is the explicitly out-of-scope thing and owns that hazard. `schema` is therefore **not**
projected out of the values. See `flakeModule.nix` and `ci/tests/flake-module.nix` (the fixture
consumer that proves this end-to-end).

## Observability

`compose.provenance` is the engine provenance channel projected **verbatim** — gen-merge's always-on,
lazy per-loc record tree, mirroring `values`'s loc structure. Per **declared-option** loc, the full
record:

```nix
{
  defs = [ { file; priority; } … ];   # all contributing defs, post property-discharge, pre priority pass
  winners = [ { file; } … ];          # the defs the priority pass kept (the merge's actual inputs)
  priority = <int>;                   # the effective priority the filter pass selected
  defaulted = <bool>;                 # true iff the option default supplied the value
}
```

Per **freeform** loc, a REDUCED record: `defs` only (contributing defs by file, pre-discharge);
`winners` / `priority` / `defaulted` are `null`. A `null` `priority` means **"freeform / not
observable"**, never "no override present" — freeform keys resolve inside the freeform type's own
`.merge`, which the engine does not instrument.

**Forcing contract.** Unforced options pay nothing (the channel mirrors config's laziness); a forced
option pays ~1 thunk + one record attrset when the channel is unread. Reading a declared loc's
provenance discharges that loc's contributing defs to WHNF but never forces the merged value; the
provenance and value paths share the same let-bound discharge/winners computation, so byte-parity of
the value path is untouched (the existing oracle + mutation teeth run unmodified). Discharge-state
caveat for uniform consumers (e.g. `diff` reading `defs` on both loc kinds): declared `defs` are
post-discharge (a false-`mkIf` branch drops out), freeform `defs` are pre-discharge and can be
OVER-inclusive. See the [gen-merge README §Provenance](https://github.com/sini/gen-merge#provenance)
for the record shapes and the engine-side forcing contract.

## Migrating from v0

v0 (`compose` / `injectArgs` / `mkSystems`) shipped as a working proof; v1 is the designed surface.
Nothing rode v0 downstream but the three demos (gen-schema / gen-aspects / gen-vars), which migrate
in the same pass. The breaking changes:

| v0 | v1 |
| --- | --- |
| `composed.classContent` | `composed.aspects` |
| `composed.hostContent` | `composed.hosts` |
| `mkSystems { hostContent; nixpkgs; extraModules; }` | `realize { composed; terminals.nixos = terminals.nixosSystem { nixpkgs; }; extraModules; }` |
| flakeModule `perSystem` args (unconditional) | `gen.injectPerSystem = true` (opt-in) |
| `injectArgs` / `genValues` | unchanged |
| — | `compose { engineArgs; selectHosts; }`, `composed.provenance`, `composed.override`, `diff` |

## Purity

The pure core (`lib/compose.nix`, `lib/inject.nix`, `lib/realize.nix`, `lib/diff.nix`) is
nixpkgs-lib-free, enforced by `ci/tests/purity.nix`. The terminal `lib/terminals.nix` (the
`nixpkgs.lib.nixosSystem` boundary) and the root `flakeModule.nix` (the flake-parts host — uses
`lib.mkOption`/`lib.types` supplied by the consumer's eval) are the sanctioned exclusions. nixpkgs is
pulled only in `ci/` (the nix-unit harness).

## Testing

```console
$ nix flake check ./ci
```

The nix-unit suites exercise the projection and the terminal: `ci/tests/compose.nix`
(`values`/`aspects`/`hosts` + provenance cold-parity + `selectHosts`), `ci/tests/terminal.nix`
(`realize`/`terminals` — class-major shape, bindings law, data + nixosSystem terminals),
`ci/tests/diff.nix` (the value diff + forcing contract), `ci/tests/flake-module.nix` (the end-to-end
fixture consumer that proves the invariant), and `ci/tests/purity.nix` (the pure core is
nixpkgs-lib-free).

## License

MIT © Jason Bowman
