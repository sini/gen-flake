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

## Purity

`lib/` is nixpkgs-lib-free, enforced by `ci/tests/purity.nix`. nixpkgs is pulled only in `ci/` (the
nix-unit harness). Run the tests with `nix flake check ./ci`.
