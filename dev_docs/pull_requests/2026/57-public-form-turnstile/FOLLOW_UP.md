# PR #57 follow-up

The fallback scans again after LiveView navigation and skips widgets already initialized or owned by core. A tokenless submit preserves the existing recovery message. A Chromium smoke check exercised navigation, duplicate initialization and the submit guard with a stubbed widget. Live Cloudflare verification used a test double throughout the review.

The builder now restricts toggle events to the six supported settings and uses the same Turnstile predicate for rendering and toggling. A LiveView test covers the imported value and the setting-name restriction.
