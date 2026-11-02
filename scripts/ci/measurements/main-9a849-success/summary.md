# Actions timing profile

Runs: 1. Outcomes: {"CI: success": 1}

Successful completed runs, latest attempt's newly executed jobs only. Seconds; nearest-rank p90.

| Workflow / scope / job | n | Queue median / p90 | Runner median / p90 | Prepare | Build | Verification commands | Evidence |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| CI / full / Complete coverage | 1 | 3.0 / 3.0 | 12.0 / 12.0 | 4.0 | 0 | 0 | 4.0 |
| CI / full / Determine verification scope | 1 | 3.0 / 3.0 | 5.0 / 5.0 | 2.0 | 0 | 0 | 0 |
| CI / full / Go / Linux | 1 | 4.0 / 4.0 | 120.0 / 120.0 | 16.0 | 19.0 | 52.0 | 1.0 |
| CI / full / Integration / adapters | 1 | 3.0 / 3.0 | 282.0 / 282.0 | 12.0 | 0 | 266.0 | 1.0 |
| CI / full / Integration / runtime | 1 | 4.0 / 4.0 | 185.0 / 185.0 | 12.0 | 0 | 167.0 | 2.0 |
| CI / full / macOS / Native verification | 1 | 3.0 / 3.0 | 1931.0 / 1931.0 | 73.0 | 272.0 | 1579.0 | 4.0 |

Preparation includes checkout, setup, cache and teardown. Verification commands can include compilation and fixture generation;
these are observed step wall times, not pure test CPU time. Other and unattributed runner time remain in JSON.
Job names can span workflow revisions; inspect source SHA and step inventory before treating samples as comparable.
Failed/cancelled/in-progress runs and carried-forward jobs remain in JSON; they are not speedup evidence.
