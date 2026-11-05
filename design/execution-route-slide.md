# Report execution continuation slide

## Recording diagnosis

The supplied 12.13s recording (`录屏2026-11-05 19.29.31.mov`) begins with
Report HTML on the left and its referenced completed execution, titled
“制作侧卡收起动画原生演示”, on the right. After sending, that execution is
shown in the Agent main reader and the new execution (19:29:35, connecting to
Codex) occupies the Conversation Sidecard. At 6.50s, two copies of the completed
execution are visible side by side. They are the outgoing Report reference
reader and the incoming Agent main reader, not two executions created by Send.
Exact AVFoundation frames at 50ms intervals establish the intermediate state;
keyframe-tolerant extraction misses this short transition.

`NativeWorkspacePresentation.finishExecutionSendNavigation` waits for an accepted
continuation and its catalog thread, fenced by route, exact source reference,
composer generation and coverage. `NativeExecutionContinuation` sends to the
latest referenced execution's Thread, or forks historical references before
sending; receipt recovery and draft consumption retain their existing ownership.
The destination route targets the accepted execution. The Conversation Sidecard
owns/excludes the active execution from main, leaving the previous execution in
main. The Report capability renders the selected exact execution independently.

The former transition retained both complete workspaces and moved each by the
whole viewport width: `[Report, reference] → [main, new execution]`. Because
reference and main show the same preceding execution in this scenario, this
created four visual seats instead of the intended three card roles.

## Shared-column handoff

`NativeExecutionRouteSlide` keeps the Report workspace covering hidden Agent
preparation. The existing `readingEntranceAdmitted` signal still acknowledges
main content reveal, auxiliary layout and Dock travel. The source reference
column is captured from its native aperture marker before deactivation; after
incoming native layout commits, the main panel marker supplies its destination.
Both measurements are local to their respective hosting seats, including actual
Report/Agent toolbar space and width constraints.

At travel start, one Core Animation transaction masks the outgoing workspace to
the Report region, reveals the incoming workspace at the old reference column's
origin, and installs the two translations. Both move by the same column distance,
using the shared 420ms replacement curve. At progress `p`, incoming main's left
edge is `sourceX - p * (sourceX - destinationX)`. Report moves left by that same
progress distance; new execution keeps its destination spacing beside main.
The old reference cannot paint beside or underneath the incoming main, even
when their widths differ. Its former toolbar is masked out as well.

The incoming main uses the production Agent reader and its destination width;
this changes reader presentation at the shared origin rather than sending a
second copy in from beyond the viewport. Text is not scaled or reflowed on each
animation frame. Report's retained WebKit layout is unchanged by this handoff.
Landing keeps the incoming host and its scroll state; it does not migrate the
Report reference reader's separate scroll model. The resident Dock stays outside
the moving seats, and dispatch/fork/receipt/Sidecard policies are unchanged.

Only accepted Report continuation navigation requests this motion, scoped to the
destination route UUID. Later streaming revisions do not replay it. Start and
completion remain generation-fenced; replacement navigation, resize and
teardown retire old geometry and masks. Pointer, accessibility and reading
interaction gates exclude preparing/travelling surfaces. Reduced Motion and
inactive/covered scenes keep the preparation cover until ready, then settle;
changing policy during travel settles immediately. Stacked or missing geometry
has no horizontal shared column and also settles directly after preparation.

## Sprint validation boundary

The original recording was decoded and inspected; this is pre-fix evidence,
not visual verification of the changed animation. Per the user's Sprint scope,
no tests were added or run, no replay or manual application scenario was run,
and no remote PR/CI was requested. Validation consists of source review,
diff/static checks and a native `Mokusei` product build.

The rendered handoff, text reflow at reader replacement, native/WebKit clipping,
focus, rapid navigation, stacked layout, Reduce Motion and resize during travel
remain unverified at runtime. Build success cannot certify those behaviors.
The change avoids the Report expansion implementation, which is being integrated
separately. The detached commit is supplied for caller-owned integration into
local main.
