# High-risk review workflow

Invoke only after `verify-change` has returned a valid verdict with `ok == true`.

1. Use the validated triage category, never the source Problem category,
   severity, or adapter identity. A null or out-of-domain triage category emits
   a warning and is treated as non-high-risk. High-risk configuration is parsed
   and domain-checked at startup; its default is `incident`.
2. If the triage category is not configured high-risk, return success without
   creating a review context.
3. Otherwise create a fresh ResolverAgent context in `review` mode. Provide
   only the change diff and acceptance criteria. Do not include problem data,
   generation history, logs, Oracle evidence, or prior contexts.
4. If `approved` is not exactly boolean true, submit `ReviewRejectEvent`,
   revert the applied change, and report a failed attempt to the parent
   workflow. Otherwise return approval so the parent may archive the change.
