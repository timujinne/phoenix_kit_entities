# PR #58 follow-up

Save reads the four primary text fields from the submit event. Built-in defaults appear as placeholders, and blank stored texts fall through to the default. LiveView and locale tests exercise submitting before blur and resolving blank values.

The German and French catalogues now include Turnstile's wait, retry, outage and initialization messages. A controller regression test submits the same protected form in both languages.

During combined validation, Hex audit flagged the existing db_connection 2.10.2 lock. The lock now resolves 2.10.3.
