# Specification Quality Checklist: Bounded checks

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-10-22
**Feature**: [spec.md](../spec.md)

## Content Quality

- [x] No implementation details beyond the existing interface it changes (`check.sh`, section files, the two documents)
- [x] Focused on the owner's value (no run hangs, costs are visible, the machine stays cool)
- [x] Written for its one stakeholder, the owner, who maintains the shell
- [x] All mandatory sections completed

## Requirement Completeness

- [x] No [NEEDS CLARIFICATION] markers remain (the one about running a named section was settled with the owner: FR-014)
- [x] Requirements are testable and unambiguous
- [x] Success criteria are measurable (stop latency, no trips over five runs, reported-time tolerance, added overhead)
- [x] Success criteria name no tool or language beyond the existing interface
- [x] Acceptance scenarios are defined for each story
- [x] Edge cases are identified (boundary race, clock start, ignored TERM, daemons, nested runs, busy machine, signals, silent section)
- [x] Scope is clearly bounded (no whole-run budget, no per-check budgets, no override, global CLAUDE.md untouched)
- [x] Dependencies and assumptions identified (006's lock underneath; 004's ordering; rejected alternatives)

## Feature Readiness

- [x] All functional requirements have clear acceptance criteria
- [x] User scenarios cover the primary flows (a hang is bounded, costs are reported, the policy is written)
- [x] Feature meets measurable outcomes defined in Success Criteria
- [x] No implementation details leak into the success criteria

## Notes

- The open marker is the owner's: the policy names "one section" as an
  iteration tier, and `./check.sh` accepts only `--strict` and `--staged`
  (usage line, `check.sh` at c3819e5). Either 007 adds a way to name sections
  (new behaviour, in scope here) or the policy says `--staged` only.
- Not settled by the owner and chosen here: three slowest sections listed; no
  budget override; durations on every run. Recorded under Assumptions.
- Feasibility to prove in the plan's research: FR-004's reach to processes
  whose parent has exited, without process groups (004 rejected `set -m`).
