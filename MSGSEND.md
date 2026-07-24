# The msgSend problem

Why `objc.jam` has a zoo of `msgSend0`, `msgSend1`, `msgSendF0`, `msgSendD1`,
`msgSendObj1`, … instead of one generic `msgSend`, what it would take to fix,
and where that stands.

## The constraint

`objc_msgSend` is the entry point for every Objective-C method call. It is **not
an ordinary variadic function** — you must call it cast to the *exact* signature
of the target method:

```objc
// WRONG — calling it variadically passes args by the C-varargs ABI,
// which differs from the fixed-args ABI (floats land in the wrong
// registers, structs are mishandled):
objc_msgSend(obj, sel, 3.5);

// RIGHT — cast to the target method's real signature, then call:
((double (*)(id, SEL, double))objc_msgSend)(obj, sel, 3.5);
```

So every binding to `objc_msgSend`, in every language, must produce a
**fixed-signature indirect call** whose parameter and return types match the
method being invoked. The only question is *who writes those signatures and
when*.

## How jam-objc does it today

jam has no way to synthesize a function type from a call's arguments, so
`objc.jam` hand-writes the signature table as untagged unions — one per
`(arity, float-shape)` — and puns `objc_msgSend`'s address through the union's
`f` field. The union pun **is** jam's `@ptrCast`:

```jam
pub const Sig1 = union { addr: u64, f: fn(u64, u64, u64) u64 };
pub const SigD1 = union { addr: u64, f: fn(u64, u64, f64) u64 };  // f64 arg
pub const SigF0 = union { addr: u64, f: fn(u64, u64) f64 };       // f64 return

pub fn rawSend1(target: u64, op: u64, a: u64) u64 {
    var caster: Sig1 = Sig1 { addr: objc_msgSend as u64 };
    var send: fn(u64, u64, u64) u64 = caster.f;
    return send(target, op, a);
}
```

The current surface (counts from `objc.jam`):

| layer | count | what |
|---|---:|---|
| `Sig*` unions | 9 | one per arity / float shape (the hand-written `@ptrCast` table) |
| `rawSend*` dispatch fns | 12 | `rawSend0..4`, `rawSendF0/1`, `rawSendD1/2`, `rawSendSuper0..2` |
| public `msgSend*` wrappers | ~25 | `Class` + `Object` method wrappers (`msgSend0..4`, `msgSendObj*`, `msgSendF*`, `msgSendD*`, `msgSendSuper*`) |

Everything travels as `u64` (ids, selectors, pointers, ints); `f32`/`f64` need
their own shapes because a float must be declared in the signature to land in an
FP register. A method with an unusual signature (e.g. an `NSRect`-by-value arg
or return — see `examples/window.jam`) needs a *fresh* hand-written union.

That last point is the real cost: **new signatures cost library code.**

## Why jam can't just write one `msgSend`

The two reference bindings each get a single ergonomic call by leaning on a
*general language feature* — and **jam has none of them**:

### Zig — comptime variadic generics

zig-objc writes one function:

```zig
obj.msgSend(f64, "doubleValue", .{});
obj.msgSend(Object, "initWithContentRect:...", .{ rect, style, backing, false });
```

At compile time it reflects the argument tuple (`@typeInfo`), builds the exact
function type (`@Type`/`@Fn`), casts `objc_msgSend` to it (`@ptrCast`), and
invokes it (`@call`). No per-arity code anywhere. This needs **tuples +
`anytype` + `@typeInfo` + `@Type` + `@call`** — a comptime-reflection stack.

### Rust — a macro + traits + tuples

rust-objc / objc2 write:

```rust
let d: f64 = msg_send![obj, doubleValue];
let win: id = msg_send![obj, initWithContentRect:rect styleMask:style ..];
```

`msg_send!` is a **syntactic macro**: it builds the selector from the call
syntax and packs the args into a **tuple** `(a, b)`, then calls a generic
`send_message<T, A, R>(obj, sel, args: A) where A: MessageArguments`. The
`MessageArguments` **trait** is implemented for tuples `()`, `(A,)`, `(A,B)`, …
up to arity ~11, **macro-generated**, each impl `mem::transmute`-ing
`objc_msgSend` to `extern fn(*mut Object, Sel, A, B) -> R` and calling it.

The crucial detail: **the per-arity "zoo" exists in Rust too.** It's just
macro-generated and hidden behind `msg_send!`. Rust needs **a macro system + a
trait system + tuple types** to make it disappear from view.

## The honest summary

`objc_msgSend` forces *someone* to write a fixed signature per call shape.

- **Zig** generates it at the call site from a tuple (comptime reflection).
- **Rust** generates ~11 tuple impls with a macro and hides them behind another
  macro.
- **jam** has neither comptime reflection, nor macros, nor traits/tuples — so
  jam-objc writes the table by hand.

jam-objc's wrapper zoo isn't a mistake; it's the cost of jam not (yet) having
any of the three general subsystems the other two languages already had.

## The options being weighed (compiler-side, in `../jam`)

| plan | new subsystem(s) needed | status | doc |
|---|---|---|---|
| **`@callC`** — a bespoke variadic intrinsic `@callC(R, fnAddr, args…)` that synthesizes the fixed signature from the args' *static* types at astgen and lowers to the (now C-ABI-correct) `CallIndirect`. | none — ~145 LOC, zero per-arity code in the compiler | **planned, recommended** | `../jam/CALLC_PLAN.md` |
| **Variadic generics** (the Zig route) | tuples + variadic/`anytype` params + monomorphization-over-packs | **rejected** — ~370 LOC on top of `@callC`, byte-identical binary, eliminates *zero* wrappers | `../jam/VARIADICS_PLAN.md` |
| **Macro system** (the Rust route) | a macro system **+ traits + tuple types** (three subsystems) | under evaluation — likely the largest, for the same one-library payoff | `../jam/MSGSEND_OPTIONS.md` |
| **`cfn`-native expansion** | possibly variadic `cfn` (jam's `cfn` already emits code into the caller, like a macro, but isn't variadic) | under evaluation — the most jam-native candidate | `../jam/MSGSEND_OPTIONS.md` |

### What `@callC` actually changes here

`@callC` is jam's equivalent of Rust's `MessageArguments::invoke` (the
transmute-and-call) — but **variadic at the intrinsic level, so it needs zero
per-arity impls**, where Rust hand-generates ~11. Once it lands:

- the 9 `Sig*` unions and 12 `rawSend*` dispatch fns **disappear** (~64 LOC of
  internal machinery gone);
- the public `msgSend*` wrappers become **optional convenience sugar** — a user
  can call `@callC` directly at *any* arity/shape:

  ```jam
  // no wrapper, no union — any signature, inline:
  var d: f64    = @callC(f64,    msgSendAddr(), obj.value, sel("doubleValue").value);
  var r: NSRect = @callC(NSRect, msgSendAddr(), win.value, sel("frame").value);
  ```

- **new signatures cost zero library code.**

What `@callC` does **not** do is hide the `R` / `.value` / `msgSendAddr()`
plumbing — that call-site polish is exactly what Rust's `msg_send!` macro buys,
and the only thing that would get jam there is a macro system (a separate,
much larger feature). So with `@callC`, the suffixed wrappers may stay as
ergonomic shorthand, but they stop being *fundamental* — they're a thin
courtesy over one variadic primitive, not a hand-maintained ABI table.

## Current direction

Build `@callC` (`../jam/CALLC_PLAN.md`). It removes the load-bearing part of the
zoo for ~145 LOC and zero codegen risk, and makes the remaining wrappers
optional. The bigger general features (variadic generics, a macro system) are
not justified by this one library's ergonomics; see `../jam/VARIADICS_PLAN.md`
and `../jam/MSGSEND_OPTIONS.md` for the full cost/benefit.

## References

- `objc.jam` — the `Sig*` / `rawSend*` / `msgSend*` surface described above.
- `examples/window.jam` — a real call site needing an `NSRect`-by-value
  signature (the case that motivates "new signatures shouldn't cost code").
- `../jam/CALLC_PLAN.md`, `../jam/VARIADICS_PLAN.md`, `../jam/MSGSEND_OPTIONS.md`
  — the compiler-side plans.
- zig-objc `references/zig-objc/src/msg_send.zig`; rust-objc
  [`message/mod.rs`](https://github.com/SSheldon/rust-objc/blob/master/src/message/mod.rs)
  + [`macros.rs`](https://github.com/SSheldon/rust-objc/blob/master/src/macros.rs).
