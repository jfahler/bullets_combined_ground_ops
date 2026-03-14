# README.md Update Plan

## Summary
Update the README.md to accurately reflect the actual code in `scripts/bullets_ground_ops_V09B.lua` and `scripts/bullets_ground_ops_diagnostic.lua`. MOOSE, MIST, and CTLD are external prerequisites (not bundled) and the README should clarify this.

## Discrepancies Found

### Critical Fixes

| # | Issue | Current README | Should Be |
|---|-------|---------------|-----------|
| 1 | **Title** | `# MOOSE Zone Initializer` | `# Bullet's Ground Ops` |
| 2 | **Overview description** | "mission scripting framework...using the MOOSE framework" | Should describe it as "Bullet's Ground Ops" — a plug-and-play ground warfare script for DCS with CTLD support |
| 3 | **Script filename (line 83)** | `scripts/moose_zone_init.lua` | `scripts/bullets_ground_ops_V09B.lua` |
| 4 | **Footer (line 236)** | `*README generated for moose_zone_init.lua*` | `*README for Bullet's Ground Ops*` |
| 5 | **Dependencies section** | Lists MOOSE as "Required" bundled | Should clarify MOOSE, MIST, CTLD are **external prerequisites** that users must load separately |
| 6 | **Trigger setup (line 80)** | `DO SCRIPT FILE -> Moose.lua` | Should clarify this is the user's own MOOSE file, loaded before this script |
| 7 | **Diagnostic script** | Not mentioned at all | Should document `scripts/bullets_ground_ops_diagnostic.lua` |

### Content Accuracy Fixes

| # | Section | Issue |
|---|---------|-------|
| 8 | Features list | Accurate to code — keep but reframe as features of this script |
| 9 | CTLD Integration | Accurate to code — keep but clarify CTLD is an optional external dependency |
| 10 | Configuration Options | Accurate to code — keep as-is, these match CONFIG table |
| 11 | Workflow Diagram | Accurate to code flow — keep |
| 12 | Customization section | Accurate — keep |
| 13 | Credits section | Should mention "Bullet" as author, keep FOOTHOLD/MOOSE credits |

### Structural Changes

1. **Rename title** to "Bullet's Ground Ops"
2. **Add a "Prerequisites / External Dependencies" section** that clearly states:
   - MOOSE framework (required, load first)
   - MIST framework (recommended, not required)
   - CTLD (optional — either MOOSE Ops.CTLD or ciribob CTLD)
   - These are NOT included in this repository
3. **Add "Files in This Repository" section** listing:
   - `scripts/bullets_ground_ops_V09B.lua` — main script
   - `scripts/bullets_ground_ops_diagnostic.lua` — diagnostic/troubleshooting script
4. **Fix all filename references** throughout
5. **Update the trigger setup** to reference correct filenames
6. **Update footer**

## Proposed README Structure

```
# Bullet's Ground Ops
  Overview paragraph

## Features
  ### Core Systems
  ### AI Ground Forces
  ### CTLD Integration (optional)

## Files
  List of scripts in this repo

## Prerequisites
  External dependencies (MOOSE, MIST, CTLD) — not bundled

## Mission Editor Setup
  ### Required Zones
  ### Trigger Configuration (with correct filenames)

## Configuration Options
  (keep existing — accurate to code)

## How It Works
  (keep existing — accurate to code)

## Workflow Diagram
  (keep existing mermaid diagram)

## Diagnostics
  Document the diagnostic script

## Customization
  (keep existing — accurate to code)

## Credits

## License
```
