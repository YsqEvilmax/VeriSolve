# High-risk review workflow

Run only after verify-change returns a valid VSVerdict with `ok == true`.

1. Use only the controlled TriageAgent category to decide risk; never use the
   source category, severity, or adapter. Read
   `config/verisolve.verification.json#high_risk_categories`; default to
   `incident`. Invalid configured categories fail startup. Null or out-of-domain
   triage category warns and is treated as non-high-risk.
2. For a configured high-risk category, create a fresh ResolverAgent context
   in review mode. Input contains only the diff and the bounded
   `acceptance_criteria` value explicitly extracted from raw. Never include the
   raw container, logs, Oracle evidence, problem context, or generation history.
3. Validate exactly `{approved:boolean, reason:string<=200}`. Resolver review
   cannot change or override the Oracle verdict.
4. If rejected, idempotently revert the change and submit ReviewRejectEvent;
   the coordinator may then consume a solution retry. If approved, allow normal
   archival.
