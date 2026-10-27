# Overview CPU-path measurements

Milliseconds; median of process medians [range].
Not frame latency, application FPS or GPU time.

| Scenario / cards | baseline-c17a3fcb | round1-membership | Paired change |
| --- | ---: | ---: | ---: |
| fresh-model / 0 | 0.028 [0.022, 0.035] | 0.024 [0.021, 0.035] | -2.5% (5 pairs) |
| catalog-admission / 0 | 0.006 [0.005, 0.006] | 0.005 [0.005, 0.006] | -2.2% (5 pairs) |
| status-update / 0 | 0.011 [0.010, 0.011] | 0.011 [0.010, 0.011] | -1.4% (5 pairs) |
| unchanged-delivery / 0 | 0.011 [0.010, 0.011] | 0.010 [0.010, 0.011] | +0.8% (5 pairs) |
| warm-reconcile / 0 | 0.004 [0.004, 0.004] | 0.004 [0.004, 0.004] | +1.0% (5 pairs) |
| filter-switch / 0 | 0.006 [0.006, 0.006] | 0.006 [0.006, 0.007] | +2.6% (5 pairs) |
| leave-return / 0 | 0.009 [0.009, 0.010] | 0.009 [0.009, 0.010] | +0.2% (5 pairs) |
| keyword-search / 0 | 0.007 [0.007, 0.007] | 0.007 [0.007, 0.007] | +2.8% (5 pairs) |
| fresh-model / 5 | 0.710 [0.670, 0.731] | 0.731 [0.684, 0.753] | +2.0% (5 pairs) |
| catalog-admission / 5 | 0.033 [0.032, 0.034] | 0.032 [0.031, 0.033] | -3.2% (5 pairs) |
| status-update / 5 | 0.352 [0.346, 0.360] | 0.125 [0.122, 0.126] | -65.0% (5 pairs) |
| unchanged-delivery / 5 | 0.284 [0.284, 0.293] | 0.059 [0.057, 0.059] | -79.6% (5 pairs) |
| warm-reconcile / 5 | 0.044 [0.043, 0.044] | 0.041 [0.040, 0.042] | -7.1% (5 pairs) |
| filter-switch / 5 | 0.045 [0.043, 0.047] | 0.045 [0.044, 0.045] | -1.1% (5 pairs) |
| leave-return / 5 | 0.013 [0.012, 0.014] | 0.013 [0.012, 0.013] | -2.3% (5 pairs) |
| keyword-search / 5 | 0.048 [0.048, 0.063] | 0.057 [0.049, 0.065] | +5.5% (5 pairs) |
| fresh-model / 30 | 4.678 [4.590, 4.761] | 4.737 [4.610, 4.797] | +0.8% (5 pairs) |
| catalog-admission / 30 | 0.075 [0.073, 0.084] | 0.074 [0.073, 0.075] | +0.1% (5 pairs) |
| status-update / 30 | 3.145 [3.090, 3.170] | 0.376 [0.371, 0.378] | -88.0% (5 pairs) |
| unchanged-delivery / 30 | 2.981 [2.966, 3.003] | 0.275 [0.270, 0.279] | -90.8% (5 pairs) |
| warm-reconcile / 30 | 0.232 [0.232, 0.237] | 0.219 [0.218, 0.224] | -6.2% (5 pairs) |
| filter-switch / 30 | 0.161 [0.160, 0.166] | 0.165 [0.163, 0.171] | +2.6% (5 pairs) |
| leave-return / 30 | 0.028 [0.027, 0.029] | 0.029 [0.028, 0.030] | +3.5% (5 pairs) |
| keyword-search / 30 | 0.302 [0.288, 0.323] | 0.318 [0.294, 0.329] | +3.4% (5 pairs) |
| fresh-model / 100 | 18.292 [17.877, 18.345] | 18.307 [18.181, 18.382] | +0.5% (5 pairs) |
| catalog-admission / 100 | 0.258 [0.198, 0.276] | 0.222 [0.202, 0.254] | -3.3% (5 pairs) |
| status-update / 100 | 12.937 [12.810, 12.980] | 1.090 [1.079, 1.106] | -91.6% (5 pairs) |
| unchanged-delivery / 100 | 12.671 [12.621, 12.758] | 0.902 [0.888, 0.925] | -92.9% (5 pairs) |
| warm-reconcile / 100 | 0.748 [0.739, 0.777] | 0.730 [0.710, 0.742] | -5.0% (5 pairs) |
| filter-switch / 100 | 0.467 [0.439, 0.477] | 0.471 [0.451, 0.497] | +0.9% (5 pairs) |
| leave-return / 100 | 0.074 [0.073, 0.075] | 0.077 [0.074, 0.078] | +3.9% (5 pairs) |
| keyword-search / 100 | 0.915 [0.899, 0.983] | 0.946 [0.898, 1.070] | +5.3% (5 pairs) |
| fresh-model / 500 | 92.416 [91.929, 93.043] | 92.084 [91.100, 93.554] | -0.9% (5 pairs) |
| catalog-admission / 500 | 1.106 [1.006, 1.153] | 1.117 [0.978, 1.135] | -1.6% (5 pairs) |
| status-update / 500 | 62.843 [62.454, 63.617] | 5.453 [5.348, 5.741] | -91.3% (5 pairs) |
| unchanged-delivery / 500 | 62.268 [62.160, 62.281] | 5.018 [4.830, 5.042] | -91.9% (5 pairs) |
| warm-reconcile / 500 | 4.093 [3.878, 4.191] | 3.933 [3.881, 4.072] | -3.9% (5 pairs) |
| filter-switch / 500 | 2.200 [2.150, 2.292] | 2.209 [2.055, 2.241] | +0.9% (5 pairs) |
| leave-return / 500 | 0.319 [0.314, 0.327] | 0.320 [0.309, 0.335] | +1.2% (5 pairs) |
| keyword-search / 500 | 4.725 [4.551, 4.866] | 4.763 [4.649, 5.150] | +2.1% (5 pairs) |
| layout-initial / 5 | 0.023 [0.023, 0.024] | 0.023 [0.023, 0.024] | -1.1% (5 pairs) |
| layout-resize / 5 | 0.031 [0.030, 0.032] | 0.031 [0.030, 0.031] | +0.8% (5 pairs) |
| layout-initial / 6 | 0.035 [0.035, 0.036] | 0.035 [0.033, 0.036] | -4.3% (5 pairs) |
| layout-resize / 6 | 0.998 [0.935, 1.003] | 0.973 [0.957, 1.087] | +2.4% (5 pairs) |
| layout-initial / 12 | 0.028 [0.027, 0.030] | 0.029 [0.028, 0.030] | +3.0% (5 pairs) |
| layout-resize / 12 | 0.046 [0.044, 0.047] | 0.046 [0.045, 0.048] | +1.7% (5 pairs) |
| layout-initial / 30 | 0.093 [0.090, 0.095] | 0.094 [0.093, 0.103] | +3.9% (5 pairs) |
| layout-resize / 30 | 0.144 [0.139, 0.154] | 0.145 [0.142, 0.153] | -0.5% (5 pairs) |

Exclusions (raw samples retained):

None detected by the sampled compiler/test and thermal gates. Other system activity remains uncontrolled.
