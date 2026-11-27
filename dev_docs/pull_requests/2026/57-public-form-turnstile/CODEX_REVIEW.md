# PR #57 review

Reviewed the Turnstile widget, submission checks, builder events and statistics at `a438938`, including their interaction with PR #58.

- **BUG - MEDIUM.** The fallback widget scanner ran only at initial document load. A sanitized form inserted by LiveView navigation had no hook to start its widget.
- **BUG - MEDIUM.** Submitting after a script or render failure replaced the recovery instructions with a generic request to wait. The visitor could wait indefinitely.
- **BUG - MEDIUM.** The builder rendered an imported string value of `"false"` as off, but its first click also saved off. The same handler accepted setting names outside the six displayed switches.
