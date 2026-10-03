# roc-luajit

## Experimental Roc Backend Targeting LuaJIT

**Status:** Design specification / investigation plan  
**Primary goal:** Compile Roc programs to Lua 5.1-compatible source intended to execute under LuaJIT 2.1 while preserving Roc language semantics.  
**Implementation philosophy:** Reuse Roc's existing frontend, type system, monomorphization, lowering, and semantic checks. Add the thinnest practical backend rather than building a source-to-source transpiler from scratch.

---

## 1. Executive Summary

`roc-luajit` is an experimental compiler backend for Roc that emits Lua source suitable for LuaJIT.

The project exists to combine:

- Roc's functional programming model
- immutable-by-default user semantics
- strong static typing and inference
- tagged unions and pattern matching
- value-oriented APIs
- LuaJIT's compact runtime
- LuaJIT's JIT compiler
- LuaJIT FFI
- access to the Lua ecosystem
- straightforward embedding into existing native applications

The key observation is that the desired semantics already exist in Roc.

The project therefore should **not** invent a new functional Lua dialect and should **not** attempt to parse and reinterpret Roc source independently.

Instead:

```text
Roc source
   ↓
Roc frontend
   ↓
canonicalization / type checking
   ↓
monomorphization
   ↓
closure / lambda lowering
   ↓
Roc low-level IR
   ↓
roc-luajit backend
   ↓
Lua 5.1-compatible source
   ↓
LuaJIT 2.1
```

The resulting system should preserve Roc semantics while allowing LuaJIT to provide garbage collection, dynamic code generation, and native interoperability.

---

## 2. Non-Goals

The first version explicitly does **not** attempt to:

- replace Roc's native backend
- outperform optimized native Roc code
- implement a new Roc parser
- implement a new Roc type checker
- reproduce Roc's optimizer independently
- emit LuaJIT bytecode directly
- depend on undocumented LuaJIT bytecode internals
- make arbitrary Lua code obey Roc's immutability semantics
- expose every Lua library automatically
- support every Roc platform immediately
- guarantee perfect source-level debugging initially
- make the backend suitable for upstream inclusion in Roc

The initial objective is semantic correctness and practical interoperability.

Performance optimization comes later.

---

## 3. Why Lua Source Instead of LuaJIT Bytecode

The backend should emit Lua 5.1-compatible source rather than LuaJIT bytecode.

Reasons:

1. Lua source is stable and portable across LuaJIT 2.1 builds.
2. LuaJIT's internal bytecode representation is not a desirable compiler ABI.
3. Source output is inspectable and debuggable.
4. LuaJIT can optimize generated source itself.
5. Generated Lua can interoperate naturally with ordinary Lua modules.
6. The project remains useful even when LuaJIT internals change.

Example invocation:

```bash
roc build --target=luajit app.roc
luajit app.lua
```

or, if implemented as an experimental external driver:

```bash
roc-luajit build app.roc -o app.lua
luajit app.lua
```

---

## 4. Primary Semantic Requirement

The backend must preserve Roc's observable language semantics.

In particular, ordinary Roc values passed to functions must behave as immutable values from the programmer's perspective.

Given conceptually:

```roc
movePoint = |p|
    { p & x: p.x + 1 }
```

calling `movePoint` must not mutate the caller's original logical value.

This does **not** imply deep cloning every argument.

The backend may use:

- structural sharing
- copy-on-write techniques
- representation reuse
- uniqueness analysis already performed by Roc
- compiler-generated mutation that is observationally invisible

The rule is semantic rather than representational:

> Generated code may mutate storage internally only when doing so cannot be observed as mutation by valid Roc code.

---

## 5. Correct Compiler Integration Point

The preferred design is a backend consuming an existing sufficiently lowered Roc IR.

The implementation should identify the narrowest stable compiler interface that already provides:

- resolved types
- monomorphized functions
- lowered pattern matches
- lowered closures
- concrete data representations or enough information to choose them
- explicit control flow
- explicit function calls
- enough ownership information to preserve value semantics

The project should avoid depending on high-level syntax structures wherever possible.

### Investigation task

Before significant implementation, inspect the current Roc compiler and determine:

1. Which IR is consumed by existing code-generation backends.
2. At what point ARC/reference-counting operations are introduced.
3. Whether a backend can consume IR before ARC insertion.
4. Which representation decisions are already fixed before backend code generation.
5. Which optimization passes assume manual memory management.
6. Which passes assume native machine-code generation.

Because Roc compiler internals are still evolving, the backend should minimize coupling to unstable frontend/compiler internals.

---

## 6. ARC and Garbage Collection

Roc's native execution model may insert automatic reference-counting operations or other explicit memory-management operations.

LuaJIT already provides garbage collection.

Therefore the backend should **not automatically reproduce Roc ARC at runtime**.

Naively translating:

```text
INCREF x
DECREF x
```

into a second reference-counting layer inside Lua would add cost without obvious benefit.

### Preferred approach

If possible, consume Roc IR before explicit ARC insertion.

### Fallback experimental approach

If the backend must initially consume post-ARC IR:

```text
INCREF → no-op
DECREF → no-op
```

may be acceptable **only after proving** that no representation-reuse or semantic decision depends on those operations being executed.

This must be tested rather than assumed.

### Important distinction

Roc ownership/uniqueness information may still be extremely valuable even when LuaJIT handles lifetime management.

Ownership information can permit safe destructive updates of otherwise immutable-looking values when the value is known to be uniquely referenced.

---

## 7. Runtime Representation Strategy

The first implementation should favor correctness and simplicity over maximal compactness.

Suggested initial mappings:

| Roc concept | Initial LuaJIT representation |
|---|---|
| `Bool` | Lua boolean |
| `Str` | Lua string where semantically compatible; otherwise runtime object |
| floating-point scalar | Lua number |
| small exact integer | Lua number when exactly representable |
| signed/unsigned 64-bit integer | LuaJIT FFI cdata where necessary |
| record | array-like Lua table with compiler-known field positions |
| tuple | array-like Lua table |
| tagged union | compact table containing numeric tag plus fields |
| closure | Lua closure or function plus explicit environment |
| list | dedicated runtime representation |
| opaque host value | userdata/cdata/table hidden behind FFI boundary |

Named string-keyed records should generally be avoided in generated hot-path code when field positions are statically known.

Instead of:

```lua
local p = {
    x = 10,
    y = 20,
}
```

prefer an internal representation such as:

```lua
local p = { 10, 20 }
```

with generated code knowing that:

```text
field x → slot 1
field y → slot 2
```

This reduces hashing overhead and gives LuaJIT a simpler representation to optimize.

---

## 8. Tagged Unions

Roc tagged unions should initially use an explicit numeric tag.

Example conceptual Roc value:

```text
Ok value
Err message
```

Possible generated representation:

```lua
-- Ok(value)
{ 0, value }

-- Err(message)
{ 1, message }
```

Generated pattern matching becomes ordinary numeric branching:

```lua
if value[1] == 0 then
    local payload = value[2]
    -- Ok branch
else
    local message = value[2]
    -- Err branch
end
```

Future optimizations may specialize zero-payload constructors into scalars or singleton constants.

---

## 9. Lists and Persistent Data

Lists deserve a dedicated design rather than blindly mapping every Roc list to a Lua sequence table.

The initial implementation may use a simple representation, but the runtime abstraction should permit future replacement.

Potential implementations include:

### 9.1 Flat Lua arrays

Advantages:

- simple
- fast iteration
- JIT-friendly

Disadvantages:

- functional updates may require copying
- slicing is awkward

### 9.2 Array plus slice metadata

Conceptually:

```text
{
    storage = <array>,
    offset = N,
    length = M
}
```

Advantages:

- cheap slicing
- shared storage

### 9.3 Copy-on-write arrays using uniqueness

If ownership analysis proves a list is unique, generated code may mutate its backing storage during an update.

Otherwise it creates new storage or shares immutable storage where valid.

This is likely the best long-term direction because it matches Roc's semantic model while exploiting information the compiler already possesses.

---

## 10. Strings

Lua strings are immutable byte strings and therefore attractive as a Roc string representation.

However, exact Roc string semantics must be verified before using raw Lua strings universally.

Questions to resolve:

- encoding guarantees
- UTF-8 validity expectations
- slicing behavior
- indexing semantics
- byte length versus character/grapheme behavior
- foreign string ownership
- NUL-byte handling

If semantics line up sufficiently, raw Lua strings should be preferred because LuaJIT handles them efficiently.

If not, use a small runtime wrapper around Lua strings.

---

## 11. Numeric Representation

Numeric compatibility is one of the project's most important technical risks.

LuaJIT's ordinary Lua number is normally IEEE-754 double precision.

That means not every Roc integer can safely be represented as a Lua number.

### Initial policy

Use the simplest exact representation available for each concrete monomorphized numeric type.

Potential mapping:

```text
F32/F64 → Lua number
small signed/unsigned integers → Lua number when exact
I64/U64 → LuaJIT FFI integer cdata where required
I128/U128 → runtime implementation
Dec → runtime implementation
```

### 128-bit values

Implement a small runtime representation, potentially:

```c
struct roc_u128 {
    uint64_t lo;
    uint64_t hi;
};
```

exposed through LuaJIT FFI.

Operations should initially prioritize correctness.

Later optimization can specialize common operations.

### Rule

Never silently degrade Roc numeric semantics merely because Lua numbers are convenient.

---

## 12. Closures

Roc closures can map naturally to Lua closures.

For example, conceptually:

```roc
makeAdder = |x|
    |y| x + y
```

may become:

```lua
local function make_adder(x)
    return function(y)
        return x + y
    end
end
```

However, if Roc's lowered IR already uses explicit closure environments, the backend may preserve that representation rather than reconstructing high-level closures.

Example:

```lua
local function closure_body(env, y)
    return env[1] + y
end

local closure = {
    closure_body,
    { x },
}
```

The fastest representation should be determined empirically after correctness is established.

---

## 13. Tail Calls

Lua supports proper tail calls in relevant cases, and LuaJIT preserves this behavior.

The backend should preserve tail position where practical.

Generated code should avoid accidentally destroying tail-call opportunities by inserting unnecessary wrappers.

Example:

Prefer:

```lua
return next_function(x)
```

instead of:

```lua
local result = next_function(x)
return result
```

when there is no semantic reason to retain the intermediate variable.

---

## 14. Roc-to-Lua Interoperability Boundary

This is where semantic immutability can be accidentally violated.

Inside generated Roc code, the compiler controls all writes.

At the foreign-code boundary, arbitrary Lua code can mutate Lua tables.

Therefore a raw internal Roc representation must not automatically be handed to arbitrary Lua code.

### Boundary categories

#### 14.1 Roc-generated code → Roc-generated code

Use internal representation directly.

No cloning.

#### 14.2 Lua → Roc opaque value

Lua objects may enter Roc as opaque host values when the platform/API contract permits it.

Generated Roc code must not assume such objects obey Roc value semantics.

#### 14.3 Lua structured value → Roc value

Explicit conversion is required.

The conversion layer establishes Roc ownership/value semantics.

#### 14.4 Roc structured value → arbitrary Lua

Use one of:

- explicit deep conversion
- shallow conversion where safe
- read-only facade/proxy
- opaque handle with accessors

The API must make the cost and mutability semantics explicit.

### Critical rule

Do **not** deep-clone ordinary values merely because they cross function-call boundaries inside generated Roc code.

Copies should occur only when demanded by semantics or by a hostile/foreign mutability boundary.

---

## 15. Lua FFI API Design

The platform should eventually expose a deliberately small interop layer.

Conceptual operations:

```roc
Lua.require : Str -> Result LuaModule LuaError
Lua.call : LuaFn, List LuaValue -> Result LuaValue LuaError
Lua.get : LuaValue, Str -> Result LuaValue LuaError
Lua.toStr : LuaValue -> Result Str LuaTypeError
Lua.toI64 : LuaValue -> Result I64 LuaTypeError
```

The exact API should be idiomatic Roc, not a literal mirror of Lua's dynamic API.

Where performance matters, platform-specific bindings can provide typed wrappers around particular Lua or C APIs.

---

## 16. C Interoperability

LuaJIT FFI is a major reason to pursue this backend.

The compiler/runtime should make it possible for Roc applications to reach native libraries through a controlled platform layer.

Long-term architecture:

```text
Roc
 ↓
roc-luajit generated code
 ↓
LuaJIT FFI
 ↓
C ABI library
```

This may provide an unusually lightweight route to native interoperability compared with many managed functional runtimes.

The first implementation should not expose arbitrary FFI directly to Roc user code.

Prefer platform-owned bindings until semantics and safety constraints are understood.

---

## 17. Platform Model

Roc separates applications from platforms.

`roc-luajit` should embrace this rather than inventing a second foreign-function model.

A minimal experimental LuaJIT platform should provide:

- process startup
- standard output
- standard error
- command-line arguments
- environment access
- filesystem access
- process exit
- time primitives

Future LuaJIT-specific platforms may expose:

- Lua module loading
- LuaJIT FFI
- embedding callbacks
- sockets
- event loops
- game engines
- Redis/OpenResty-style environments where applicable

---

## 18. Generated Code Style

Generated Lua should be machine-oriented but readable enough for debugging.

Example:

```lua
local function roc_fn_42(v1, v2)
    local v3 = v1[1]
    local v4 = v2 + v3
    return v4
end
```

Avoid excessive abstraction layers merely to make generated code pretty.

The generated code is an implementation artifact, not hand-written application code.

### Debug mode

A debug option may emit:

- more stable temporary names
- comments identifying Roc functions
- source-location comments
- less aggressive inlining
- runtime assertions

Example:

```bash
roc-luajit build --debug app.roc
```

---

## 19. Runtime Library

Keep the runtime tiny.

Tentative components:

```text
runtime/
  numeric.lua
  list.lua
  str.lua
  union.lua
  ffi.lua
  panic.lua
```

Native FFI helpers may additionally live in:

```text
runtime/native/
  roc_numeric.h
  roc_numeric.c
```

or be declared directly through LuaJIT FFI when possible.

### Runtime rule

Do not move generic compiler logic into the runtime merely because writing Lua helpers is easier.

Prefer compile-time specialization when it produces simpler hot-path code.

---

## 20. Error and Panic Semantics

Roc-level `Result` values should remain ordinary values.

Only actual runtime failures should use backend panic machinery.

Potential runtime panic representation:

```lua
error({
    roc_panic = true,
    message = msg,
    source = source_info,
}, 0)
```

A top-level runner can convert this to a useful diagnostic.

Generated code should not use Lua exceptions as an implementation shortcut for ordinary Roc control flow unless proven semantics-preserving and beneficial.

---

## 21. Testing Philosophy

The project should be developed through differential TDD.

The core invariant:

```text
Roc reference execution == LuaJIT backend execution
```

for every supported test case.

Whenever possible, use Roc's interpreter or another established Roc backend as the semantic oracle.

### Development loop

For every new supported language feature:

1. Add a Roc test program demonstrating the feature.
2. Confirm the reference Roc implementation produces the expected result.
3. Confirm the LuaJIT backend currently fails or lacks support.
4. Implement the smallest backend/runtime change needed.
5. Run the generated Lua through LuaJIT.
6. Compare output, exit behavior, and relevant side effects.
7. Add regression coverage.
8. Only then proceed to the next feature.

No large untested compiler subsystem should be written in advance.

---

## 22. Test Harness

Create a single test harness capable of running a Roc fixture through multiple execution paths.

Conceptually:

```text
fixture.roc
   ├── reference backend/interpreter → reference.out
   └── roc-luajit → fixture.lua → luajit → actual.out

compare(reference.out, actual.out)
```

Comparison should include, where applicable:

- stdout bytes
- stderr bytes
- exit status
- serialized test result
- deterministic file output

For structured values, prefer canonical serialization in the test platform rather than comparing pretty-printer formatting.

---

## 23. Initial Conformance Test Categories

Implement in roughly this order.

### Phase A: Scalars and functions

- integer literals
- floating-point literals
- booleans
- simple arithmetic
- local bindings
- function calls
- nested function calls
- if expressions

### Phase B: Records and tuples

- record construction
- field access
- record updates
- nested records
- tuples
- tuple destructuring

### Phase C: Tagged unions

- tag construction
- payload tags
- nested tags
- exhaustive pattern matching
- branch-local variables

### Phase D: Closures

- captured scalar
- captured record
- returned closure
- closure passed as argument
- higher-order functions

### Phase E: Lists

- empty list
- construction
- indexing/access via Roc APIs
- map
- filter
- fold
- append
- slicing if exposed by the relevant API

### Phase F: Strings

- literals
- concatenation
- UTF-8
- conversion
- substring operations

### Phase G: Numeric edge cases

- signed limits
- unsigned limits
- overflow semantics
- I64/U64
- I128/U128
- decimal arithmetic
- NaN
- infinities
- signed zero if relevant

### Phase H: Platform effects

- stdout
- stderr
- CLI arguments
- filesystem
- environment
- exit

### Phase I: Lua interoperability

- call Lua function
- pass primitive values
- receive primitive values
- opaque handles
- converted records
- mutation boundary tests

---

## 24. Mutation Safety Tests

Because this project's motivation includes value semantics, mutation tests are mandatory.

Example conceptual test:

```roc
original = { x: 1, nested: { y: 2 } }
updated = update original

expect original.x == 1
expect original.nested.y == 2
```

The backend should test:

- top-level record updates
- nested record updates
- list updates
- aliases to the same source value
- closure captures
- values shared between branches
- values passed to multiple functions

Additionally, FFI tests should prove that arbitrary Lua mutation cannot silently violate Roc value semantics.

---

## 25. Performance Testing

Do not optimize before conformance is substantial.

When optimization begins, benchmark generated LuaJIT code against:

- idiomatic handwritten LuaJIT
- Roc native backend where relevant
- the same roc-luajit code with JIT disabled

Useful categories:

- numeric loops
- record-heavy transforms
- tagged-union dispatch
- list maps/folds
- closure-heavy workloads
- string processing
- FFI-heavy code

The project should distinguish:

```text
compiler overhead
runtime abstraction overhead
LuaJIT optimization behavior
representation overhead
foreign-boundary overhead
```

rather than treating total runtime as one mystery number.

---

## 26. LuaJIT Trace Friendliness

Generated code should eventually be shaped with LuaJIT tracing behavior in mind.

Likely principles:

- stable table layouts
- numeric tags
- positional arrays where practical
- predictable call shapes
- minimal polymorphism inside hot loops
- avoid unnecessary metatables
- avoid proxy objects on internal hot paths
- avoid unnecessary FFI crossings

However, these are hypotheses to benchmark, not dogma.

LuaJIT has enough peculiar optimization behavior that generated-code strategy should be evidence-driven.

---

## 27. Optimization Opportunities

After correctness:

### 27.1 Unboxed scalar locals

Keep primitive values in Lua locals whenever possible.

### 27.2 Record scalar replacement

Avoid allocating short-lived records when all fields can remain locals.

### 27.3 Union specialization

Represent nullary constructors as small integers when safe.

### 27.4 Unique-update optimization

If Roc ownership information proves uniqueness, update Lua table storage destructively rather than copying.

### 27.5 Closure specialization

Avoid heap-like environment objects when captures can become direct Lua upvalues.

### 27.6 Specialized list loops

Lower common monomorphized list operations into direct loops rather than generic runtime calls.

### 27.7 Runtime helper inlining

Generate common primitive operations directly where doing so helps LuaJIT optimize them.

---

## 28. Correctness Before Cleverness

The backend must not silently alter semantics for performance.

Examples of forbidden shortcuts:

- representing large exact integers as lossy doubles
- exposing mutable internal tables directly to foreign Lua
- reusing storage when aliases can observe the mutation
- converting structured Roc equality into Lua reference equality
- depending on table iteration order where Roc semantics require determinism
- using Lua truthiness to implement a Roc boolean-like abstraction incorrectly

Any optimization that changes representation must remain observationally equivalent to valid Roc code.

---

## 29. Determinism

Generated output should be deterministic where feasible.

Given the same:

- Roc compiler revision
- roc-luajit revision
- platform
- compiler options
- input source

then emitted Lua should be byte-for-byte reproducible unless nondeterminism is unavoidable and documented.

This aids:

- build caching
- debugging
- source comparison
- test reproducibility
- software preservation

Avoid hash-map iteration order influencing emitted symbol order.

---

## 30. Build Modes

Eventually support at least:

### Debug

```text
readable generated Lua
runtime assertions
source mapping metadata
minimal optimization
```

### Release

```text
compact symbols
specialized representations
reduced assertions
optimization enabled
```

### Trace/debug-JIT mode

Optional mode designed to help inspect LuaJIT behavior:

```text
stable function boundaries
trace labels/comments where possible
minimal wrapper noise
```

---

## 31. Source Maps and Diagnostics

A practical backend needs errors to point back to Roc source rather than generated Lua.

Initial solution:

- preserve a generated-function → Roc-source mapping table
- encode Roc source locations in comments or sidecar metadata
- intercept top-level Lua errors
- translate generated function identifiers into Roc source positions when possible

Possible sidecar:

```text
app.lua
app.lua.rocmap
```

A later version may provide richer stack rewriting.

---

## 32. Project Structure

Tentative repository structure:

```text
roc-luajit/
  README.md
  SPEC.md
  src/
    backend/
      emit.zig
      expr.zig
      stmt.zig
      types.zig
      symbols.zig
      representation.zig
    platform/
    driver/
  runtime/
    core.lua
    list.lua
    numeric.lua
    ffi.lua
    panic.lua
  tests/
    fixtures/
    conformance/
    ffi/
    regression/
    performance/
  tools/
```

Use the language and structure that fit the current Roc compiler implementation rather than forcing a separate technology stack without cause.

If contributing directly against the current Zig compiler, backend code should probably remain Zig unless architectural constraints strongly suggest otherwise.

---

## 33. AI-Agent Development Rules

This project is specifically suitable for agent-assisted implementation because it has a strong semantic oracle.

The agent must follow these rules:

1. Work feature-by-feature.
2. Add a failing test first.
3. Make only the minimal implementation required to pass it.
4. Run the full existing test suite after each feature.
5. Never invent Roc semantics from intuition when a reference implementation can answer the question.
6. Prefer differential tests over prose interpretation.
7. Do not rewrite unrelated Roc compiler subsystems.
8. Keep backend-specific logic isolated.
9. Record unsupported constructs explicitly.
10. Do not hide failing cases behind fallback dynamic evaluation.

The project's most dangerous failure mode is an AI agent producing an impressive amount of backend code before proving that its assumptions match Roc semantics.

Prevent that with tests.

---

## 34. First Investigation Milestone

Before implementing actual code generation, produce an architecture report answering:

- exact Roc compiler revision inspected
- exact current IR pipeline
- candidate backend integration point
- how native/WASM/etc. backends attach
- where ownership information exists
- where ARC is inserted
- whether memory reuse decisions occur before or after ARC
- representation metadata available to the backend
- calling convention exposed by lowered IR
- how platform boundaries are represented
- what existing backend tests can be reused

No implementation architecture should be considered stable until this report exists.

---

## 35. Minimal Viable Backend

The MVP is intentionally tiny.

It should compile a Roc program containing:

- scalar values
- local bindings
- arithmetic
- booleans
- simple functions
- function calls
- conditionals
- a minimal stdout platform

into Lua that runs under LuaJIT and produces exactly the same observable result as the Roc reference execution.

An acceptable first demonstration:

```text
hello.roc
   ↓
roc-luajit
   ↓
hello.lua
   ↓
luajit hello.lua
   ↓
Hello from Roc on LuaJIT
```

That is enough to validate the compiler integration strategy.

Do **not** begin with lists, FFI, or elaborate runtime work.

---

## 36. Milestone Plan

### M0: Compiler archaeology

Deliverable:

```text
ARCHITECTURE.md
```

No significant backend implementation yet.

### M1: Scalar emitter

Support:

- literals
- locals
- arithmetic
- booleans
- conditionals
- functions

### M2: Structured values

Support:

- records
- tuples
- basic updates

### M3: Tagged unions and pattern matching

Support:

- constructors
- payloads
- exhaustive matching

### M4: Closures

Support:

- captures
- higher-order functions
- returned closures

### M5: Strings and lists

Support common standard-library operations.

### M6: Numeric completeness

Implement exact semantics for wider integer and decimal types.

### M7: Platform completeness

CLI, files, environment, process behavior.

### M8: Lua interoperability

Typed Lua boundary and opaque handles.

### M9: Optimization

Representation specialization and uniqueness-driven updates.

### M10: Embedding

Use generated Roc modules from larger LuaJIT applications.

---

## 37. Module Export Mode

A particularly useful long-term feature is compiling Roc code as a Lua module.

Conceptually:

```bash
roc-luajit build --module maths.roc -o maths.lua
```

Then:

```lua
local maths = require("maths")
print(maths.add(2, 3))
```

Exports require an explicit ABI/conversion policy.

Primitive types can map directly where semantics permit.

Structured values should use generated conversion wrappers rather than exposing internal representations casually.

---

## 38. Embedding Use Case

The backend becomes especially interesting when Roc is used as a safe functional logic layer inside a LuaJIT host.

Example:

```text
existing LuaJIT application
        ↓
load generated Roc module
        ↓
call pure/typed Roc logic
        ↓
return converted result
```

Possible applications:

- game logic
- policy engines
- validation
- transforms
- data pipelines
- configuration evaluation
- deterministic business rules
- plugin systems

Roc provides the safer semantic layer while LuaJIT remains the integration/runtime substrate.

---

## 39. Security and Trust Boundary

Generated Roc code should be treated as ordinary trusted generated code.

Arbitrary imported Lua modules are not automatically safe.

The FFI/platform layer must clearly distinguish:

```text
pure Roc computation
trusted platform primitive
foreign mutable Lua object
native FFI resource
```

Do not allow a foreign Lua table to masquerade as an ordinary immutable Roc record without conversion or an opaque wrapper.

---

## 40. Open Questions

These should be answered empirically during M0-M3.

1. Which Roc IR is the best backend boundary today?
2. Can ARC insertion be skipped cleanly for this backend?
3. Which Roc optimizations depend on manual lifetime semantics?
4. Which representation decisions can be reused directly?
5. Can LuaJIT closures efficiently implement Roc closure environments?
6. What list representation best balances semantic fidelity and JIT optimization?
7. Which integer widths can safely remain Lua numbers?
8. What runtime representation best supports `I128`, `U128`, and `Dec`?
9. Can internal record updates exploit Roc uniqueness information directly?
10. How should generated modules expose Roc functions to ordinary Lua?
11. What is the smallest practical LuaJIT-specific Roc platform?
12. How much source-location metadata is available after lowering?
13. Which constructs cause pathological LuaJIT trace exits?
14. Are some Roc abstractions better compiled into FFI structs than Lua tables?

---

## 41. Success Criteria

The experiment is successful if it demonstrates all of the following:

1. Real Roc programs compile using the existing Roc frontend.
2. Generated output runs under stock LuaJIT 2.1.
3. Roc value semantics are preserved.
4. Ordinary function calls require no defensive deep cloning.
5. Structured values can use safe structural sharing or storage reuse.
6. Differential tests match a reference Roc implementation.
7. Foreign Lua mutation cannot silently corrupt Roc semantic assumptions.
8. Generated code can call a small LuaJIT platform API.
9. LuaJIT FFI can be reached through controlled platform bindings.
10. Performance is reasonable enough to justify further optimization.

A stretch success criterion:

> Generated Roc code performs within the same order of magnitude as equivalent hand-written LuaJIT for representative application workloads, while preserving Roc semantics.

---

## 42. Failure Criteria

Stop or redesign if investigation shows that:

- Roc's lowered IR is inseparably tied to native memory layout assumptions
- bypassing ARC invalidates earlier compiler transformations
- every meaningful structured update requires pathological copying
- LuaJIT representation constraints fundamentally conflict with Roc semantics
- foreign-boundary conversion overwhelms intended workloads
- compiler churn makes maintenance cost disproportionate to value

The project should remain an experiment until these questions are answered.

---

## 43. Guiding Principle

The project should resist two equally bad instincts:

### Bad instinct A

"Roc is functional, therefore clone everything."

Wrong.

Immutability is an observable semantic property, not a requirement to duplicate every byte of storage.

### Bad instinct B

"Lua tables are fast and mutable, therefore just mutate them."

Also wrong.

Compiler-internal mutation is acceptable only when Roc code cannot observe it.

The target design is:

```text
functional semantics
+
compiler-proven safe storage reuse
+
LuaJIT runtime and FFI
```

That combination is the entire point.

---

## 44. Recommended First Agent Prompt

The first coding agent should **not** be told simply "implement a Roc-to-LuaJIT compiler."

Instead, give it this narrower mission:

> Inspect the current Roc compiler and identify the smallest stable point at which a LuaJIT source backend could consume already-typed, monomorphized, lowered Roc code. Produce `ARCHITECTURE.md` documenting the compiler pipeline, existing backend interfaces, ownership/ARC insertion points, representation metadata, platform call model, and the exact minimal changes needed to add an experimental backend. Do not implement the backend yet except for disposable probes required to verify claims. Every architectural claim should cite code locations in the inspected Roc revision.

Once that document is correct, proceed to M1 using strict differential TDD.

---

## 45. Reference Repositories

Roc:

https://github.com/roc-lang/roc

Roc language site:

https://www.roc-lang.org/

LuaJIT:

https://luajit.org/

The implementation should pin the exact Roc commit used during development because compiler internals may change rapidly.

---

## 46. One-Sentence Project Definition

> **roc-luajit is an experimental Roc compiler backend that emits Lua 5.1-compatible source for LuaJIT, preserving Roc's functional value semantics while exploiting LuaJIT's JIT, garbage collector, FFI, and embedding ecosystem.**
