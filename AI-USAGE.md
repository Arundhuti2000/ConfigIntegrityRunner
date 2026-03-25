# AI Usage Note

## Tools Used

- **GitHub Copilot** - primary tool for generating and iterating on all code in this submission.

---

## Where AI Helped

### High value / high confidence

- **Module structure scaffold** — AI suggested the `psm1` + `psd1` + thin CLI wrapper pattern immediately. This is the right production shape for reusable PowerShell and the scaffold was correct on the first try.
- **ServiceNow table mapping** — the field naming convention (`u_` prefix for custom fields), the two-table model (run header + drift items), and the recommended Business Rule trigger were all correct and operationally sound.
- **Scoring model** — AI proposed the weighted severity model and partial-credit formula on the first pass. The math is correct. I adjusted the grade bands (switched from AI's initial strict 90% threshold for 'B' to 85%).

### Moderate value

- **Comparison logic (Concept)** — The recursive approach (walk PSCustomObject properties, recurse on nested objects) provided a solid starting point, though the implementation details needed debugging (see _Corrections_ below).
- **GitHub Actions workflow** — the OIDC Azure login block and step structure were correct. I adjusted the artifact versions (`actions/upload-artifact@v3`) for compatibility.

---

## What AI Got Wrong or What I Corrected

1. **Pester Version Compatibility** — AI generated tests using modern **Pester 5** syntax (`BeforeAll`, `New-PesterConfiguration`). However, the target environment/pipeline was running **Pester 3.4.0** (common on default Windows images). I rewrote the test suite to use Pester 3 syntax (`Describe`, `Context`, `It`) to ensure portability without forcing an environment upgrade.

2. **Recursion & Type Safety Bug** — The initial `Compare-ResourceChecks` function used `.AddRange()` on a generic list. This failed at runtime when a nested object (like `Tags`) returned a single PSCustomObject instead of a collection. I fixed this by adding logic to explicitly cast results to a collection before adding them.

3. **Missing Property Handling** — The drafted logic assumed properties defined in `Desired` would exist in `Actual`. I added defensive null checks and `Get-Member` validation to correctly classify missing keys as `MissingProperty` drift rather than throwing runtime errors.

4. **Grade F bound** — AI's initial scoring wrote `{ $_ -lt 50 } { 'F' }` inside the `switch` expression. I simplified this to `default { 'F' }` for cleaner logic.

5. **Boolean serialization edge case** — AI's first draft used direct `$wantedVal -eq $actualVal` comparison. I changed it to normalize both sides to `.ToString()` to prevent edge cases where JSON booleans round-trip differently through PowerShell's type system.

6. **SNOW payload for MISSING resources** — AI's initial implementation skipped MISSING resources in the drift table because they had no "items" to iterate. I added a synthetic single-record path so missing resources explicitly appear in the reporting data.

---

## What I Rejected

- **AI suggested using `Invoke-RestMethod` directly inside `Invoke-ConfigIntegrityCheck`** to POST to ServiceNow inline. Rejected: mixing detection logic with side effects makes the module untestable in isolation. Kept the SNOW concern in a separate function.
- **AI offered to generate a full `Get-AzureActualState.ps1` discovery script**. I declined to include it in this submission to keep the scope focused on the _runner_ logic as requested ("Thin-slice implementations are welcome").
- **AI suggested a `-WhatIf` parameter on the runner**. While standard for PowerShell, this tool is read-only (detect, don't fix), so `-WhatIf` adds complexity with no value here.
