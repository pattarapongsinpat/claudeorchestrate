Read `.pipeline/request.txt` and the full run diff from
`git diff $(cat .pipeline/run_base)..HEAD`.

Launch a fresh general-purpose subagent with no inherited conversation context.
Give it only:

1. The original request text, copied verbatim.
2. The complete run diff.
3. This question: "Would the person who wrote the request accept this diff?"

Do not give the subagent `intent.md`, `intent.json`, plan artifacts, prior stage
outputs, or your own assessment. The interpretation is under test. The
subagent must return exactly one of:

- `ACCEPT`
- `DRIFT: <specific divergence from the original request>`

Write its response verbatim to `.pipeline/verify.md`. Do not revise or override
the isolated verdict. DRIFT reports an upstream misreading and must not patch
the implementation.
