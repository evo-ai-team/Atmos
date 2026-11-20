# Usage tests

`DemoBudgetTests` exercises attempted-request accounting, overflow, saved counter compatibility, mixed endpoint rates, and estimates. `UsageStorageTests` uses isolated temporary directories to test first-use migration and preservation of existing counters.

Never point these tests at the user's application-support directory or Keychain. Accounting failures must not disable otherwise authorized requests.
