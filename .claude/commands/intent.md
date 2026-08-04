Convert the request into an intent artifact. Write `.pipeline/intent.md`,
then `.pipeline/intent.json` with the same content as structured data.

Verbatim copy of the original request goes in `.pipeline/request.txt` first —
unmodified, no interpretation. Later stages compare against it.

A request often does not stand on its own — "do it", "fix that too", "same as
before", a pronoun pointing at earlier conversation. Two later stages read this
file and nothing else: the assumption check grades the intent against it, and
the final verifier decides ACCEPT or DRIFT against it. Both would be judging the
word "it". So `request.txt` must be self-contained before the run starts, and it
must become so out of the user's words rather than yours.

Ask, in one round, one to three questions. This is the only stage that may ask
and the only round it gets.

The first question is mandatory and is always what to build. Ask it even when
the request looks obvious. Every later stage inherits the Goal — the assumption
check grades against it, the tests are written from it, the final verdict is
rendered against it — so a wrong goal is the one error the pipeline cannot
catch: each stage agrees with the one before it and they are wrong together.
This question is the only place that is checked, and it is worth a stop on every
run.

Spend the other two only when the answer would change what gets built: what the
request points at, which of two readings is meant, a value that has no ordinary
default. Do not spend one on something the request settles, on a preference with
a sensible default, or on implementation detail. One question is a normal round.

Every question is multiple choice, asked with `AskUserQuestion` in a single call
so all three arrive at once. Each carries two to four concrete options, and each
option says what will actually be built if it is picked — "retry three times,
then report the upload as failed", not "sensible default". Put the option you
recommend first and mark it `(Recommended)`. Never write an "Other" option;
the tool supplies one, and that is the escape hatch for an answer you did not
anticipate.

For the optional two, a question with no real options is a question you should
not be asking. If you cannot name two things the user might plausibly want,
either the request already settles it, or the choice does not change what gets
built — assume and move on.

The mandatory first question is never "is this right?". Its options are the
readings of the request actually in play, each stated as the outcome it would
produce, so picking one settles the Goal. Lead with your reading, marked
`(Recommended)`; the others are the next most plausible readings, and a clear
request still has them — a narrower scope, a wider one, a different place to put
the change. When a request is so plain that the alternatives are strained, say
so in the option text rather than inventing a rival: the user should be able to
confirm in one click, and Other is there for the reading you missed.

Then write the answers into `request.txt` verbatim, as the user gave them: the
option they picked, or their own text when they chose Other.

```
## Request
do it

## Clarifications (verbatim)
Q: What should "do it" implement?
A: The uploader retry discussed above
Q: How many attempts before an upload is reported as failed?
A: Other — two, the endpoint is slow
```

Record the option's own words, not your restatement of them, and mark an Other
answer as one so a later stage can see the user wrote it rather than picked it.

When `.campaign/unit_request.txt` exists and `.campaign/state.json` has
`"status": "running"`, this run is one unit of a campaign. Copy that file to
`request.txt` verbatim and ask nothing. The campaign asked its question round
once, before any unit ran, and its answers are in the brief block that file
already carries. Asking again per unit would be the same round repeated with the
run already committed to a decomposition, and the answer could no longer change
the backlog. Leave the block that marks the unit text as the pipeline's
decomposition in place: the assumption check and the final verifier read this
file and nothing else, and that marker is what tells them which part of it you
wrote.

When you cannot ask — an unattended run, no interactive channel — quote the
conversation turns the request points at instead, under
`## Referenced context (verbatim)`, in the same file. Quote, never summarize.
Note in that block that the goal went unconfirmed, because the run is then
missing the one check on the goal and whoever reads the result should know it.
When there is nothing to quote either and the request still needs a decision it
does not carry, HALT.

Nothing in this file may be your reading of the request. A paraphrase would
launder the interpretation the later stages exist to test. A self-contained
request that was confirmed needs no extra block beyond its clarifications.

# Goal
One sentence. Observable outcome, not implementation.

# Assumptions
Everything inferred but not stated. Be exhaustive; this list is the
main failure surface now that no human confirms it.

# Non-goals
Explicit prohibitions. Be aggressive. Name modules not to touch, patterns
not to introduce, dependencies not to add. Vague non-goals do nothing —
"don't over-engineer" is useless, "do not add a caching layer" works.

# Allowed files
Paths that may be written. Narrowest set that could satisfy the goal.
Include files that do not exist yet and must be created, at their exact
intended path — a path absent from this list can never be written, and a coder
that needs an undeclared file has no way to ask for it. Directories are created
as needed.
The identical list MUST appear as `allowed_files` in intent.json, which is
authoritative — plan and gate read the JSON, not this prose. Keep them equal.

# Ambiguities
Each: description, the interpretations available, which was chosen, why.

# Verification
`mode: tests` by default. Use `mode: judgment` only when observable behavior
requires a host, hardware, or proprietary runtime that is unavailable to the
pipeline, such as a BepInEx game process. Record a concrete `reason`. Missing
dependencies, a broken suite, or tests that are merely difficult are not valid
reasons. The structured form is
`"verification":{"mode":"tests|judgment","reason":"..."}`. Omit `reason`
for test mode.

Judgment mode keeps available compilation checks but requires Opus review and
isolated final verification.

# Blockers
Proceed by default. A missing decision blocks; a missing detail is an
assumption. Ask before you halt: a blocker you can put to the user in one of
your three questions is not a blocker. Write `.pipeline/HALT` with the open
questions only when the answer is unavailable — the questions are spent, or
nobody is there to answer.

Do not grade your own confidence. A self-reported adjective is chosen by the
same session it is meant to check, and nothing in the run contradicts it, so
`medium` cost nothing and measured nothing. Assumptions is the artifact under
test instead, and the next stage sends it to a different model with the request
and nothing else. Every ambiguity must therefore be resolved
explicitly there, in the request's own terms — an assumption a reader with only
the request in front of them cannot trace back to it is the one that comes back
`UNSOUND`.
