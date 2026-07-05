# `realize` — the terminal registry fold. PURE (builtins only, no nixpkgs — ci/tests/purity.nix
# covers this file). It turns a `compose` result plus a per-class terminal into class-major artifacts:
#
#     realize { composed; terminals; bindings ? {}; extraModules ? {}; } -> { <class>.<host> = artifact; }
#
# For each class that has a terminal, every host whose projection carries a NON-EMPTY module list for
# that class is realized by calling the terminal with the pinned contract (below). A host with no
# content for a class does not appear under it — the output is class-major and content-driven, so a
# consumer wires `flake.nixosConfigurations = (realize { … }).nixos`. Each consumed
# `composed.hosts.<name>` entry MUST carry `bindings` (compose always emits `{ host = <instance> }`),
# so the bare `hc.bindings` read below fails loud on a malformed projection rather than papering over it.
#
# Terminal contract (every field pinned):
#   name         the host's registry key (string).
#   modules      `composed.hosts.<name>.classes.<class>` — this class's deferredModule list. Opaque
#                and unforced; the terminal decides whether/when to evaluate it.
#   bindings     the merged binding set, most specific wins: compose's `{ host = <instance> }` <
#                global `bindings` < per-host `bindings.<name>`. There is no separate `host` field —
#                `bindings.host` IS the resolved instance by construction.
#   nodes        the `realized.<class>` set itself — a lazy cross-host accessor for THIS class. Its
#                spine is the class's host keys, so reading the keys forces no peer artifact.
#   extraModules the per-host extras for this host (`[]` when absent).
#   osConfig     present IFF the host's projection entry carries one (host-owned user/home content);
#                passed through verbatim.
{
  realize =
    {
      # A `compose` result; only `.hosts` (the per-host build projection) is consumed.
      composed,
      # `{ <class> = terminal; }` — which classes to realize, and how. The output keys are exactly
      # these class names.
      terminals,
      # The extra-bindings hook: a global attrset applied to every host, optionally carrying per-host
      # refinements under `<host>` keys (`bindings.<host>` wins over the global layer). The global
      # layer splats WHOLESALE (`hc.bindings // bindings // perHost`), so any host-named refinement key
      # also rides into every host's merged bindings as a literal binding — harmless (`wrapAll` injects
      # only the args a module's formals name), but surprising if a formal happens to share a host name.
      bindings ? { },
      # `{ <host> = [ module ]; }` — per-host extras handed to the terminal (`[]` when absent).
      extraModules ? { },
    }:
    let
      hosts = composed.hosts;

      # The class-major fold. `realized` is self-referential: a host's `nodes` is `realized.<class>`,
      # the same set being built — lazy, so forcing one host's artifact never forces a peer's (the
      # spine is only the class's host keys, populated by `listToAttrs` names).
      realized = builtins.mapAttrs (
        className: terminal:
        builtins.listToAttrs (
          builtins.concatMap (
            hostName:
            let
              hc = hosts.${hostName};
              classModules = hc.classes.${className} or [ ];
            in
            if classModules == [ ] then
              [ ]
            else
              [
                {
                  name = hostName;
                  value =
                    let
                      # The per-host refinement layer, applied only when `bindings.<name>` is an
                      # attrset (a bare global value under a host-named key is not a refinement).
                      perHost = if builtins.isAttrs (bindings.${hostName} or null) then bindings.${hostName} else { };
                      mergedBindings = hc.bindings // bindings // perHost;
                    in
                    terminal (
                      {
                        name = hostName;
                        modules = classModules;
                        bindings = mergedBindings;
                        nodes = realized.${className};
                        extraModules = extraModules.${hostName} or [ ];
                      }
                      // (if hc ? osConfig then { inherit (hc) osConfig; } else { })
                    );
                }
              ]
          ) (builtins.attrNames hosts)
        )
      ) terminals;
    in
    realized;
}
