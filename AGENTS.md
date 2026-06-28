# Repository Instructions

- Before changing code, consider multiple plausible fixes and choose the one with the smallest coherent scope.
- Prefer removing or simplifying conflicting logic before adding new state, variables, flags, or branches. Minus first, addition second.
- When a fix needs new code, keep it directly tied to the observed bug and avoid broad refactors unless they are required for correctness.
- Find root cause of a bug first before fixing it.
- Review the user's requested change before implementing it. If it may remove important recovery behavior, degrade reliability, or create other negative side effects, call that out and challenge the request before editing.
- After refactoring any code, review the finished change, especially what the refactor might break by checking the impact to callers of the modified code. Write comments to explain the purpose of the refactor whenever necessary.

# Related Projects

- `TweetAppBackend` is the shared backend companion project for this app and its sibling clients.
- It lives at `/Users/cfa532/Documents/GitHub/TweetAppBackend`.
- `Tweet` lives at `/Users/cfa532/Documents/GitHub/Tweet` and also accesses `TweetAppBackend`.
- `TweetWeb` lives at `/Users/cfa532/Documents/GitHub/TweetWeb` and also accesses `TweetAppBackend`.
- When changing API calls, request or response models, authentication, posting, timeline loading, media upload, or sync behavior, consider the shared backend contract and the impact across `Tweet-iOS`, `Tweet`, and `TweetWeb`.
- If backend or sibling project files are needed, ask for read access or have the user attach/open those projects too.
