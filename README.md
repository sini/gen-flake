# gen-flake — the nixpkgs boundary of the pure-gen module ecosystem

[![CI](https://github.com/sini/gen-flake/actions/workflows/ci.yml/badge.svg)](https://github.com/sini/gen-flake/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT) [![Sponsor](https://img.shields.io/badge/Sponsor-%E2%9D%A4-pink?logo=github)](https://github.com/sponsors/sini)

## Overview

gen-flake is the **single nixpkgs boundary** of the pure-gen module ecosystem. Compose a gen module
tree **purely** — `gen-merge`'s `evalModuleTree` folds the tree over the `gen-schema`/`gen-aspects`
grammar, checked by `gen-types`, with **no nixpkgs** — yielding resolved **values** plus per-class
**deferredModules**. gen-flake is the terminal that crosses into nixpkgs: it **injects those
resolved VALUES** into a consumer's nixpkgs eval (via `_module.args`) and builds NixOS systems.

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
| [gen-merge](https://github.com/sini/gen-merge) | Byte-mode module merge engine (`evalModuleTree`, byte-identical to nixpkgs `lib.evalModules` over the priority subset) |
| [gen-schema](https://github.com/sini/gen-schema) | Typed registries (kinds, instances, collections, refs); re-hosted on gen-merge |
| [gen-aspects](https://github.com/sini/gen-aspects) | Aspect type system (traits, classification, dispatch); re-hosted on gen-merge |
| [gen-scope](https://github.com/sini/gen-scope) | HOAG scope-graph evaluator (demand-driven, \_eval memoization, circular attributes) |
| [gen-graph](https://github.com/sini/gen-graph) | Accessor-based graph query combinators (traversal, condensation, phaseOrder) |
| [gen-select](https://github.com/sini/gen-select) | Selector algebra (pattern matching over graph positions) |
| [gen-bind](https://github.com/sini/gen-bind) | Module binding (inject external args into NixOS modules) |
| [gen-dispatch](https://github.com/sini/gen-dispatch) | Relational rule dispatch STEP (stratified phases, conflict resolution) |
| [gen-resolve](https://github.com/sini/gen-resolve) | Demand-driven RAG evaluator over scope graphs (attribute schedule + convergence loop) |
| [gen-rebuild](https://github.com/sini/gen-rebuild) | Pure-Nix incremental rebuilder (change propagation, AFFECTED set) |
| [gen-vars](https://github.com/sini/gen-vars) | Pure-Nix vars/secrets (den-agnostic) |
| [gen-flake](https://github.com/sini/gen-flake) | **This lib** — the nixpkgs boundary — compose purely, inject resolved values, build NixOS systems (value-injection) |

## Usage

### As a flake input

Import the flake module into a flake-parts flake and point `gen.tree` at a directory of gen
definition modules. From one `compose` you get both the resolved VALUES (injected as `genValues`)
and the built `nixosConfigurations`:

```nix
{
  imports = [ gen-flake.flakeModules.default ];

  gen.tree = ./gen-modules; # a directory of gen definition modules
  gen.extraModules.myhost = [ ./hardware.nix ]; # per-host platform/base NixOS modules

  # the resolved gen VALUES are injected as `genValues` into every flake + perSystem module:
  flake.myOutput = {
    addr = config.gen.composed.values.hosts.myhost.addr;
  };
}
```

The `lib.compose` and `flakeModules.default` sections below document the full projection and option
set; `lib.compose` is also the entry point for consumers not on flake-parts.

## `lib.compose`

`compose` loads a gen module tree and resolves it purely via `gen-merge.evalModuleTree`:

```nix
compose ::
  { tree ? <path>, modules ? [ ], specialArgs ? { } }
  -> { values; classContent; hostContent; }
```

- `tree` — a directory of gen definition modules, loaded as a **bare path list** via the
  import-tree fork: `(importTree.addPath tree).files`. Each path is imported by `evalModuleTree`
  (gen-merge path-leaf import).
- `modules` — extra inline modules appended to the tree.
- `specialArgs` — extra module args, merged over the threaded gen libs.

The gen constructors (`genMerge`, `genSchema`, `genAspects`, `genTypes`, `genPrelude`) are threaded
into every module via `evalModuleTree`'s `specialArgs`, so definition modules declare their typed
surfaces purely — no nixpkgs `lib`.

### Projection

- `values` — a thin read of the resolved config (`result.config`): instances, `id_hash`, resolved
  refs, flattened surfaces. This is the injection payload — VALUES, not gen types.
- `classContent` — `genAspects.flatten result.config.aspects`: the flat aspect registry (keyed by
  aspect path), where each entry carries its per-class deferredModule content (e.g. `.nixos`),
  inspectable but unforced. This is the flat **query** surface (gen-graph/gen-select queries over
  aspects).
- `hostContent` — the per-host `(class, host)` projection driven by each host's `aspects` membership:
  `{ <host> = { bindings = { host = <resolved instance>; }; classes = { <class> = [ <deferredModule> ]; }; }; }`.
  This is the **build** surface `mkSystems` consumes; the deferredModules stay unforced until the
  terminal imports them.

The projection is exercised by `ci/tests/compose.nix` (values/classContent/hostContent) and
`ci/tests/terminal.nix` (the hostContent projection + `mkSystems`) against the fixture tree under
`ci/tests/_fixtures/tree/`.

## `flakeModules.default` — flake-parts ergonomics

The `.flakeModule` is the "no manual threading" front door. A consumer imports it into their
flake-parts flake and gets, from **one** `compose`, both the query surface and the built systems:

```nix
{
  imports = [ gen-flake.flakeModules.default ];

  gen.tree = ./gen-modules;                         # a directory of gen definition modules
  gen.extraModules.myhost = [ ./hardware.nix ];     # per-host platform/base NixOS modules

  # QUERY — the resolved gen VALUES are injected as `genValues` (default name) into every flake and
  # perSystem module, so any consumer module reads them with no manual inject:
  flake.myOutput = { addr = config.gen.composed.values.hosts.myhost.addr; };
  # or, in a module body: { genValues, ... }: { … genValues.hosts.myhost.addr … }
}
```

From that one import the module:

- runs `compose { inherit (config.gen) tree modules specialArgs; }` **once**;
- injects the resolved values under `config.gen.inject` names (default `{ genValues = <values>; }`,
  derived by reusing `injectArgs`) into **both** the top-level flake args and every `perSystem` arg;
- sets `flake.nixosConfigurations = mkSystems { hostContent; nixpkgs = config.gen.nixpkgs; extraModules; }`.

`options.gen`:

| option | type | default | purpose |
| --- | --- | --- | --- |
| `tree` | `nullOr path` | `null` | directory of gen definition modules (composed once) |
| `modules` | `listOf raw` | `[ ]` | extra inline gen modules (fed to gen-merge, **not** nixpkgs) |
| `specialArgs` | `attrsOf raw` | `{ }` | extra args merged over the gen libs during compose |
| `inject` | `attrsOf raw` | `{ genValues = <values>; }` | resolved values to inject, keyed by arg name |
| `nixpkgs` | `nullOr raw` | `inputs.nixpkgs` | nixpkgs used to **build** the systems |
| `extraModules` | `attrsOf (listOf deferredModule)` | `{ }` | per-host extra NixOS modules |
| `composed` | `raw` (read-only) | the compose result | `values` / `classContent` / `hostContent` handle |

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

## Purity

The pure core (`lib/compose.nix`, `lib/inject.nix`) is nixpkgs-lib-free, enforced by
`ci/tests/purity.nix`. The terminal `lib/systems.nix` (the `nixpkgs.lib.nixosSystem` boundary) and
the root `flakeModule.nix` (the flake-parts host — uses `lib.mkOption`/`lib.types` supplied by the
consumer's eval) are the sanctioned exclusions. nixpkgs is pulled only in `ci/` (the nix-unit
harness). Run the tests with `nix flake check ./ci`.

## Testing

```console
$ nix flake check ./ci
```

The nix-unit suites exercise the projection and the terminal: `ci/tests/compose.nix`
(`values`/`classContent`/`hostContent`), `ci/tests/terminal.nix` (the `hostContent` projection +
`mkSystems`), `ci/tests/flake-module.nix` (the end-to-end fixture consumer that proves the
invariant), and `ci/tests/purity.nix` (the pure core is nixpkgs-lib-free).

## License

MIT © Jason Bowman
