# Usage accounting

`DemoBudget` retains its historical name for compatibility; it counts attempted requests and completed response tokens, with no local billing cap. Requests are reserved before networking, including attempts that fail or are cancelled. Completed calls use the appropriate endpoint's configured estimate without repricing earlier history.

`UsageStorage` saves to the Atmos application-support directory. On first use it copies the Mouse counter if available, then checks Chosen as a fallback. It never overwrites a destination created by another process. The application owns reading/writing the counter and showing recoverable storage warnings.

The estimates are local constants, not a billing lookup. [Usage tests](../../../Tests/AtmosCoreTests/Usage/README.md) cover overflow, mixed rates, saved formats, and non-overwriting migration.
