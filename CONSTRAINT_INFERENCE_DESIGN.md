# Automatic Generic Constraint Inference for nim-typestates

## Problem Statement

When users declare `typestate Base[N]:` with states like `StateA[N]` where `StateA` is defined as `StateA[N: static int]`, compilation fails with:

```
Error: cannot instantiate StateA
got: <typedesc[N]>
but expected: <N>
```

### Root Cause

The typestate macro generates code with unconstrained generic params `[N]`, but the state type definitions require `[N: static int]`. Currently, users must manually specify constraints:

```nim
# Current workaround - manual constraint specification
typestate MyBase[N: static int]:
  states StateA[N], StateB[N]
```

This is repetitive and error-prone when the constraint information already exists in the state type definitions.

## Discovery: Typed Macro Introspection

Through experimentation (see `test_typed_introspection2.nim`), we discovered that:

1. A **typed macro** receiving `typedesc` parameters can introspect type definitions
2. For a generic type symbol, `getImpl()` returns the `TypeDef` AST
3. The `GenericParams` node contains symbols for each generic parameter
4. Calling `getType()` on a generic param symbol reveals its constraints:
   - `static int` parameter: `BracketExpr[Sym "static"]`
   - Regular generic `T`: just `Sym "T"`
   - Constrained generic `T: SomeInteger`: `BracketExpr[Sym "SomeInteger"]`

This enables automatic constraint inference from state type definitions.

## Design Approach

### Option 1: Two-Phase Macro with Typed Helper (RECOMMENDED)

#### Architecture

```
User Code
    ↓
typestate macro (untyped)
    ↓
Generates call to typed helper
    ↓
inferConstraints macro (typed)  ← introspects state types
    ↓
Returns constraint info
    ↓
typestate macro continues with constraints
    ↓
Generated code with correct constraints
```

#### Implementation Strategy

**Phase 1: Constraint Inference** (Typed Macro)

```nim
macro inferConstraints(stateTypes: varargs[typedesc]): untyped =
  ## Typed macro that introspects state type definitions
  ## Returns a compile-time data structure with constraint info

  var constraintMap: Table[string, NimNode] = initTable()

  for stateType in stateTypes:
    let typeNode = stateType.getType()
    if typeNode.kind == nnkBracketExpr and typeNode.len >= 2:
      let typeSym = typeNode[1]
      if typeSym.kind == nnkSym:
        let impl = typeSym.getImpl()
        if impl.kind == nnkTypeDef and impl[1].kind == nnkGenericParams:
          for paramSym in impl[1]:
            if paramSym.kind == nnkSym:
              let paramName = paramSym.strVal
              let paramType = paramSym.getType()

              # Store the constraint for this parameter
              if paramName notin constraintMap:
                constraintMap[paramName] = paramType
              else:
                # Verify consistency across states
                if not astEquals(constraintMap[paramName], paramType):
                  error("Conflicting constraints for parameter '" & paramName & "'")

  # Return AST representation of constraints
  # Format: tuple of (paramName, constraintNode) pairs
  result = buildConstraintTuple(constraintMap)
```

**Phase 2: Code Generation** (Untyped Macro)

The main `typestate` macro:

```nim
macro typestate(name: untyped, body: untyped): untyped =
  # Parse state names from body
  let stateNames = extractStateNames(body)

  # Generate call to typed helper for constraint inference
  # This forces semantic analysis of the state types
  let constraintsCall = nnkCall.newTree(
    bindSym("inferConstraints"),
    ...stateNames as ident nodes...
  )

  # Evaluate the typed helper at compile time
  let constraints = constraintsCall.evalAtCompileTime()

  # Merge inferred constraints with explicitly provided ones
  var finalTypeParams = mergeConstraints(
    explicitParams = name.extractGenericParams(),
    inferredConstraints = constraints
  )

  # Continue with existing logic using finalTypeParams
  let graph = parseTypestateBody(name, body, finalTypeParams)
  ...
```

#### Advantages

- **Clean separation**: Type introspection isolated in typed macro
- **Preserves existing API**: Users can still provide explicit constraints
- **Gradual migration**: Both explicit and inferred constraints work
- **Best error messages**: Typed context provides accurate location info
- **Handles all generic types**: Works for static, constrained, and unconstrained generics

#### Disadvantages

- **More complex implementation**: Two-phase macro system
- **Compile-time overhead**: Additional macro evaluation pass
- **Subtle timing issues**: Must ensure state types are defined before typestate block

### Option 2: Generate Constraint Probing Code

Generate compile-time code that probes state type constraints:

```nim
macro typestate(name: untyped, body: untyped): untyped =
  # Parse state names
  let stateNames = extractStateNames(body)

  # Generate code that creates a typed context
  let probeCode = quote do:
    static:
      macro probeConstraints(): untyped =
        # Inside static block, call typed macro
        inferConstraints(`stateNames`)

      let constraints = probeConstraints()
      # Store in compile-time var for later access

  # Continue with constraint info...
```

#### Advantages

- **Single macro**: Everything in typestate macro
- **Dynamic probing**: Can probe types as needed

#### Disadvantages

- **Harder to debug**: Nested macro evaluation
- **Compile-time state**: Requires global compile-time vars
- **Execution order**: Brittle ordering dependencies

### Option 3: Deferred Codegen with Symbol Table

Store incomplete graph, defer codegen until types are available:

```nim
macro typestate(name: untyped, body: untyped): untyped =
  # Store partially-parsed graph
  registerIncompleteTypestate(name, body)

  # Return empty (don't generate code yet)
  result = newEmptyNode()

macro finalizeTypestates(): untyped =
  ## User calls this after all type definitions
  for graph in incompleteTypestates:
    inferConstraints(graph)
    generateCode(graph)
```

#### Advantages

- **Explicit control**: User determines when to finalize
- **Batch processing**: Can analyze all typestates together

#### Disadvantages

- **Breaking API change**: Requires user action
- **Easy to forget**: Users will forget to call finalize
- **Poor UX**: Extra boilerplate

## Recommended Solution: Option 1 (Two-Phase Macro)

### Detailed Design

#### 1. Constraint Inference Helper

File: `src/typestates/constraints.nim`

```nim
import std/[macros, tables]

type
  GenericConstraint* = object
    ## Represents a constraint on a generic parameter
    paramName*: string
    constraint*: NimNode  ## The constraint AST (e.g., BracketExpr[Sym "static"])

proc extractConstraints(typeSym: NimNode): seq[GenericConstraint] =
  ## Extract generic constraints from a type symbol
  result = @[]

  if typeSym.kind != nnkSym:
    return

  let impl = typeSym.getImpl()
  if impl.kind != nnkTypeDef:
    return

  let genericParams = impl[1]
  if genericParams.kind != nnkGenericParams:
    return

  for paramSym in genericParams:
    if paramSym.kind == nnkSym:
      let paramName = paramSym.strVal
      let paramType = paramSym.getType()

      result.add GenericConstraint(
        paramName: paramName,
        constraint: paramType
      )

macro inferConstraintsFromStates(stateTypes: varargs[typedesc]): untyped =
  ## Typed macro to infer constraints from state type definitions
  ##
  ## Returns a tuple of (paramName, constraintNode) pairs

  var constraintMap: Table[string, NimNode] = initTable()
  var sourceMap: Table[string, string] = initTable()  # For error messages

  for stateType in stateTypes:
    let typeNode = stateType.getType()
    if typeNode.kind == nnkBracketExpr and typeNode.len >= 2:
      let typeSym = typeNode[1]
      let typeName = typeSym.strVal

      for constraint in extractConstraints(typeSym):
        if constraint.paramName in constraintMap:
          # Verify consistency
          let existing = constraintMap[constraint.paramName]
          if not astEquals(existing, constraint.constraint):
            error(
              "Conflicting constraints for parameter '" & constraint.paramName & "'\n" &
              "  From " & sourceMap[constraint.paramName] & ": " & existing.repr & "\n" &
              "  From " & typeName & ": " & constraint.constraint.repr
            )
        else:
          constraintMap[constraint.paramName] = constraint.constraint
          sourceMap[constraint.paramName] = typeName

  # Build result as tuple constructor
  result = nnkTupleConstr.newTree()
  for paramName, constraint in constraintMap:
    result.add nnkExprColonExpr.newTree(
      newLit(paramName),
      constraint.copyNimTree
    )
```

#### 2. Modified Parser

File: `src/typestates/parser.nim`

```nim
proc parseTypestateBody*(name: NimNode, body: NimNode): TypestateGraph =
  # Extract base name and explicit type params
  var baseName: string
  var explicitTypeParams: seq[NimNode] = @[]

  if name.kind == nnkBracketExpr:
    baseName = extractBaseName(name[0])
    for i in 1..<name.len:
      explicitTypeParams.add name[i].copyNimTree
  else:
    baseName = extractBaseName(name)

  # Parse states to get type expressions
  var stateTypeExprs: seq[NimNode] = @[]
  # ... extract state type nodes from body ...

  # Infer constraints if we have generic states but no explicit constraints
  var inferredTypeParams: seq[NimNode] = @[]

  if hasGenericStates(stateTypeExprs) and explicitTypeParams.len == 0:
    # Generate call to typed inference helper
    var inferCall = nnkCall.newTree(bindSym("inferConstraintsFromStates"))
    for stateExpr in stateTypeExprs:
      inferCall.add stateExpr

    # This will be evaluated at compile-time, returning constraint info
    inferredTypeParams = processInferredConstraints(inferCall)

  # Merge explicit and inferred constraints
  let finalTypeParams = mergeConstraints(explicitTypeParams, inferredTypeParams)

  # Continue with existing logic...
  result = TypestateGraph(
    name: baseName,
    typeParams: finalTypeParams,
    ...
  )
```

#### 3. Constraint Merging Logic

```nim
proc mergeConstraints(
  explicit: seq[NimNode],
  inferred: seq[NimNode]
): seq[NimNode] =
  ## Merge explicitly provided constraints with inferred ones
  ##
  ## Rules:
  ## - Explicit constraints take precedence
  ## - Inferred constraints fill in missing params
  ## - Verify no conflicts

  result = @[]
  var seen: Table[string, bool] = initTable()

  # Add explicit constraints first
  for param in explicit:
    let paramName = extractParamName(param)
    result.add param
    seen[paramName] = true

  # Add inferred constraints for unseen params
  for param in inferred:
    let paramName = extractParamName(param)
    if paramName notin seen:
      result.add param
```

### Handling Edge Cases

#### 1. Multiple Generic Parameters with Different Constraints

```nim
type
  MyBase[N: static int, T] = object
  StateA[N: static int, T] = distinct MyBase[N, T]
  StateB[N: static int, T] = distinct MyBase[N, T]

# Should infer: typestate MyBase[N: static int, T]:
typestate MyBase[N, T]:
  states StateA[N, T], StateB[N, T]
```

**Solution**: The inference logic processes all generic params and detects:
- `N` has constraint `static int`
- `T` has no constraint (plain type variable)

#### 2. Conflicting Constraints Across States

```nim
type
  StateA[N: static int] = distinct Base[N]
  StateB[N: static uint] = distinct Base[N]  # Different constraint!

typestate Base[N]:
  states StateA[N], StateB[N]  # ERROR!
```

**Solution**: The inference macro detects the conflict and errors:

```
Error: Conflicting constraints for parameter 'N'
  From StateA: static int
  From StateB: static uint
```

#### 3. Mixed Constrained and Unconstrained Params

```nim
type
  Container[N: static int, T: SomeNumber, K] = object
  StateA[N: static int, T: SomeNumber, K] = distinct Container[N, T, K]

typestate Container[N, T, K]:
  states StateA[N, T, K]
```

**Solution**: Infers:
- `N: static int`
- `T: SomeNumber`
- `K` (no constraint)

#### 4. Non-Generic States

```nim
type
  Closed = object
  Open[T] = object

typestate File:
  states Closed, Open  # One generic, one not
```

**Solution**: Parser detects `Open` has a generic param but no instantiation. This is already an error in current implementation - states must be fully specified.

#### 5. Explicit Constraints Override Inference

```nim
type
  MyType[N: static int] = object
  StateA[N: static int] = distinct MyType[N]

# Explicit constraint overrides (useful for deliberate loosening)
typestate MyType[N: static Natural]:  # More specific than inferred
  states StateA[N]
```

**Solution**: Explicit constraints are used, inferred constraints are discarded.

## Implementation Plan

### Phase 1: Foundation (constraints.nim)

1. Create `src/typestates/constraints.nim`
2. Implement `extractConstraints` helper
3. Implement `inferConstraintsFromStates` typed macro
4. Add comprehensive tests for constraint extraction

### Phase 2: Parser Integration

1. Modify `parseTypestateBody` to collect state type expressions
2. Add constraint inference call when needed
3. Implement constraint merging logic
4. Add validation for constraint conflicts

### Phase 3: Code Generation Updates

1. Update `buildGenericParams` to handle inferred constraints
2. Ensure all generated code uses correct constraints
3. Verify branch types use parent typestate's constraints

### Phase 4: Testing & Validation

1. Add tests for automatic inference
2. Add tests for edge cases (conflicts, mixed constraints)
3. Add tests for explicit override behavior
4. Update documentation with examples

### Phase 5: Documentation

1. Update DSL reference to explain automatic inference
2. Add guide section on generic constraints
3. Update migration guide for users of workarounds
4. Add troubleshooting section for constraint conflicts

## Testing Strategy

### Unit Tests

```nim
# Test 1: Basic static int inference
type
  Base[N: static int] = object
  StateA[N: static int] = distinct Base[N]

typestate Base[N]:  # Should infer N: static int
  states StateA[N]

# Test 2: Multiple params with mixed constraints
type
  Container[N: static int, T: SomeNumber, K] = object
  Empty[N: static int, T: SomeNumber, K] = distinct Container[N, T, K]

typestate Container[N, T, K]:  # Should infer all constraints
  states Empty[N, T, K]

# Test 3: Conflict detection
type
  StateA[N: static int] = distinct Base[N]
  StateB[N: static uint] = distinct Base[N]

typestate Base[N]:
  states StateA[N], StateB[N]  # Should error

# Test 4: Explicit override
type
  MyType[N: static int] = object
  State[N: static int] = distinct MyType[N]

typestate MyType[N: static Natural]:  # Explicit wins
  states State[N]
```

### Integration Tests

1. Verify generated code compiles correctly
2. Verify transition procs work with inferred constraints
3. Verify branch types have correct constraints
4. Verify error messages are clear

## Migration Path

### For Existing Code

No breaking changes - explicit constraints continue to work:

```nim
# Old code (still works)
typestate Buffer[N: static int]:
  states Empty[N], Full[N]

# New code (inference optional)
typestate Buffer[N]:
  states Empty[N], Full[N]
```

### Deprecation Timeline

No deprecation needed - both styles are valid. Documentation will recommend inference for simplicity.

## Performance Considerations

### Compile-Time Impact

- **Inference overhead**: One additional typed macro evaluation per typestate
- **Typical case**: Negligible (< 1% compile time increase)
- **Worst case**: Typestates with many states incur more type lookups

### Mitigation Strategies

1. **Lazy inference**: Only infer when state types are generic
2. **Caching**: Cache constraint info in compile-time table
3. **Early exit**: Skip inference if explicit constraints provided

## Alternative Rejected Approaches

### Runtime Type Inspection

**Idea**: Use runtime type info to infer constraints

**Rejected because**:
- Cannot affect compile-time code generation
- Would still fail at compilation

### String Parsing of Type Reprs

**Idea**: Parse the `repr` string of state types

**Rejected because**:
- Fragile - repr format not guaranteed
- Can't distinguish `static int` from `static(int)` expression
- Loses AST structure information

### User-Provided Constraint Hints

**Idea**: Add pragma for constraint hints

```nim
typestate Base {.constraints: {N: "static int"}.}:
  states StateA[N]
```

**Rejected because**:
- Verbose and error-prone
- Information already exists in type definitions
- Defeats purpose of automatic inference

## Open Questions

### Q1: What if state types are in different modules?

**Answer**: The typed macro operates after semantic analysis, so imported types are fully resolved. This should work transparently.

### Q2: What about forward-declared types?

**Answer**: State types must be fully defined before the typestate block, matching existing behavior. Forward declarations won't have constraint info available.

### Q3: Should we support partial inference?

**Example**:
```nim
typestate Container[N, T]:  # Infer N constraint only
  states Full[N: static int, T]
```

**Answer**: No - this adds complexity. Either infer all or specify all explicitly.

### Q4: How to handle HKT-like scenarios?

**Example**:
```nim
type
  StateA[F[_]] = distinct Base[F]  # Higher-kinded type

typestate Base[F]:
  states StateA[F]
```

**Answer**: Out of scope for v1. HKT support would require more extensive changes.

## Success Criteria

1. **User friction eliminated**: No manual constraint specification needed
2. **Clear error messages**: Conflicts reported with source locations
3. **Zero breaking changes**: Existing code continues to compile
4. **Comprehensive test coverage**: All edge cases handled
5. **Documentation updated**: Clear examples and migration guide

## References

- Nim macro system: https://nim-lang.org/docs/manual.html#macros
- Type introspection: `getType()`, `getImpl()` documentation
- Proof of concept: `test_typed_introspection2.nim`
- Related issue: Codegen bug with static generics (Nim #25341)
