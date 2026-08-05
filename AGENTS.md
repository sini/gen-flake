# gen-flake — agent capability sheet

## Scope

The single nixpkgs / flake-parts boundary of the pure-gen stack: `compose` resolves a gen module tree purely through gen-merge's `evalModuleTree` into resolved values + a flat aspect registry + a per-host class projection + the provenance channel, and `realize` folds that projection through per-class terminals into `{ <class>.<host> = artifact; }`.

## Not this library's job

Quoted text is the owner's own `flake.nix` `description` field, verbatim.

| Responsibility | Owner |
|---|---|
| Module merging, option priorities, the provenance channel, the warm splice itself | `gen-merge` — "gen-merge — pure-Nix byte-mode module MERGE engine (evalModuleTree) for the pure-gen module system". gen-flake supplies knobs only: `warmFrom`/`editedModules` (`lib/compose.nix:197,206`) land on `evalModuleTree`'s own formals (gen-merge `lib/modules.nix:788-789`), and `trace` is `result.warmDecision` re-exported field-for-field (`lib/compose.nix:280-292`) |
| Kinds, instances, registries, `id_hash` | `gen-schema` — "gen-schema: typed record registry with extension points for the pure-gen module system". gen-flake only threads it as a module arg (`lib/compose.nix:31-39`) |
| The aspect grammar, class declaration, and flattening the aspect tree | `gen-aspects` — "gen-aspects: aspect-oriented composition types (pure-gen, re-hosted on gen-merge)". gen-flake calls `genAspects.flatten` once (`lib/compose.nix:213`) and reshapes the result |
| Partial-applying resolved bindings into class module functions | `gen-bind` — "gen-bind: module binding with external arguments for Nix". The terminal's whole wrap step is `genBind.wrapAll` (`lib/terminals.nix:51-53`) |
| Type checking / `verify` | `gen-types` — "gen-types: pure, nixpkgs-lib-free structural type checker for the gen ecosystem". Threaded only; optional at construction |
| General utilities | `gen-prelude` — "gen-prelude: vendored, nixpkgs-lib-free pure utilities for the gen ecosystem". Threaded only; optional at construction |
| Reading a directory into a module list | the import-tree fork `github:denful/import-tree`, pinned at `a164a12` (`flake.nix`, `flake.lock`). **Attribution UNKNOWN** — that flake.nix has no `description` field (its whole body is `{ outputs = _: import ./.; }`) |
| Querying the aspect registry (traversal, condensation, selector matching) | `gen-graph` — "gen-graph: accessor-based graph query combinators"; `gen-select` — "gen-select: selector algebra for attributed graph positions". gen-flake ships `composed.aspects` as the flat query surface and imports neither (both appear in `lib/` only inside comments) |
| What a system class MEANS (`nixosSystem`, `darwinSystem`, an image builder) | the consumer's `evaluator` argument to `mkSystemTerminal` (`lib/terminals.nix:41-61`). gen-flake's only system touch is the `nixosSystem` sugar (`lib/terminals.nix:111-122`), carved out by name in `ci/tests/purity.nix` |
| Hosting a flake-parts evaluation | the consumer. `flakeModules.default` is a plain flake-parts module; `mkFlakeTerminal` calls `flakeParts.lib.evalFlakeModule` as a library over a caller-supplied module set. `flake-parts` — "Flake basics described using the module system" |
| Incremental rebuild / change propagation over compose results | `gen-rebuild` — "gen-rebuild: pure-Nix incremental rebuilder core (Mokhov rebuilder dimension)". `lib.diff` reports a value delta; it schedules nothing |
| Computing the values a consumer pushes through `realize`'s `bindings` hook (settings cascades, secrets/vars) | `gen-settings` — "gen-settings — stratified settings resolution as a pure layered fold, with refs-as-data, structured provenance, and the graduated injection construct"; `gen-vars` — "gen-vars: scope-driven, multi-target variable generation" |
| Cross-flake aspect federation | `gen-link` — "gen-link: cross-flake aspect federation over origin-labeled subgraphs" |

## Exports

Entry: `inputs.gen-flake.lib` (flake) or `import ./. { … }` (root `default.nix` — a FUNCTION of named deps that self-fetches the flake-locked revs; `nixpkgs` and `flakeParts` default to `null`). Both yield the same five-key attrset.

Surface version: the repo carries one signed tag, `v1.0.0` at `88f639c` ("gen v1 trust release: the composition boundary — compose/realize/override/diff with observability"), an ancestor of `HEAD`. "gen-flake v1" in a sibling repo (e.g. gen-vars `7b595f4`, which pins rev `16aafe6` ≤ `v1.0.0`) denotes that surface: `compose` / `realize` present, `mkSystems` retired, `perSystem` injection opt-in.

**Pure core** — `lib/compose.nix`, `lib/inject.nix`, `lib/realize.nix`, `lib/diff.nix`

| Export | Signature |
|---|---|
| `compose` | `{ tree ? null, modules ? [ ], specialArgs ? { }, engineArgs ? { }, selectHosts ? (v: v.hosts or { }) } -> { values; aspects; hosts; provenance; override; }` |
| `injectArgs` | `composed -> { _module.args.genValues = composed.values; }` |
| `realize` | `{ composed, terminals, bindings ? { }, extraModules ? { } } -> { <class>.<host> = artifact; }` |
| `diff` | `a -> b -> { changed; added; removed; perLoc = { "<loc>" = { before; after; defs; }; }; }` |

**Terminals** — `lib/terminals.nix` (the excluded nixpkgs / flake-parts boundary)

| Export | Signature |
|---|---|
| `terminals.mkSystemTerminal` | `{ evaluator } -> terminalArgs -> artifact`; `evaluator : { modules, specialArgs } -> artifact` |
| `terminals.nixosSystem` | `{ nixpkgs ? <threaded default> } -> terminalArgs -> artifact` (sugar: `mkSystemTerminal { evaluator = nixpkgs.lib.nixosSystem; }`) |
| `terminals.mkFlakeTerminal` | `{ inputs, self, modules, systems ? [ ] } -> config.flake` (not a `realize` terminal — called directly) |

**Flake output** — `flakeModule.nix`

| Export | Signature |
|---|---|
| `flakeModules.default` | a flake-parts module: `{ config, lib, inputs, ... } -> module` (already partially applied over the constructed lib) |

**`options.gen`** declared by that module (`flakeModule.nix:78-197`):

| Option | Type | Default |
|---|---|---|
| `tree` | `nullOr path` | `null` |
| `modules` | `listOf raw` | `[ ]` |
| `specialArgs` | `attrsOf raw` | `{ }` |
| `inject` | `attrsOf raw` | `(injectArgs composed)._module.args` ⇒ `{ genValues = <values>; }` |
| `injectPerSystem` | `bool` | `false` |
| `nixpkgs` | `nullOr raw` | `inputs.nixpkgs or null` |
| `terminals` | `attrsOf raw` | `{ }` (a `nixos` terminal merges in from `gen.nixpkgs` unless null or already set) |
| `extraModules` | `attrsOf (listOf deferredModule)` | `{ }` |
| `composed` | `raw`, `readOnly`, `internal` | the single compose result |
| `realized` | `raw`, `readOnly`, `internal` | the class-major realize result |

Its `config` sets exactly three things: `_module.args = cfg.inject`, `perSystem` (under `mkIf cfg.injectPerSystem`), and `flake.nixosConfigurations = realized.nixos or { }` (`flakeModule.nix:199-211`).

**Construction contract** (consumed, not exported). `lib/default.nix` takes `{ importTree, genMerge, genSchema, genAspects, genTypes ? { }, genPrelude ? { }, genBind, nixpkgs ? null, flakeParts ? null }`. `genBind`, `nixpkgs`, `flakeParts` reach `lib/terminals.nix` only; the pure core never receives them.

**Terminal contract** (consumed, not exported). A terminal is `terminalArgs -> artifact`; measured arg names are `bindings`, `extraModules`, `modules`, `name`, `nodes`, plus `osConfig` iff the projection entry carries one. `bindings.host` IS the resolved instance — there is no separate `host` field.

**Compose result keys** (measured): `aspects`, `hosts`, `override`, `provenance`, `values`; an `override` result additionally carries `trace`, whose keys are `mode`, `modules`, `reason`, `remerged`, `reused`.

## Entry points by task

| Task | Reach for |
|---|---|
| Resolve a directory of gen modules to values | `compose { tree = ./gen-modules; }` |
| Resolve inline gen modules with no directory | `compose { modules = [ … ]; }` |
| Point compose at a nested host registry | `compose { selectHosts = v: v.fleet.hosts; }` |
| Pass an engine knob through (`check`, `prefix`) | `compose { engineArgs = { check = false; }; }` |
| Re-compose with extra module definitions | `composed.override { modules = [ … ]; }` (chainable) |
| Find out whether an override took the warm path | `(composed.override e).trace.mode` / `.reason` |
| Hand resolved values to a nixpkgs eval for QUERYING | `injectArgs composed` (arg name `genValues`) |
| Build per-host artifacts from class content | `realize { composed; terminals = { <class> = …; }; }` |
| Build NixOS systems | `terminals.nixosSystem { nixpkgs = <flake input>; }` as the `nixos` terminal |
| Build a non-NixOS target (darwin, an image, a stub) | `terminals.mkSystemTerminal { evaluator = <your builder>; }` |
| Cross a flake-parts module set to flake outputs | `terminals.mkFlakeTerminal { inputs; self; modules; systems; }` |
| Push reader-computed values into class modules | `realize { bindings = { … ; <host> = { … }; }; }` |
| Read a peer host's artifact from inside a class module | the `nodes` specialArg (lazy; spine is the class's host keys) |
| Compare two compose results by value | `diff a b` — `.added` / `.removed` are cheap, `.changed` and `.perLoc` are not |
| Wire the whole thing with no manual threading | `imports = [ gen-flake.flakeModules.default ]; gen.tree = ./gen-modules;` |
| Read realized non-`nixos` classes from flake-parts | `config.gen.realized.<class>` |

## Measured traps

Verified at gen-flake `90960ad` by evaluating against `(builtins.getFlake "git+file:///home/sini/Documents/repos/sini/gen-flake").lib`.

Shared fixtures: `base` = `compose` of (a) a flat `hosts` registry with `h1`/`h4` declaring `aspects = [ "web" ]`, `h2` declaring none, `h3` declaring `aspects = [ "ghost" ]`; (b) an aspect module whose `mkAspectSchema` declares classes `nixos` AND `metrics`, where the `web` aspect supplies `nixos` content only. `Lnull` = `import ./lib` with `nixpkgs = null; flakeParts = null;`. `dataTerm` = a terminal returning its own arg names / binding keys / module count.

| Trap | Evidence |
|---|---|
| A **declared-but-unset** class still projects a NON-EMPTY module list, so `realize` builds every member host under it | `base.hosts.h1.classes` ⇒ `["metrics","nixos"]`; the `metrics` list has length 1 and its entry is a `{ imports = [ … ]; }` of length 1, identical in shape to `nixos`'s. `realize` with `terminals.metrics = dataTerm` ⇒ `{ h1 = …; h4 = …; }`. `lib/compose.nix:45-53` — `classFieldsOf` is structural (`? imports && isList imports`), and an unset class option is still that shape. "Class-major, iff-non-empty" tests the LIST, not the content |
| Aspect membership naming an aspect absent from the registry is **silently dropped** — no throw, no warning | `lib/compose.nix:92`; `base.hosts.h3.classes` ⇒ `{}` (h3 declares `aspects = [ "ghost" ]`). Positive control, same projection: `base.hosts.h1.classes` ⇒ `["metrics","nixos"]` |
| Membership strings must equal the **flat** registry keys, which are SLASH-joined; a dotted path matches nothing, silently | `composed.aspects` keys ⇒ `["net","net/dns","web"]` while `composed.values.aspects` keys ⇒ `["net","web"]`. Host with `aspects = [ "net/dns" ]` ⇒ `classes` `["nixos"]`; the same host with `aspects = [ "net.dns" ]` ⇒ `{}` |
| Default `selectHosts` reads flat `values.hosts`; a nested registry projects **EMPTY** with no error | `lib/compose.nix:171`; nested `fleet.hosts` fixture ⇒ `hosts` `[]` while `values ? fleet` ⇒ `true`. Positive control: `selectHosts = v: v.fleet.hosts` ⇒ `["n1"]`. Test: `test-nested-default-selecthosts-empty` (`ci/tests/compose.nix`) |
| `selectHosts` returning a non-attrset throws a NAMED error rather than dying inside `mapAttrs` | `lib/compose.nix:82-86`; observed: `error: compose: selectHosts must return an attrset of host instances ({ <host> = <instance>; }), got string`. Test: `test-nonattrset-selecthosts-throws` |
| `engineArgs` carrying `modules` / `specialArgs` / `warmFrom` / `editedModules` throws, naming **all** offenders in one message | `lib/compose.nix:182-192`; each of the four ⇒ `tryEval.success = false`; `{ modules = [ ]; specialArgs = { }; }` ⇒ `error: compose: engineArgs must not carry modules, specialArgs — compose owns these engine keys`. Positive control: `engineArgs.check = false` ⇒ succeeds. Tests: `test-engineargs-modules-collision`, `test-engineargs-specialargs-collision` |
| The engine's unknown-key orphan check is **ON** by default — an undeclared config key throws | `compose { modules = [ { config.orphanKey = 1; } ]; }` ⇒ `success = false`; same with `engineArgs.check = false` ⇒ `true`. Tests: `test-engineargs-check-default-throws`, `test-engineargs-check-false-passthrough` |
| Warm fires on a purely **syntactic** key test, `attrNames edits == [ "modules" ]` — so `override { modules = [ ]; }` is WARM despite editing nothing, and adding any second key is COLD | `lib/compose.nix:260`; `.trace.mode` ⇒ `"warm"` for `{ modules = [ … ]; }` and for `{ modules = [ ]; }`; `"cold"` for `{ modules = [ ]; specialArgs = { }; }` and for `{ }`. A chained warm stays warm. Tests: `test-warm-trace-mode`, `test-cold-fallback-trace` |
| Both cold cases report the **same** reason — the trace does not distinguish "you added a non-modules key" from "you passed an empty edit" | `.trace.reason` ⇒ `"no warmFrom (cold)"` for `{ modules = [ ]; specialArgs = { }; }` AND for `{ }` |
| A base `compose` has **no** `trace`; only override results do | `lib/compose.nix:294`; `base ? trace` ⇒ `false`, `attrNames base` ⇒ `["aspects","hosts","override","provenance","values"]`; `(base.override { modules = [ ]; }) ? trace` ⇒ `true`. Tests: `test-base-has-no-trace`, `test-override-has-trace` |
| `realize`'s output keys are exactly the `terminals` keys: a class with a terminal but no member host is present as an **empty attrset**, not absent | `lib/realize.nix:48-84`; `terminals = { nixos; metrics; neverDeclared; }` ⇒ `attrNames r` `["metrics","neverDeclared","nixos"]` with `r.neverDeclared` ⇒ `{}`. Test: `test-output-is-class-major` (`ci/tests/terminal.nix`) |
| `extraModules` **supplement** a build, never create one | `lib/realize.nix:57-59`; `extraModules.h2 = [ { } ]` where h2 has no class content ⇒ `attrNames r.nixos` still `["h1"]`. Test: `test-host-under-class-iff-nonempty` |
| The global `bindings` layer splats WHOLESALE, so a host-named refinement key also rides into **every other** host's bindings as a literal binding | `lib/realize.nix:67-68`; with `bindings = { globalKey = 1; h1 = { onlyH1 = 2; }; }`, h1's binding keys ⇒ `["globalKey","h1","host","onlyH1"]` and h4's ⇒ `["globalKey","h1","host"]`. Tests: `test-global-beats-base`, `test-perhost-beats-global` |
| A host-named binding whose value is NOT an attrset is not a refinement — it stays a literal binding | `lib/realize.nix:67`; `bindings.h1 = "a bare string"` ⇒ h1's binding keys `["h1","host"]` |
| `realize` consumes any attrset with `.hosts`; a projection entry missing `bindings` fails with a RAW attribute error that **`tryEval` does not catch** | `lib/realize.nix:68`; `realize { composed = { hosts.hX.classes.nixos = [ { imports = [ ]; } ]; }; … }` ⇒ `error: attribute 'bindings' missing at …/lib/realize.nix:68:40`, and wrapping it in `tryEval` still aborts the eval |
| `compose` NEVER emits `osConfig` — the field is a consumer-supplied projection extension that `realize`/`mkSystemTerminal` forward iff present | `git grep -n "osConfig" -- lib/compose.nix` ⇒ no output; positive control, same predicate same run: `git grep -n "osConfig" -- lib/realize.nix` ⇒ 3 lines (`9`, `23`, `78`) |
| `mkSystemTerminal` absorbs `name` — the evaluator's `specialArgs` is `{ nodes; }` only (plus `osConfig` when present) | `lib/terminals.nix:41-61`; evaluator observed `attrNames specialArgs` ⇒ `["nodes"]`. Test: `test-nodes-threaded` |
| `wrapAll` hands the evaluator MORE modules than the class list held (wrapped modules ++ collision validators) | `lib/terminals.nix:51-58`; a 1-module class list ⇒ evaluator receives 2 modules. Test: `test-wrap-contract-module-count` |
| Host-dependency guards are LAZY and named: constructing a terminal with a null `nixpkgs` / `flakeParts` succeeds; only forcing an artifact throws | `lib/terminals.nix:111-122,86-90`; `terminals.nixosSystem { nixpkgs = null; }` constructs (`tryEval.success = true`), realizing through it ⇒ ``error: gen-flake terminals.nixosSystem: `nixpkgs` is required (pass the nixpkgs flake input, or thread one at construction).``; `Lnull.terminals.mkFlakeTerminal { … }` ⇒ ``error: gen-flake terminals.mkFlakeTerminal: `flakeParts` is required (thread the flake-parts flake at construction).``. Tests: `test-missing-nixpkgs-construction-ok`, `test-missing-nixpkgs-forcing-throws` |
| `diff` treats two **different** functions at the same loc as unchanged | `lib/diff.nix:69-78`; a `types.raw` loc holding `x: x` vs `x: "totally different …"` — both `isFunction`, applied results differ — yields `changed` `[ ]`. Positive control, same pair of composes: a string leaf edit ⇒ `changed` `["alpha"]` |
| `diff` laziness has an intrinsic coupling: `added`/`removed` survive a throwing leaf, but a **shared** throwing leaf makes `changed` AND the `perLoc` KEY SET throw | `lib/diff.nix:141,146-161`; throwing leaf on ONE side ⇒ `added` `["boom"]`, evaluates clean. Same leaf on BOTH sides ⇒ `added`/`removed` still clean (`success = true`), `changed` and `attrNames perLoc` both `success = false`. Tests: `test-changed-does-not-force-unrelated-throw`, `test-perloc-value-read-throws` (`ci/tests/diff.nix`) |
| `compose { }` — no tree, no modules — is legal and totally empty, not an error | `values` / `aspects` / `hosts` all `[]` under `attrNames`. Tests: `test-empty-values`, `test-empty-aspects`, `test-empty-hosts` |
| `values` carries gen TYPE objects (with function fields) by design; the invariant is that they land in `_module.args`, which nixpkgs does not type-walk | `values.schema.host.options.addr.type` keys ⇒ `["__id","__name","check","name","verify"]`, `isFunction …type.check` ⇒ `true`. Test: `test-invariant-type-is-data-not-option` (`ci/tests/flake-module.nix`) |
| The tree loader skips any `_`-prefixed path — **file and directory** | `lib/compose.nix:174-177`; a fixture tree of `visible.nix` + `_skipped.nix` + `_hidden/inside.nix` ⇒ `attrNames values` `["visibleKey"]` (the other two modules declare `skippedFileKey` / `skippedDirKey`) |
| `injectArgs` sets ONLY `_module.args`, and the arg is named `genValues` (not `genSchema`) | `lib/inject.nix:16-18`; `attrNames (injectArgs base)` ⇒ `["_module"]`, `attrNames …_module.args` ⇒ `["genValues"]`. Test: `test-sets-only-module-args` |
| The flake module emits **no** `perSystem` definition unless `gen.injectPerSystem` is set | `flakeModule.nix:204-206` (`lib.mkIf`) — **read, not exercised** in this run (needs a flake-parts eval). Test: `test-persystem-not-injected-by-default` (`ci/tests/flake-module.nix`) |

## Theory

No academic result is claimed. `git grep -nEi "\(19[0-9]{2}\)|\(20[0-9]{2}\)|et al\.|Theorem|Lemma|doi|arxiv" -- lib/ README.md flakeModule.nix default.nix flake.nix` returns one line, `flakeModule.nix:123`, matching only on `doi` inside the word "doing"; positive control, same predicate same run, `git grep -c … -- README.md` in `gen-select` ⇒ `6`.

What the repo claims instead are **invariants**, stated in `README.md` and restated in code comments:

- **gen types never leave the pure eval; only values cross into nixpkgs** (`README.md:35`). Realized as value-injection rather than type-driving: the payload lands in `_module.args`, never in a consumer options tree (`flakeModule.nix:117-124`).
- **The pure core is nixpkgs-lib-free.** `lib/compose.nix`, `lib/inject.nix`, `lib/realize.nix`, `lib/diff.nix` may not so much as NAME nixpkgs; `lib/default.nix` + the root flake may name it but not CALL a module-system function; `lib/terminals.nix` and `flakeModule.nix` are the declared exclusions. Enforced by `ci/tests/purity.nix` (`test-library-core-is-nixpkgs-free`), which strips comments before scanning — `git grep -n "nixpkgs" -- lib/compose.nix lib/inject.nix lib/realize.nix lib/diff.nix` filtered to non-comment lines returns nothing, while the same predicate over `lib/default.nix lib/terminals.nix` returns 8 lines.
- **Warm is an optimization, never a semantics change** (`README.md:140-143`): `composed.override e` is byte-identical to a cold `compose` of the hand-merged args over both `values` and `provenance`, standing behind `test-cold-parity-force` and `test-chain-warm-equals-manual` (`ci/tests/compose.nix`).
- **The nixpkgs boundary is exactly one call.** `mkSystemTerminal` is generic (consumer-supplied evaluator); the sole system touch is `nixosSystem`'s `nixpkgs.lib.nixosSystem`, and `test-generic-equals-nixossystem-sugar` pins the sugar to the generic form.

Contracts consumed from a sibling's documentation rather than restated here: gen-merge's warm re-eval decision shape and its provenance record shape / forcing contract (`README.md:134,375-376`, `lib/compose.nix:242-243,280-292`).

## Drift check

```sh
nix eval --json .#lib --apply 'l: { lib = builtins.attrNames l; terminals = builtins.attrNames l.terminals; }' &&
nix eval --json .#flakeModules --apply 'm: { flakeModules = builtins.attrNames m; }' &&
git grep -oe '^    [a-zA-Z]* = mkOption' -- flakeModule.nix
```

Current output (verbatim):

```
{"lib":["compose","diff","injectArgs","realize","terminals"],"terminals":["mkFlakeTerminal","mkSystemTerminal","nixosSystem"]}
{"flakeModules":["default"]}
flakeModule.nix:    tree = mkOption
flakeModule.nix:    modules = mkOption
flakeModule.nix:    specialArgs = mkOption
flakeModule.nix:    inject = mkOption
flakeModule.nix:    injectPerSystem = mkOption
flakeModule.nix:    nixpkgs = mkOption
flakeModule.nix:    terminals = mkOption
flakeModule.nix:    extraModules = mkOption
flakeModule.nix:    composed = mkOption
flakeModule.nix:    realized = mkOption
```

**Checks.** Test-runner invocation (from the repo root; CI runs the same command with `working-directory: ci`, `.github/workflows/ci.yml:13,18`):

```sh
nix flake check ./ci
```
