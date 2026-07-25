# Fixing the limitations

What it would take to clear README's known-limitations list and the jam
punch list, where each fix lives (`../jam` vs here), and a recommended
order. Companion to `MSGSEND.md`, which covers the design history of the
one limitation already fixed.

## 1. x86_64

Done — `jam -C target=x86_64-apple-darwin` cross-compiles, the whole jam
corpus and this suite (and jam-metal's GPU tests) pass under Rosetta 2.
Shipped as sketched: `@isX86_64()` folds per target, `msgSend` selects
`_stret` per instantiation (`@sizeOf(R) > 16`, dead-dropped on arm64),
fpret skipped (only long double needs it), and the SysV eightbyte
classifier landed in jam's `classify_c_abi` with byval stack args.
Original analysis:

Today the library is arm64-only. The blocker is not the runtime API —
it's dispatch and ABI:

**Dispatch.** arm64 has exactly one entry point per family
(`objc_msgSend`, `objc_msgSendSuper`); the ABI puts an indirect struct
return in x8 and the runtime handles it. x86_64 splits per return type
(zig-objc's table, `references/zig-objc/src/msg_send.zig:100-152`):

| return type            | x86_64 entry point       |
|------------------------|--------------------------|
| ints, pointers, void   | `objc_msgSend`           |
| struct > 16 bytes      | `objc_msgSend_stret`     |
| struct <= 16 bytes     | `objc_msgSend`           |
| f64                    | `objc_msgSend_fpret`     |
| f32                    | `objc_msgSend`           |

(`_fpret` strictly only matters for `long double`, which jam doesn't
have; zig-objc routes f64 through it anyway and both land in xmm0.
Following zig-objc is the safe copy.)

`msgSend` can do this selection at instantiation time — `R` is
substituted when the clone body lowers, so `@sizeOf(R)` folds to a
constant, and jam's OS predicates already fold and drop dead arms
(`@isDarwin` in `../jam` astgen). Two small pieces are missing:

* an arch predicate in jam — `@isX86_64()` / `@isAarch64()`, a clone of
  the `@isDarwin` family (~20 LOC in `astgen_at_call`);
* `msgSendStretAddr()` / `msgSendFpretAddr()` here, plus the branch in
  the `msgSend` / `msgSendSuper` cfns:

  ```jam
  var addr: u64 = msgSendAddr();
  if (@isX86_64() and @sizeOf(R) > 16) {   // folds away per-instantiation
      addr = msgSendStretAddr();
  }
  ```

  `R = void` needs a special case before the `@sizeOf` (order the
  branches, or a `@sizeOf(void) == 0` rule in jam).

**ABI.** The bigger half. `@callC`'s aggregate guard is reasoned from
AAPCS64 (`../jam/CALLC_PLAN.md` §4): it admits HFAs of ≤ 4 floats
because arm64 puts them in v0–v3. SysV has no such exemption past 16
bytes — a by-value `NSRect` (32 bytes) goes to memory on x86_64, so the
current admission would miscompile there. Until real per-target
classification lands (§2), the guard needs to be target-gated: on
x86_64, reject HFAs > 16 bytes too. ~20 LOC.

**Testing.** Apple Silicon machines run x86_64 binaries under
Rosetta 2, so a test lane is `--target x86_64-apple-darwin` + `arch
-x86_64 ./output`. jam's `Target::from_triple_str` exists but the CLI
has no target flag yet — that flag is a prerequisite and useful beyond
this repo.

Cost: ~20 LOC compiler (arch predicate) + ~20 LOC guard gating +
~30 LOC here, then the real work is §2's SysV classifier and the CLI
target flag. Verdict: doable, mostly blocked on §2.

## 2. The by-value struct boundary (`@callC` phase 4)

Done — shipped in ../jam as `abi::classify_c_abi` + a classified
`CallIndirect` lowering, exactly as sketched below; the guard is gone on
arm64 and `msgSend` takes/returns any C struct. The x86_64 half still
waits on §1. Original analysis:

The guard admits HFAs of ≤ 4 same-width floats or ≤ 2 full 64-bit
words; anything else (div_t's `{i32,i32}`, mixed float/int, > 16 bytes)
is a compile error. That covers every struct Cocoa actually passes, but
the fix is well understood — it's phase 4 of `../jam/CALLC_PLAN.md`,
made concrete:

* an AArch64 classifier (port of zig's `arch/aarch64/abi.zig`
  `classifyType`, ~80 LOC): HFA / register-pair / memory;
* `CallIndirect` lowering changes (`../jam` `jir_codegen.rs`):
  * ≤ 16-byte aggregates with sub-word fields coerce to `[n x i64]`
    (clang-style) — unlocks `div_t` shapes;
  * HFAs lower as float arrays (what LLVM already does implicitly);
  * \> 16-byte args copy to a caller alloca and pass the pointer (what
    AAPCS64 specifies; jam-metal does this by hand for `MTLSize` today);
  * \> 16-byte non-HFA returns get an sret alloca — LLVM places sret in
    x8 on arm64, which is exactly what `objc_msgSend` expects;
* delete the guard on arm64, keep it (SysV-shaped) on x86_64 until the
  eightbyte classifier is ported too (zig's `arch/x86_64/abi.zig`,
  ~200 LOC — this is the same work §1 needs).

Payoff: `msgSend` takes and returns any C struct; jam-metal's
`dispatchThreadgroups` stops hand-passing pointers and takes `MTLSize`
by value; the two reject tests flip to must-pass corpus tests.

Cost: ~250 LOC + tests for arm64; the x86_64 classifier roughly doubles
it. Verdict: the highest-value item on this list, and the natural next
compiler milestone.

## 3. Hand-written type encodings

zig-objc synthesizes `"i@:ii"`-style strings from the function type at
comptime (`references/zig-objc/src/encoding.zig` — a `@typeInfo`
recursion). jam has no comptime type reflection, so `addMethod` and
block signatures take the string spelled out.

The jam-shaped fix would be an `@objcEncode(T)` intrinsic: astgen maps a
type to its encoding fragment (`u64` → `Q`, `i32` → `i`, `f64` → `d`,
pointers → `^v`, `Object` → `@`, structs → `{name=...}` recursively) and
returns a `str` constant, with a small builder here concatenating
`ret + "@:" + args`. ~60 LOC in the compiler, ~20 here.

But the strings are five characters long, appear only in `addMethod` /
`replaceMethod` / block construction, and getting them wrong fails
loudly at the first send. Verdict: not worth an intrinsic yet; keep the
strings, revisit if class construction becomes a bigger part of the API.

## 4. The punch list (compiler bugs that shaped this code)

From README here and in jam-metal, with where the fix went in `../jam`.
Every row is fixed now. One correction from the debugging: the
"slashed-path field access" failure was really bare-name shadowing — an
imported module's private fn (`metal.jam`'s `nsString`) overwrote the
entry module's same-named fn in the registry, so calls resolved to the
wrong module's function. Bare names now belong to the first module that
claims them, and each module's bodies resolve their own names first.

| bug | fix | size |
|---|---|---|
| extern fns unreachable through an import handle (`objc.objc_getClass`) | the import-handle branch of `astgen_dotted_call` only looks up `module.name`; fall back to the bare name for externs (C symbols register unqualified) | small |
| module consts unreachable through a handle (`metal.StorageModeShared`) | member-access lowering treats the handle as a local; check `import_handle_module` first and inline the const like a bare reference | small |
| field access on a call result fails for slashed-path imports (`nsString("q").value` in jam-metal) | return-type alias resolution misses when the module key has slashes; needs a look at `requalify_type` / alias registration for multi-segment paths | medium |
| `u64 as *const T` miscompiles inside generic instantiations | cast lowering doesn't apply the active substitution to `T` before computing the pointee; `block.jam` works around it | medium |
| duplicate extern declarations with different signatures silently rename (`objc_msgSend.1`) | a decl-time diagnostic: same extern name, different signature → error | small |
| trailing commas in call argument lists | parser accepts them in struct literals already; mirror in the call-arg loop | tiny |

The first two would let this library drop its destructure-workarounds
and `metal.jam` its duplicated externs.

## Recommended order

1. Punch-list smalls (handle lookups, trailing commas, duplicate-extern
   diagnostic) — each removes a real wart for little cost.
2. §2 phase 4 on arm64 — biggest unlock, well specified, all the
   reference code exists.
3. §1 x86_64 — after §2, since it reuses the classification machinery;
   needs the CLI `--target` flag and a Rosetta test lane.
4. §3 encodings — only if class construction grows.
