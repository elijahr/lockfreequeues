---
description: "Comprehensive Axiomantic compliance validation using Four-Pillar assessment"
---
# Axiomantic Compliance Check (AxiCheck)
Performing a comprehensive Axiomantic compliance sweep.

## Compliance Assessment Process
### 1. Recent Changes Analysis
- ID all significant code changes, impls, or modifications in current session/workspace
- Focus on files created, edited, or modified recently
- Prioritize user-created content over generated boilerplate

### 2. 4-Pillar Validation Framework
Apply systematic [4-Pillar Validation](../instructions/base.instructions.md#four-pillar-validation) across all pillars for each ID'd change:
1. **Coding Stds Validation**-Style, quality, error handling, perf, sec
2. **Doc Completeness Validation**-API docs, examples, README, comments, architecture
3. **Proj Pattern Consistency Validation**-Existing patterns, org, naming, imports, conf
4. **Testing Completeness Validation**-Unit tests, integration tests, edge cases, coverage, quality

### 3. Instruction Compliance Check
- Verify adherence to [Pro Dialogue Stds](../instructions/base.instructions.md#professional-dialogue-standards)
- Check compliance w/file-specific instruction stds
- ID any violations of user or proj overrides
- Validate against import assumptions & shell cmd guidelines

### 4. Compliance Report Generation
#### For Each File/Change Assessed:
**File**: `path/to/file.ext`
**Status**: ✅ COMPLIANT | ⚠️ ISSUES FOUND | ❌ NON-COMPLIANT
**4-Pillar Assessment**:
- **Coding Stds**: ✅/⚠️/❌ [Brief findings]
- **Doc**: ✅/⚠️/❌ [Brief findings]
- **Proj Patterns**: ✅/⚠️/❌ [Brief findings]
- **Testing**: ✅/⚠️/❌ [Brief findings]
**Issues ID'd** (if any):
1. [Specific issue w/pillar ref]
2. [Specific issue w/pillar ref]
**Recommendations**:
1. [Actionable improvement w/pillar ref]
2. [Actionable improvement w/pillar ref]

#### Overall Compliance Summary:
**Compliance Score**: X/Y files fully compliant
**Critical Issues**: X issues req immediate attention
**Improvement Opportunities**: X suggestions for enhancement
**Priority Actions** (if issues found):
1. **High Priority**: [Critical fixes needed]
2. **Medium Priority**: [Important improvements]
3. **Low Priority**: [Nice-to-have enhancements]

### 5. Post-Assessment Guidance
If non-compliance found:
- Provide specific, actionable remediation steps
- Ref relevant Axiomantic instruction sections
- Suggest validation checkpoints for fixes
- Offer to help impl corrections
If fully compliant:
- Acknowledge adherence to Axiomantic stds
- Highlight exemplary practices observed
- Suggest any minor optimizations if applicable

## Execution Guidelines
### Scope Determination
- **Session Changes**: Focus on changes made during current session
- **Recent Commits**: If requested, analyze recent commit changes
- **Specific Files**: User can specify particular files to check
- **Full Proj**: Comprehensive proj-wide assessment if requested
### Assessment Depth
- **Quick Check**: High-level 4-pillar validation
- **Detailed Review**: Thorough examination w/specific examples
- **Deep Dive**: Comprehensive analysis w/improvement roadmap
### Output Format
- **Summary First**: Lead w/overall compliance status
- **Details Follow**: Provide specifics for each pillar/file
- **Action-Oriented**: Focus on concrete next steps
- **Ref Links**: Include links to relevant Axiomantic instruction sections

## QA
### Self-Validation
Before delivering compliance report:
- ✅ All recent changes ID'd & assessed
- ✅ 4-pillar validation applied systematically
- ✅ Issues are specific & actionable
- ✅ Recommendations ref appropriate instruction sections
- ✅ Report format is clear & scannable
### Pro Stds
- Be thorough but concise in findings
- Focus on high-impact improvements
- Maintain constructive, critical dialogue tone
- Provide specific examples rather than generic advice
- Ref instruction sections for deeper context
Execute comprehensive Axiomantic compliance assessment based on recent changes & current workspace state.