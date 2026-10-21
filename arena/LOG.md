# Arena log

One line per experiment: hypothesis → change → result → decision. Model: Qwen3.8-27B EXL3 via Omarchy Local AI.

| Date | Change | Result | Decision |
|---|---|---|---|
| 2026-10-21 | Baseline T1 (awl 0.1.0, pi 1.3.0, omp 18.12.3, grok 1.0.62) | All 5/5. Median prompt tokens: awl 8.8K, pi 14.7K, omp 43K, grok 90K. Main RSS: awl 0.3 MB, pi 142 MB, omp 345 MB, grok 385 MB. Wall: awl 5.9 s, pi 5.5 s. awl weak on needle (read whole 64 KB file, 98K tokens, 24.7 s) and ledger (CRLF broke exact edit, 11 turns). | Baseline accepted. |
| 2026-10-21 | edit matches CRLF files; read hides \r; read description says grep first in big files; replies start flush; bash returns on command exit (pidfd); context window from /v1/models with old-tool-output elision | e2e 18/18; T2 pending | — |
