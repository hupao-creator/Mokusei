# Overview CPU-path measurements

Milliseconds; median of process medians [range].
Not frame latency, application FPS or GPU time.

| Scenario / cards | round1-membership | round2-scopes | Paired change |
| --- | ---: | ---: | ---: |
| fresh-model / 0 | 0.033 [0.021, 0.041] | 0.030 [0.024, 0.045] | -22.4% (5 pairs) |
| catalog-admission / 0 | 0.006 [0.005, 0.006] | 0.006 [0.005, 0.006] | +3.9% (5 pairs) |
| status-update / 0 | 0.010 [0.010, 0.011] | 0.011 [0.010, 0.011] | +1.2% (5 pairs) |
| unchanged-delivery / 0 | 0.010 [0.010, 0.010] | 0.010 [0.010, 0.011] | +3.8% (5 pairs) |
| warm-reconcile / 0 | 0.004 [0.004, 0.004] | 0.004 [0.004, 0.004] | +3.1% (5 pairs) |
| filter-switch / 0 | 0.006 [0.006, 0.007] | 0.006 [0.006, 0.006] | -3.6% (5 pairs) |
| leave-return / 0 | 0.010 [0.009, 0.010] | 0.010 [0.009, 0.010] | -0.4% (5 pairs) |
| keyword-search / 0 | 0.007 [0.007, 0.007] | 0.007 [0.007, 0.007] | -2.5% (5 pairs) |
| fresh-model / 5 | 0.767 [0.685, 0.803] | 0.731 [0.636, 0.792] | -4.7% (5 pairs) |
| catalog-admission / 5 | 0.031 [0.030, 0.033] | 0.034 [0.033, 0.035] | +12.4% (5 pairs) |
| status-update / 5 | 0.122 [0.121, 0.124] | 0.125 [0.120, 0.133] | +3.4% (5 pairs) |
| unchanged-delivery / 5 | 0.057 [0.057, 0.059] | 0.059 [0.057, 0.060] | +1.3% (5 pairs) |
| warm-reconcile / 5 | 0.040 [0.040, 0.042] | 0.041 [0.040, 0.042] | +0.9% (5 pairs) |
| filter-switch / 5 | 0.044 [0.043, 0.050] | 0.044 [0.043, 0.050] | -0.0% (5 pairs) |
| leave-return / 5 | 0.012 [0.012, 0.013] | 0.013 [0.012, 0.013] | -0.8% (5 pairs) |
| keyword-search / 5 | 0.062 [0.059, 0.064] | 0.062 [0.061, 0.068] | +0.1% (5 pairs) |
| fresh-model / 30 | 4.859 [4.605, 4.926] | 3.327 [3.173, 3.560] | -31.1% (5 pairs) |
| catalog-admission / 30 | 0.076 [0.075, 0.084] | 0.077 [0.075, 0.099] | +2.0% (5 pairs) |
| status-update / 30 | 0.376 [0.372, 0.379] | 0.374 [0.370, 0.408] | +0.2% (5 pairs) |
| unchanged-delivery / 30 | 0.274 [0.273, 0.284] | 0.278 [0.271, 0.291] | +1.2% (5 pairs) |
| warm-reconcile / 30 | 0.215 [0.214, 0.220] | 0.218 [0.215, 0.239] | +0.5% (5 pairs) |
| filter-switch / 30 | 0.169 [0.164, 0.175] | 0.173 [0.162, 0.177] | +2.4% (5 pairs) |
| leave-return / 30 | 0.028 [0.028, 0.029] | 0.029 [0.027, 0.030] | +1.0% (5 pairs) |
| keyword-search / 30 | 0.327 [0.269, 0.348] | 0.332 [0.303, 0.363] | -4.4% (5 pairs) |
| fresh-model / 100 | 19.033 [18.400, 20.133] | 11.002 [10.387, 11.216] | -41.1% (5 pairs) |
| catalog-admission / 100 | 0.256 [0.209, 0.287] | 0.234 [0.202, 0.282] | -8.8% (5 pairs) |
| status-update / 100 | 1.132 [1.057, 1.283] | 1.086 [1.040, 1.147] | -3.3% (5 pairs) |
| unchanged-delivery / 100 | 0.935 [0.901, 0.964] | 0.905 [0.885, 0.925] | -4.2% (5 pairs) |
| warm-reconcile / 100 | 0.728 [0.721, 0.737] | 0.723 [0.721, 0.750] | -0.5% (5 pairs) |
| filter-switch / 100 | 0.466 [0.463, 0.471] | 0.462 [0.452, 0.469] | -0.2% (5 pairs) |
| leave-return / 100 | 0.077 [0.075, 0.080] | 0.077 [0.074, 0.081] | -0.6% (5 pairs) |
| keyword-search / 100 | 1.014 [0.896, 1.114] | 0.961 [0.918, 1.005] | -0.9% (5 pairs) |
| fresh-model / 500 | 92.607 [92.394, 95.351] | 54.063 [53.959, 54.866] | -41.6% (5 pairs) |
| catalog-admission / 500 | 1.147 [1.042, 1.484] | 1.167 [1.118, 1.187] | -1.1% (5 pairs) |
| status-update / 500 | 5.614 [5.459, 5.913] | 5.709 [5.474, 5.780] | +2.2% (5 pairs) |
| unchanged-delivery / 500 | 5.204 [4.904, 5.463] | 4.883 [4.793, 5.145] | -3.5% (5 pairs) |
| warm-reconcile / 500 | 4.085 [3.837, 4.320] | 4.035 [3.941, 4.331] | -1.2% (5 pairs) |
| filter-switch / 500 | 2.239 [2.167, 2.269] | 2.153 [2.130, 2.312] | -3.8% (5 pairs) |
| leave-return / 500 | 0.332 [0.320, 0.347] | 0.327 [0.319, 0.331] | -1.4% (5 pairs) |
| keyword-search / 500 | 4.884 [4.820, 4.965] | 5.048 [4.793, 5.305] | +3.2% (5 pairs) |
| layout-initial / 5 | 0.023 [0.023, 0.024] | 0.022 [0.022, 0.024] | -2.9% (5 pairs) |
| layout-resize / 5 | 0.031 [0.030, 0.031] | 0.030 [0.029, 0.031] | -4.5% (5 pairs) |
| layout-initial / 6 | 0.036 [0.034, 0.036] | 0.034 [0.033, 0.036] | -4.3% (5 pairs) |
| layout-resize / 6 | 0.949 [0.918, 1.067] | 0.970 [0.932, 1.038] | +1.5% (5 pairs) |
| layout-initial / 12 | 0.028 [0.028, 0.029] | 0.029 [0.028, 0.030] | +0.3% (5 pairs) |
| layout-resize / 12 | 0.046 [0.046, 0.047] | 0.047 [0.045, 0.049] | +1.1% (5 pairs) |
| layout-initial / 30 | 0.093 [0.091, 0.095] | 0.092 [0.091, 0.096] | -0.7% (5 pairs) |
| layout-resize / 30 | 0.141 [0.139, 0.231] | 0.150 [0.143, 0.182] | +3.3% (5 pairs) |

Exclusions (raw samples retained):

None detected by the sampled compiler/test and thermal gates. Other system activity remains uncontrolled.
