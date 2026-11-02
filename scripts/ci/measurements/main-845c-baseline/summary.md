# Actions timing profile

Runs: 1. Outcomes: {"CI: success": 1}

Successful completed runs, latest attempt's newly executed jobs only. Seconds; nearest-rank p90.

| Workflow / scope / job | n | Queue median / p90 | Runner median / p90 | Prepare | Build | Verification commands | Evidence |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| CI / full / Complete coverage | 1 | 15.0 / 15.0 | 7.0 / 7.0 | 2.0 | 0 | 0 | 2.0 |
| CI / full / Determine verification scope | 1 | 3.0 / 3.0 | 6.0 / 6.0 | 2.0 | 0 | 0 | 0 |
| CI / full / Go / Linux | 1 | 3.0 / 3.0 | 105.0 / 105.0 | 17.0 | 16.0 | 47.0 | 1.0 |
| CI / full / Integration / adapters | 1 | 3.0 / 3.0 | 273.0 / 273.0 | 12.0 | 0 | 257.0 | 1.0 |
| CI / full / Integration / runtime | 1 | 3.0 / 3.0 | 179.0 / 179.0 | 12.0 | 0 | 163.0 | 1.0 |
| CI / full / macOS / Native verification | 1 | 4.0 / 4.0 | 2031.0 / 2031.0 | 71.0 | 281.0 | 1670.0 | 5.0 |

Preparation includes checkout, setup, cache and teardown. Verification commands can include compilation and fixture generation;
these are observed step wall times, not pure test CPU time. Other and unattributed runner time remain in JSON.
Job names can span workflow revisions; inspect source SHA and step inventory before treating samples as comparable.
Failed/cancelled/in-progress runs and carried-forward jobs remain in JSON; they are not speedup evidence.
