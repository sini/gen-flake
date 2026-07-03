# gen-flake

The single boundary of the pure-gen module ecosystem.

The pure stack composes a gen module tree with **no nixpkgs**, producing resolved **values** plus
per-class **deferredModules**. A later terminal (not part of this library) injects those values into
a consumer's nixpkgs eval and builds NixOS systems.

**Invariant:** gen *types* never leave the pure eval; only *values* cross into nixpkgs.

## `lib.compose`

`compose` loads a gen module tree and resolves it purely via `gen-merge.evalModuleTree`:

```nix
compose ::
  { tree ? <path>, modules ? [ ], specialArgs ? { } }
  -> { values; classContent; }
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
  refs, flattened surfaces.
- `classContent` — `genAspects.flatten result.config.aspects`: the flat aspect registry, where each
  entry carries its per-class deferredModule content (e.g. `.nixos`). This is the raw material a
  consumer eval injects into nixpkgs. The exact `(class, host)` reshape is finalized downstream.

The projection is intentionally minimal; it is exercised by `ci/tests/compose.nix` against the
fixture tree under `ci/tests/_fixtures/tree/`.

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
