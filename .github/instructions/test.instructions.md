---
applyTo: "tests/**/*,t_*.nim,test.nim"
---
# Testing Stds
### Testing Stds
#### Testing Approach
- Write tests that verify behavior, not impl
- Use appropriate testing frameworks
- Follow the testing pyramid (unit, integration, e2e)
- Maintain good test coverage
#### Test Quality
- Write clear, readable tests
- Use descriptive test names
- Test edge cases & error conditions
- Keep tests independent & isolated
#### Test-Driven Dev
- Write tests before impl features
- Use tests to guide design decisions
- Refactor w/confidence when tests are in place
- Update tests when reqs change
#### Validation & Verification
- Validate inputs & outputs
- Test error handling paths
- Verify perf reqs
- Check sec & accessibility
### Mandatory Test Quality Stds
#### Never Skip Tests - Always Fix Root Cause
Fix env/dependencies/code - don't use `pytest.skip()`, `@pytest.mark.skip/xfail()`.
**Systematic Approach**: 1) Discovery/Assessment, 2) Infrastructure/Env, 3) Core Impl, 4) Integration, 5) File Org, 6) Framework Issues, 7) Quality/Completeness, 8) Final Validation
**Success Criteria**: `pytest -v` showing 100% pass rate, 0 skips/xfails/errors. Tests pass individually, meaningful assertions, edge case coverage.