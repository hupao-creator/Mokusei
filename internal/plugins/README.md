# Plugin modules

Harness plugins adapt externally installed native engines. Application plugins
own their domain state and scoped operations; Context plugins contribute Moku
context. [Module boundaries](../README.md) and the
[public plugin contracts](../core/plugin/README.md) describe their responsibilities.

Codex, Claude, Pi and OpenCode keep Agent grep restricted to completed public
content. The four approved external Harness JS resources remain production inputs. Architecture/static registration checks and Go vet/build remain part of
`make check`.
