Read `.pipeline/request.txt` — the ORIGINAL request, not the intent artifact.
Then read the full run diff: `git diff $(cat .pipeline/run_base)..HEAD`.

Question: would the person who wrote that request accept this diff?

Do not consult intent.md while judging. Its interpretation is the thing
under test — checking the diff against it would confirm any misreading
rather than catch it.

Then read `.pipeline/intent.md` Ambiguities. For each: given the finished
implementation, does the chosen interpretation still look right?

Write `.pipeline/verify.md`: ACCEPT, or DRIFT with the specific divergence.
DRIFT means the intent artifact misread the request — report it rather than
patching the code, because the bug is upstream.
