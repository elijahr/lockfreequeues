---
applyTo: "src/**/*,examples/**/*,tests/**/*,*.nim,*.nims,t_*.nim,test.nim"
---
# Src Code Stds & Architecture
## II. DEV STDS
### Code Stds
#### Style & Quality
- Follow estab style guides for your lang
- Use consistent formatting & indentation
- Write self-documenting code w/clear variable names
- Avoid magic numbers & hardcoded values
#### Perf & Maintainability
- Optimize for readability first, perf second
- Use appropriate data structures for the task
- Consider memory usage & algorithmic complexity
- Write modular, reusable code
#### Error Handling
- Handle errors gracefully w/meaningful messages
- Use lang-specific error handling patterns
- Don't suppress errors w/o good reason
- Log errors appropriately for debugging
#### Refactoring & Automation
- Before writing regex fix-up scripts: Test patterns on sample text first, use specific non-greedy patterns, & avoid broad exclusions like [^"] that break on legitimate content. Always include dry-run mode, preserve original content, & validate syntax before running on all files.
##### Comment Cleanup
**When user requests to clean up comments in proj:**
1. **Extract All Comments**: Write a shell cmd that will find all comments & docstrings in the proj (exclude .venv or other such pkg dirs) & write the comments to a file, including the file & line number.
2. **Analyze Each Comment**: Go over each comment & determine if it does any of the following:
   - **Explains a change to the code**-More of a CHANGELOG type of comment w/i the code
   - **Makes ref to Phases** of some impl plan
   - **States the obvi**-If the code below it or next to it is readable & self-explanatory, we don't need the comment
3. **Doc Violations**: Create a doc in `.tmp/` detailing all of those violations
4. **Confirm w/User**: Present the analysis & get approval before making changes
5. **Execute Cleanup**: Start deleting the bad comments in batches
#### Code Comment Stds
**NEVER write comments that ref time, sessions, or dev phases:**
❌ **Forbidden comment patterns:**
- "Phase 1 impl"
- "Added in this session"
- "Changed to fix issue"
- "Updated per reqs"
- "TODO: Phase 2"
- "Modified during refactor"
- Refs to "steps", "phases", "sessions", "changes", "updates"
✅ **Write comments about the code as it exists:**
- Explain complex algorithms & business logic
- Doc why decisions were made (not when)
- Clarify non-obvi behavior
- Explain the purpose of functions & classes
- Avoid obvi comments
- Don't write comments unless they will be useful to a dev reading the code for the first time
**Comment about the code's current state & purpose, never its dev history.**
#### Lang-Specific Patterns
- Use idiomatic constructs for your lang
- Leverage lang features appropriately
- Follow estab conventions
- Use static analysis tools when available
### Architecture Design
#### Sys Design Principles
- Design for maintainability, extensibility, & scalability
- Use appropriate design patterns
- Plan for failure scenarios & sec from the start
#### Component Relationships
- Define clear interfaces between components
- Minimize coupling between modules
- Use dependency injection where appropriate
- Doc component interactions
#### Planning & Impl
- Break down complex problems, consider non-functional reqs
- Follow [Planning Stds](#planning-stds) below for detailed planning
#### Best Practices
- Follow estab architectural patterns
- Consider perf implications
- Plan for monitoring, observability, sec, & failure scenarios
- Doc architectural decisions
### Debugging Methodology
#### Systematic Approach
- Reproduce the issue consistently
- Isolate the problem area
- Form hypotheses about the cause
- Test hypotheses systematically
#### Data Collection
- Gather relevant logs & error messages
- Doc the env & conditions
- Create minimal test cases
- Use debugging tools effectively
#### Root Cause Analysis
- Look beyond symptoms to underlying causes
- Consider multiple potential causes
- Use scientific method for investigation
- Doc findings for future ref
#### Problem Resolution
- Fix the root cause, not just symptoms
- Test the fix thoroughly
- Consider impact on other parts of the sys
- Update doc & tests as needed
---
## III. PROJ MGMT
### Self-Validation Stds
#### After Every Major Impl Step
After completing any significant code change, impl, or milestone, apply [4-Pillar Validation](base.instructions.md#four-pillar-validation).
#### Self-Validation
**For each validation pillar:**
1. **Review**-Check code against specific criteria
2. **ID gaps**-Be brutally honest about shortcomings
3. **Fix immediately**-Don't postpone validation fixes
4. **Doc validation**-Note what was checked & confirmed
**Example Self-Validation Comment:**
```
# Self-Validation Checkpoint:
# ✅ Coding Stds: Follows proj style, proper error handling
# ✅ Doc: Docstrings added, README updated
# ✅ Proj Patterns: Consistent w/existing service structure
# ✅ Testing: Unit tests added, edge cases covered
```
#### When to Validate
- After impl features, refactoring, or bug fixes
- Before committing significant changes
- At completion of plan milestones
### Planning Stds
All non-trivial work must be planned & documented BEFORE impl begins.
#### Planning
1. **Step Back & Survey**: Read relevant files, understand architecture, ID components, note constraints
2. **Internal Dialogue**: Question the problem, approaches, risks/trade-offs, sys interactions
3. **Context-Informed Planning**: Reflect codebase patterns, infrastructure, team practices, realistic scope, apply 4-Pillar Validation
4. **Plan Validation**: Review against codebase, check assumptions, ensure actionable/specific, consider alternatives
#### Planning Hierarchy
1. **ROADMAP.md**-Major features, significant refactoring, multi-phase projs
2. **README.md (Roadmap Section)**-Proj-level planning & feature roadmaps
3. **Tmp Plan Files**-All other planning (create `.tmp/`, ensure in `.gitignore`)
#### Plan Template
```markdown
# [Feature/Task] Impl Plan
## Overview: [Brief desc of what/why]
## Validation Integration: Stds, Docs, Patterns, Testing strategy
## Phases: Planning/Setup → Core Impl → Integration/Testing
## Success Criteria & Risks: [Functionality works, passes validation | Risk mitigation]
```
#### Plan Mgmt
**Complexity Guidelines**: Simple (<1hr) = inline validation; Medium (1-4hr) = .tmp plan; Complex (>4hr) = ROADMAP.md
**Plan Discovery**: Check for existing plans (ROADMAP.md > PROJECT_PLAN.md > README roadmap > TODO.md). Ask user which to follow if multiple found.
**User Intent Signals**:
- "No plan"/"ignore plans" → DISABLED
- "Pause plan" → PAUSED
- "Resume plan" → ACTIVE
- "Done w/plan" → COMPLETED
**Progress Tracking**: Auto-update completion status, mark completed items, update progress indicators, ref current status in responses
### Plan Creation Guidance
For substantial tasks w/multiple phases, prompt user: "This looks like a substantial task w/multiple phases. Would you like me to create a proj plan/roadmap first to track our progress? This helps ensure we don't miss steps & makes it easier to resume work later."
### Milestone & Commit Mgmt
**After completing significant milestones or plan phases:**
- **Self-validate first**: Complete all 4 validation pillars before considering milestone complete
- **Prompt user to commit**: "This completes [milestone/phase]. All validation pillars checked. Would you like to commit these changes before continuing?"
- **Use conventional commit format**: `feat:`, `fix:`, `docs:`, `refactor:`, etc.
- **Include validation confirmation**: "Validated: stds ✅, docs ✅, patterns ✅, testing ✅"
- **Break large changes into logical commits** when working through multi-step plans
#### Commit Message Templates
**For validated milestones:**
```
feat: impl user auth sys
- Add JWT token generation & validation
- Create user login/logout endpoints
- Add password hashing w/bcrypt
- Include comprehensive unit tests (95% coverage)
Validated: coding stds, doc, proj patterns, testing
```
**For validation fixes:**
```
refactor: improve code stds compliance
- Fix inconsistent naming conventions
- Add missing error handling
- Update doc for clarity
- Ensure test coverage for edge cases
Self-validation: all 4 pillars verified
```
