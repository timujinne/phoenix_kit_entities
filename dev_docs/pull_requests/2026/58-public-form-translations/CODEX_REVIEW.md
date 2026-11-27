# PR #58 review

Reviewed locale resolution, field wording, controller flashes, catalogue coverage and the builder's save path at `4691c08`, together with PR #57.

- **BUG - MEDIUM.** The primary text fields relied on a blur event. Submitting with Enter while still in the field could discard the final edit because Save ignored those posted values.
- **BUG - MEDIUM.** Clearing the primary submit label or success message suppressed its built-in default, leaving a blank button or flash.
- **BUG - MEDIUM.** The combined changes lacked German and French translations for Turnstile's visitor-facing messages.
