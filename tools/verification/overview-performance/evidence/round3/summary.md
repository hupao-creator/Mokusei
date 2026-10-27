# Overview CPU-path measurements

Milliseconds; median of process medians [range].
Not frame latency, application FPS or GPU time.

| Scenario / cards | round2-scopes | round3-tag-keys | Paired change |
| --- | ---: | ---: | ---: |
| fresh-model / 0 | 0.034 [0.024, 0.039] | 0.030 [0.024, 0.041] | -4.0% (5 pairs) |
| catalog-admission / 0 | 0.006 [0.005, 0.006] | 0.006 [0.006, 0.006] | -0.4% (5 pairs) |
| status-update / 0 | 0.010 [0.010, 0.011] | 0.011 [0.010, 0.011] | +1.2% (5 pairs) |
| unchanged-delivery / 0 | 0.010 [0.010, 0.010] | 0.010 [0.010, 0.011] | +2.0% (5 pairs) |
| warm-reconcile / 0 | 0.004 [0.004, 0.004] | 0.004 [0.004, 0.004] | +1.0% (5 pairs) |
| filter-switch / 0 | 0.007 [0.006, 0.007] | 0.007 [0.006, 0.007] | +0.3% (5 pairs) |
| leave-return / 0 | 0.010 [0.009, 0.011] | 0.010 [0.009, 0.011] | -2.5% (5 pairs) |
| keyword-search / 0 | 0.007 [0.007, 0.007] | 0.007 [0.007, 0.007] | +1.8% (5 pairs) |
| fresh-model / 5 | 0.694 [0.640, 0.715] | 0.646 [0.596, 0.656] | -9.6% (5 pairs) |
| catalog-admission / 5 | 0.033 [0.031, 0.035] | 0.033 [0.030, 0.034] | -3.2% (5 pairs) |
| status-update / 5 | 0.121 [0.121, 0.127] | 0.122 [0.119, 0.123] | -1.8% (5 pairs) |
| unchanged-delivery / 5 | 0.059 [0.056, 0.059] | 0.059 [0.058, 0.060] | +0.3% (5 pairs) |
| warm-reconcile / 5 | 0.040 [0.040, 0.040] | 0.041 [0.040, 0.042] | +2.7% (5 pairs) |
| filter-switch / 5 | 0.045 [0.045, 0.049] | 0.045 [0.044, 0.049] | -2.0% (5 pairs) |
| leave-return / 5 | 0.013 [0.012, 0.013] | 0.012 [0.012, 0.013] | -4.6% (5 pairs) |
| keyword-search / 5 | 0.060 [0.059, 0.065] | 0.063 [0.052, 0.067] | +4.1% (5 pairs) |
| fresh-model / 30 | 3.331 [3.123, 3.422] | 2.871 [2.753, 2.902] | -14.5% (5 pairs) |
| catalog-admission / 30 | 0.085 [0.077, 0.097] | 0.076 [0.074, 0.100] | -12.4% (5 pairs) |
| status-update / 30 | 0.378 [0.372, 0.400] | 0.374 [0.373, 0.382] | +0.3% (5 pairs) |
| unchanged-delivery / 30 | 0.280 [0.271, 0.288] | 0.280 [0.273, 0.289] | -0.6% (5 pairs) |
| warm-reconcile / 30 | 0.218 [0.216, 0.234] | 0.220 [0.215, 0.220] | -1.7% (5 pairs) |
| filter-switch / 30 | 0.173 [0.164, 0.179] | 0.170 [0.166, 0.174] | -0.4% (5 pairs) |
| leave-return / 30 | 0.029 [0.028, 0.030] | 0.028 [0.028, 0.029] | -2.7% (5 pairs) |
| keyword-search / 30 | 0.330 [0.320, 0.351] | 0.295 [0.279, 0.330] | -12.5% (5 pairs) |
| fresh-model / 100 | 10.765 [10.499, 11.626] | 9.179 [8.958, 10.414] | -14.1% (5 pairs) |
| catalog-admission / 100 | 0.204 [0.200, 0.267] | 0.247 [0.217, 0.274] | +8.7% (5 pairs) |
| status-update / 100 | 1.126 [1.085, 1.176] | 1.093 [1.089, 1.129] | -0.6% (5 pairs) |
| unchanged-delivery / 100 | 0.888 [0.874, 0.933] | 0.901 [0.886, 0.955] | +1.5% (5 pairs) |
| warm-reconcile / 100 | 0.724 [0.708, 0.769] | 0.742 [0.730, 0.750] | +2.9% (5 pairs) |
| filter-switch / 100 | 0.463 [0.452, 0.466] | 0.480 [0.443, 0.485] | +3.3% (5 pairs) |
| leave-return / 100 | 0.076 [0.070, 0.078] | 0.075 [0.073, 0.077] | -1.3% (5 pairs) |
| keyword-search / 100 | 0.946 [0.929, 1.037] | 0.969 [0.884, 1.193] | -4.5% (5 pairs) |
| fresh-model / 500 | 53.973 [53.440, 54.541] | 46.579 [46.036, 48.660] | -13.1% (5 pairs) |
| catalog-admission / 500 | 1.038 [1.005, 1.194] | 1.186 [1.044, 1.263] | +8.8% (5 pairs) |
| status-update / 500 | 5.542 [5.472, 5.768] | 5.433 [5.352, 5.615] | -1.2% (5 pairs) |
| unchanged-delivery / 500 | 5.012 [4.928, 5.240] | 4.931 [4.776, 5.108] | -2.8% (5 pairs) |
| warm-reconcile / 500 | 3.976 [3.857, 4.087] | 3.969 [3.889, 4.063] | -0.0% (5 pairs) |
| filter-switch / 500 | 2.131 [2.029, 2.189] | 2.269 [2.044, 2.350] | +3.9% (5 pairs) |
| leave-return / 500 | 0.326 [0.317, 0.338] | 0.318 [0.310, 0.329] | +0.4% (5 pairs) |
| keyword-search / 500 | 4.931 [4.833, 5.838] | 4.784 [4.606, 5.106] | -1.0% (5 pairs) |
| layout-initial / 5 | 0.024 [0.023, 0.024] | 0.023 [0.022, 0.023] | -4.2% (5 pairs) |
| layout-resize / 5 | 0.030 [0.030, 0.031] | 0.030 [0.030, 0.031] | -0.4% (5 pairs) |
| layout-initial / 6 | 0.034 [0.033, 0.037] | 0.035 [0.034, 0.035] | +0.6% (5 pairs) |
| layout-resize / 6 | 0.937 [0.924, 1.008] | 0.963 [0.934, 0.979] | +1.0% (5 pairs) |
| layout-initial / 12 | 0.028 [0.028, 0.029] | 0.028 [0.028, 0.029] | +1.2% (5 pairs) |
| layout-resize / 12 | 0.047 [0.045, 0.048] | 0.046 [0.045, 0.047] | -1.9% (5 pairs) |
| layout-initial / 30 | 0.093 [0.090, 0.095] | 0.092 [0.091, 0.094] | -1.5% (5 pairs) |
| layout-resize / 30 | 0.143 [0.137, 0.154] | 0.144 [0.140, 0.166] | +0.1% (5 pairs) |

Exclusions (raw samples retained):

None detected by the sampled compiler/test and thermal gates. Other system activity remains uncontrolled.
