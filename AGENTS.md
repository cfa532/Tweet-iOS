# Repository Instructions

- Before changing code, consider multiple plausible fixes and choose the one with the smallest coherent scope.
- Prefer removing or simplifying conflicting logic before adding new state, variables, flags, or branches. Minus first, addition second.
- When a fix needs new code, keep it directly tied to the observed bug and avoid broad refactors unless they are required for correctness.
- Find root cause of a bug first before fixing it.
- Review the user's requested change before implementing it. If it may remove important recovery behavior, degrade reliability, or create other negative side effects, call that out and challenge the request before editing.
