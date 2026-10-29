# Eight-card screenshot replay

The second screenshot contains eight cards occupying nine grid cells. Its exact
footprint/position reconstruction is `ABC / DEE / F.. / G.H`, a 3×4 envelope at
75% occupancy. This differs from the earlier seven-card, two-wide-card fixture.

| ID | Visible title | Presentation | Grid origin | Footprint |
| --- | --- | --- | --- | --- |
| A | 报告卡片归档按钮点击区域 | Report | (0, 0) | 1×1 |
| B | Overview 卡片布局空洞修复 | Report | (1, 0) | 1×1 |
| C | Overview 搜索栏外观与光标 | Report | (2, 0) | 1×1 |
| D | Landing 输入框修复与集成状态 | Report | (0, 1) | 1×1 |
| E | 修复 Thread Detail 加载文案居中 | Ordinary Agent Thread with Git extension | (1, 1) | 2×1 |
| F | 滚动条导致阅读内容跳动的修复 | Report | (0, 2) | 1×1 |
| G | 设置页动画修复与验证边界 | Report | (0, 3) | 1×1 |
| H | 历史入口位置修复 | Report | (2, 3) | 1×1 |

A–H are fixture identifiers, not recovered Runtime identities. E visibly shows
`00:06:44`, `1.7M`, four files, `+16 −7` and `fix/thread-loading-center`.
Elapsed time is also shown for ended executions, so its running/completed and
attention states remain unknown. Reports do not participate in attention
carousel eligibility; E's eligibility is unknown. The solver consumes only
identity and outer footprint, so neither eligibility nor execution state is
invented for this replay. Report age, preview text and relation counts do not
change the production report's fixed 1×1 footprint. No user database or profile
is read.

The original PNG is 3066×2370 pixels. Headless ImageIO/CGImage edge measurements
give approximately these bounds (±2px; rounded corners measured at edge centers):

| Coordinate | Observed pixel edges |
| --- | --- |
| Column 0 | x≈45…940 |
| Column 1 | x≈984…1879 |
| Column 2 | x≈1923…2818 |
| Row 0 | y≈66…561 |
| Row 1 | y≈605…1101 |
| Row 2 | y≈1144…1640 |
| Row 3 | y≈1684…2179 |

The approximately 939×539px pitch agrees with the production 376×216 world
pitch at about 2.497 pixels per world point. Unit cards measure about 896×496px;
E measures about 1835×496px. The production envelope is 1112×848 world points.
The screenshot omits window boundaries and may be cropped; these measurements
do not establish viewport points, backing scale, camera/manual state, or the
application build being shown.

## Original PR result

Production sources from PR #166 head
`15f2c181cb3c191569d648eab7acd52ea8c36b96` were compiled unchanged with the
additional fixture. The original evidence is retained locally under
`/private/tmp/overview-layout-second-original`, including complete source inputs
and `before-regression.json`. With the existing representative readable
1420×1100-point viewport, the original PR solver returns:

| Card | Before | After | Travel |
| --- | --- | --- | --- |
| A–E | Observed positions/footprints | Unchanged | 0 |
| F | (0, 2) | (1, 2) | 376 world points |
| G | (0, 3) | (0, 2) | 216 world points |
| H | (2, 3) | (2, 2) | 216 world points |

The result is `ABC / DEE / GFH`, a full 3×3 grid, with total travel 808 and
certified move order `[F, G, H]`. F moves right first to release G's vertical
path; simply lifting the bottom reports would collide with stationary F.
Search completes in 12,249 steps without `requiresRepack`. A fresh layout also
uses 3×3 (518 steps); replaying the repaired positions takes zero search steps.
At a 200-step budget, the smaller legal 3×3 witness survives with incomplete
search and `requiresRepack`.

The current PR therefore already covers this geometry when planning runs. No
additional production fix is supported by this fixture. The new regression
assertions preserve its exact membership, E's 2×1 footprint, A–E anchors, the
three moves, their order, total travel and stable replay. A deletion boundary
also removes synthetic reports from the three observed vacancies; this is a
possible structural history, not the actual event order reconstructed from the
image.

A separate two-case check compiled main revision
`14e8ffb7f0d2769ea71ed4392115005afcd40bbb` with the same driver through its
history/fresh calls. Raw compiler inputs, a source-revision/hash manifest and
`results.json` are retained in `/private/tmp/overview-layout-second-main`.
Main keeps the observed history at 3×4 with zero search steps; the PR repairs it
to 3×3 as above. Fresh planning already produced 3×3 on both revisions in 518
steps. This isolates the PR's correction to preserving a reducible historical
envelope rather than changing initial packing.

## Reproduction and scope

```sh
python3 tools/verification/overview-layout/run.py \
  --baseline 15f2c181cb3c191569d648eab7acd52ea8c36b96 \
  --output /private/tmp/overview-layout-second-final
```

The final command passes all 15 original comparison scenarios and 37 regression
scenarios, with three deterministic runs per version. Production geometry is
unchanged from the original PR head; this follow-up adds fixture coverage and
documentation only.

The replay uses the same readable/natural extent calculations as Canvas for
representative 1420×1100, 1420×1280, 1920×1200 and 1920×1350 viewports. Separate
cases use an exact 1112×848 fitting envelope and a slightly larger 1150×900
envelope. These are declared inputs that can hold the observed collection;
they are not camera or viewport measurements inferred from the cropped image.
Every resulting certified move order is independently sampled against survivor
rectangles after exits/shrink. JSON retains the fitting extents and results.

This command compiles pure production solver/camera geometry and launches no
application, window or graphical test. It distinguishes three paths:

- Fresh planning has no historical positions and produces a compact 3×3 grid.
- Structural planning receives the observed placements as history and repairs
  them with the three certified moves above.
- Settled Canvas updates with the same scene, identical identities/footprints,
  no layout error or pending presentation transitions, and either an unchanged
  viewport or still-readable existing bounds after resize reuse geometry without
  invoking the solver. Source inspection establishes this branch's conditions;
  this headless solver replay does not mount Canvas or prove that the screenshot
  entered that branch.

Neither the image nor this replay establishes the application's actual revision
or event sequence. The headless result cannot certify rendered transitions,
mounted camera lifecycle or the live screenshot's state.
