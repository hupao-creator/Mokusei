# Overview CPU-path measurements

Milliseconds; median of process medians [range].
Not frame latency, application FPS or GPU time.

| Scenario / cards | baseline-c17a3fcb | Paired change |
| --- | ---: | ---: |
| fresh-model / 0 | 0.021 [0.021, 0.022] | — |
| catalog-admission / 0 | 0.005 [0.005, 0.005] | — |
| status-update / 0 | 0.011 [0.011, 0.011] | — |
| unchanged-delivery / 0 | 0.010 [0.010, 0.011] | — |
| warm-reconcile / 0 | 0.004 [0.004, 0.004] | — |
| filter-switch / 0 | 0.006 [0.006, 0.006] | — |
| leave-return / 0 | 0.010 [0.009, 0.010] | — |
| keyword-search / 0 | 0.007 [0.007, 0.007] | — |
| fresh-model / 5 | 0.682 [0.679, 0.685] | — |
| catalog-admission / 5 | 0.032 [0.031, 0.032] | — |
| status-update / 5 | 0.355 [0.353, 0.358] | — |
| unchanged-delivery / 5 | 0.282 [0.280, 0.284] | — |
| warm-reconcile / 5 | 0.044 [0.043, 0.044] | — |
| filter-switch / 5 | 0.048 [0.046, 0.050] | — |
| leave-return / 5 | 0.012 [0.012, 0.013] | — |
| keyword-search / 5 | 0.053 [0.049, 0.057] | — |
| fresh-model / 30 | 4.744 [4.711, 4.777] | — |
| catalog-admission / 30 | 0.078 [0.074, 0.083] | — |
| status-update / 30 | 3.083 [3.049, 3.118] | — |
| unchanged-delivery / 30 | 2.882 [2.848, 2.917] | — |
| warm-reconcile / 30 | 0.235 [0.234, 0.236] | — |
| filter-switch / 30 | 0.164 [0.160, 0.168] | — |
| leave-return / 30 | 0.028 [0.028, 0.029] | — |
| keyword-search / 30 | 0.300 [0.290, 0.310] | — |
| fresh-model / 100 | 18.353 [18.229, 18.478] | — |
| catalog-admission / 100 | 0.225 [0.216, 0.234] | — |
| status-update / 100 | 12.828 [12.815, 12.841] | — |
| unchanged-delivery / 100 | 12.712 [12.651, 12.772] | — |
| warm-reconcile / 100 | 0.750 [0.749, 0.752] | — |
| filter-switch / 100 | 0.455 [0.447, 0.462] | — |
| leave-return / 100 | 0.077 [0.074, 0.079] | — |
| keyword-search / 100 | 0.921 [0.912, 0.930] | — |
| fresh-model / 500 | 92.055 [91.740, 92.371] | — |
| catalog-admission / 500 | 1.076 [0.971, 1.181] | — |
| status-update / 500 | 62.307 [62.282, 62.332] | — |
| unchanged-delivery / 500 | 62.051 [61.925, 62.177] | — |
| warm-reconcile / 500 | 3.998 [3.974, 4.023] | — |
| filter-switch / 500 | 2.152 [2.032, 2.271] | — |
| leave-return / 500 | 0.315 [0.307, 0.322] | — |
| keyword-search / 500 | 4.696 [4.578, 4.813] | — |
| layout-initial / 5 | 0.023 [0.022, 0.024] | — |
| layout-resize / 5 | 0.030 [0.030, 0.030] | — |
| layout-initial / 6 | 0.034 [0.033, 0.034] | — |
| layout-resize / 6 | 0.959 [0.950, 0.969] | — |
| layout-initial / 12 | 0.028 [0.028, 0.028] | — |
| layout-resize / 12 | 0.046 [0.045, 0.046] | — |
| layout-initial / 30 | 0.091 [0.090, 0.093] | — |
| layout-resize / 30 | 0.142 [0.141, 0.142] | — |

Exclusions (raw samples retained):

- r1-baseline-c17a3fcb.json: concurrent compiler/test/probe: swift-frontend
- r2-baseline-c17a3fcb.json: concurrent compiler/test/probe: swift-frontend
- r3-baseline-c17a3fcb.json: concurrent compiler/test/probe: mtlcompilerservi
