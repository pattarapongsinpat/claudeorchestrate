# Spec: Thread-safe token-bucket rate limiter

## Goal
A reusable `TokenBucket` class for throttling calls to an API client.

## Interface
- `TokenBucket(rate: float, capacity: float)`
  - `rate`: tokens refilled per second.
  - `capacity`: max tokens the bucket holds (burst size).
- `acquire(tokens: float = 1.0, blocking: bool = True, timeout: float | None = None) -> bool`
  - Attempts to consume `tokens`.
  - If enough tokens are available, consume them and return `True` immediately.
  - If not and `blocking=True`, sleep until enough tokens accrue (respecting
    `timeout`), then consume and return `True`. If `timeout` elapses first,
    return `False` and consume nothing.
  - If `blocking=False`, return `False` immediately when short, consuming nothing.
- `available() -> float`: current token count (after a lazy refill).

## Behavior
- Lazy refill: compute accrued tokens from elapsed wall-clock time on each call,
  cap at `capacity`. Use a monotonic clock.
- Thread-safe: all state mutations under a single lock. Do not hold the lock
  while sleeping.
- No busy-waiting: sleep for the computed deficit duration, not a spin loop.

## Constraints
- Standard library only (`threading`, `time`).
- `tokens` must be <= `capacity`; raise `ValueError` otherwise.
- Type hints throughout. Module-level docstring plus a short usage example
  under `if __name__ == "__main__":`.

---

*Note on context:* this example is greenfield — it depends on no existing code, so it
needs no attachments. When a spec **does** touch existing code, do not describe, excerpt,
or summarize that code in the spec: attach the real files at dispatch with `-c`
(repeatable) — one per file the task touches or depends on — and refer to them by name.
The dispatcher sees only this spec plus what you attach, and cannot go find context itself.
