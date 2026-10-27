# Mokusei

Mokusei coordinates work performed by native agent runtimes.

## Language

**Moku**: Mokusei's coordinating assistant. It communicates with the user and delegates work to ordinary Agent Threads through their Harnesses.

**Harness**: An agent runtime that owns execution, tools, permissions and native sessions. It also owns any subscription built into that runtime.

**Native subscription**: A model-service entitlement managed by a Harness's native account system. Its model catalog and quota belong to that native service.

**Native model provider**: A model service configured and selected within a Harness. Its model identities, credentials and account capacity belong to that native service.

**Call identifier**: The model name sent to a model-service API. It may be a moving alias for a different model release over time.

**Model release**: The actual model version served behind a call identifier. Its identity is distinct from reasoning or effort configuration.

**Account telemetry**: Model-service- or subscription-authored facts about available capacity, balance or usage. Missing facts mean unknown capacity.

**Context Plugin**: A plugin that supplies additional context exclusively to Moku. It may obtain and cache the information it contributes, but does not own conversations, application surfaces or task execution.

### Threads and lifecycle

**Agent Thread**: An ordinary task conversation that can contain successive executions. Its identity persists when one execution finishes.

**Sidecard**: A plugin-owned card alongside an ordinary Agent Thread's reading view. A Sidecard provides an activity within that Thread, such as browsing a webpage or participating in its current execution.

**Moku Thread**: The conversation in which Moku communicates with the user and coordinates ordinary Agent Threads.

**Report Agent**: The private agent that reviews task evidence and maintains report documents within one Directory Scope. Its conversation is distinct from those documents.

**Tag Agent**: The private agent that maintains a five-slot semantic tag pool within one Directory Scope and assigns eligible ordinary Agent Threads, including archived threads, to that pool.

**Directory Scope**: The shared workspace identity of related task conversations and documents. Inbox is the Directory Scope for tasks without a persistent directory; its identity is distinct from its display name.

**Global Agent**: A background agent whose authority spans directory scopes within its declared capabilities. Global authority is explicit and is distinct from Inbox or a missing scope.

**Scoped Agent**: A background agent whose authority is limited to one Directory Scope. Its scope does not determine whether its native session remains open while idle.

**Report Thread**: A persistent report document prepared by Report Agent for the user. It has no model execution or conversation lifecycle.

**Git worktree extension**: Read-only worktree facts attached to ordinary task cards. The built-in Git monitor reconciles currently referenced execution directories and supplies on-demand file/diff queries. It does not create separate Git Threads or control task execution.

**Thread type**: The domain kind of a thread, including executing conversations and non-conversational views such as Report Threads.

**Thread metadata**: Descriptive information owned by a thread's plugin, distinct from its execution history. Its content may be generated, authored by the user, or obtained from an external source.

**Thread catalog projection**: The public description a thread's owner supplies for identification and cross-thread references. Its readable name does not prescribe how the owner creates or stores metadata.

**Lifecycle subject**: The thread, report document, application, or configuration whose state a lifecycle fact describes. A thread subject retains its type even after deletion.

**Lifecycle source**: The actor or application authority that produced a lifecycle fact. A Tag Agent edit to an ordinary Agent Thread has Tag Agent as its source and the ordinary thread as its subject.
