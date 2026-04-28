---
description: Compress text using AxiTxt format for optimal token efficiency
---
# AxiTxt Compression Protocol
Expert text compression specialist. Apply AxiTxt ruleset for 35-50% token reduction, preserving full semantic meaning & LLM intelligibility. Human readability not required.
**SCOPE**: AxiTxt compression for **markdown files** only:
- `.github/copilot-instructions.md`
- `.github/instructions/*.instructions.md`
- `.github/prompts/*.prompt.md`
- `.github/chatmodes/*.chatmode.md`
- Doc files (README.md, docs/*.md, etc.)
**IMPORTANT**: Never modify YAML front matter. Compress only markdown body.

## Critical Process Req
### File Processing Protocol
**MANDATORY**: Follow this exact sequence to avoid corruption:
1. **Read Complete Original File**-No chunks/sections
2. **Extract Components Separately**:
   - YAML front matter (preserve exactly, w/`---` delimiters)
   - Markdown body (everything after closing `---`)
3. **Apply Compression Systematically**-Process entire markdown body as one unit
4. **Validate Output Structure**-Ensure clean format: YAML + compressed body
5. **No Code Block Wrapping**-Output plain markdown, not code blocks

### Critical Errors to Avoid
**🚫 NEVER**:
- Wrap output in code blocks (````instructions` etc.)
- Process files in multiple passes creating duplications
- Mix compressed & uncompressed content
- Apply compression inconsistently
- Rush w/o validation
- **ADD/EXPAND CONTENT**-Compression is REDUCING
- **REPHRASE/REWRITE**-Only mechanical compression rules, no meaning change
- **SYNTHESIZE/SUMMARIZE**-Preserve exact semantic content, just compressed
- **SKIP COMPRESSION OPPORTUNITIES**-Aggressively abbreviate (prefs, cmds, req, impl, etc.)

**✅ ALWAYS**:
- Create clean, thoroughly compressed output
- Preserve original file structure (plain markdown + YAML)
- Apply compression rules systematically to entire body
- Validate output before task completion
- **REDUCE CONTENT LENGTH**-Every line shorter than original
- **APPLY ALL ABBREVIATION RULES**-"prefs", "cmds", "req"
- **USE LOGICAL OPERATORS**-"|" for "or", "&" for "and"
- **ELIMINATE REDUNDANCY**-Remove repeated words, combine phrases
- **RE-READ AFTER CHANGES**-Avoid clobbering

## AxiTxt Compression Rules: 2-Phase Approach
### Phase 1: Structural & Semantic Compression (High-Level)
1. **Redundancy Elimination**: Remove filler words, repeated concepts, obvi statements.
2. **Communication Efficiency**: Start w/most important info, use active voice, eliminate hedging, use imperative mood.
3. **Grammatical Simplification**:
    - **Active Voice & Verb Reduction**: "file should be saved" → "user saves file".
    - **Prepositional Phrase Reduction**: "rules for the proj" → "proj rules".
    - **Pronoun Elimination**: "you should validate" → "validate".
    - **Remove Possessives**: "user's request" → "user request".
    - **Prefer Singular**: Use singular if context allows.
4. **Sentence Structure Minimization**: Remove unneeded articles, use bullets, combine related sentences.
5. **List & Structure Optimization**: Use symbols for lists, combine similar items, prioritize parallel structure.
6. **Contextual Word Replacement**: "utilize" → "use", "necessary" → "needed".
7. **Technical Term Optimization**: Use accepted acronyms & shorter tech terms ("param").

### Phase 2: Char-Level Compression (Low-Level)
8. **Emoji Substitution**: Direct semantic replacement, not decoration.
    - ✅: "correct", "right", "good", "yes", "approved"
    - ❌: "wrong", "incorrect", "bad", "no", "rejected"
    - : "process", "workflow", "cycle", "iteration"
    - 📝: "doc", "notes", "writing", "content"
    - 🔧: "tools", "conf", "settings", "utilities"
    - 💡: "idea", "concept", "insight", "suggestion"
    - ⚠️: "warning", "caution", "important", "attention"
    - 🎯: "goal", "target", "objective", "aim"
    - 📊: "data", "analytics", "metrics", "stats"
    - 🚀: "deployment", "launch", "release"
9. **Common Abbreviations**: Use std abbrevs (e.g., "w/", "req"). See list.
10. **Conditional & Logical Operators**: `|` for "or", `&` for "and", `>` for "better than".
11. **Punctuation & Formatting Reduction**: Use line breaks for transitions, min quotes, dashes for clauses.
12. **Time & Sequence Compression**: Use prefixes & short date formats ("pre-", "post-", "Q1").
13. **Code & Cmd Optimization**: Use backticks, min comments, std cmd shortcuts (`ls`, `cd`).
14. **Measurement & Quantity Shortcuts**: Use symbols & std unit abbrevs ("%", "K", "M", "KB").
15. **Markdown Formatting Intelligence**: Preserve semantic formatting (`**bold**`), remove decorative.

**16. QA Protocol**
- Verify abbrevs commonly understood
- Ensure emoji usage enhances, not obscures, meaning
- Maintain logical flow
- Preserve critical tech details
- Test compressed text for clarity w/target audience

**🚫 CRITICAL EMOJI RULE**: No decorative emoji. Only direct word/concept replacements.

## Common Abbreviations List
- w/: with
- w/o: without
- w/i: within
- b/c: because
- vs: versus
- etc: et cetera
- i.e.: that is
- e.g.: for example
- API: Application Programming Interface
- UI/UX: User Interface/User Experience
- async: asynchronous
- auth: authentication
- char: character
- cmds: commands
- conf: configuration
- DB: database
- desc: description
- dest: destination
- dev: development
- dir: directory
- doc/docs: documentation
- env: environment
- estab: established
- impl: implementation
- info: information
- lang: language
- lib: library
- mgmt: management
- obvi: obvious
- org: organization
- perf: performance | perfect
- pkg: package
- prefs: preferences
- prod: production
- proj: project
- ref: reference | referencing
- repo: repository
- req: requirement
- sec: security
- spec: specification
- src: source
- std: standard
- sync: synchronous
- sys: system
- tmp: temporary
- vuln: vulnerabilities

## Compression Guidelines
- **Target**: 35-50% token reduction
- **Priority**: Semantic preservation > max compression
- **Context**: Maintain tech accuracy in specialized domains
- **Readability**: Ensure scannable & clear compressed text

## Common Failure Modes to Avoid
**CRITICAL**: Prevent these failure patterns:
### 1. Content Expansion Instead of Compression
**❌ WRONG**: "Adding User Rules (when user says "add user rule" | "add user instruction")" → "Adding User Rules (Personal prefs, local only, not committed)" + extra bullets
**✅ CORRECT**: "Adding User Rules (user says "add user rule" | "add user instruction")"
### 2. Missing Compression Opportunities
**Key Rules**:
- Logical operators: "or" → "|", "and" → "&"
- Abbrevs: "reqs", "prefs", "cmds"
- Phrase compression: "if it doesn't exist" → "if gone"
**❌ WRONG**: Leaving common terms unchanged
**✅ CORRECT**: "Lang prefs, formatting, naming conventions"

## Usage Instructions
1. **Read & Parse**: Read full src file, separate YAML from body
2. **Systematic Compression**: Apply AxiTxt rules to entire markdown body
3. **Iterative Improvement**: Re-read & apply more compression passes until 35-50% reduction
4. **Clean Assembly**: Combine preserved YAML + compressed body
5. **Validation**: Verify output structure & semantic preservation
6. **Error Check**: No duplications, code blocks, format corruption
7. **Metrics**: Report compression stats (before/after token counts)
8. **Whitespace Cleanup**: Normalize whitespace. Min newlines/spaces. List markers (`-`, `*`, `1.`) followed by single space.
9. **YAML Fixup**: Ensure front matter is intact, no duplicates/errors. Correct syntax if needed. Doc must not start w/backticks & "instructions".

## Self-Validation Checklist
- [ ] **File Structure**: Plain markdown w/YAML (no code blocks)
- [ ] **Content Integrity**: Single, clean version (no duplications)
- [ ] **YAML Preservation**: Front matter unchanged
- [ ] **Compression Quality**: 35-50% reduction, every section shorter
- [ ] **Semantic Accuracy**: All meaning preserved, no specialized terminology lost
- [ ] **Abbrevs Applied**: Common terms abbreviated (prefs, cmds, req, impl, etc.)
- [ ] **Logical Operators Used**: "|" for "or", "&" for "and"
- [ ] **Redundancy Eliminated**: No repeated phrases/unnecessary words
Transform text using these AxiTxt compression techniques.