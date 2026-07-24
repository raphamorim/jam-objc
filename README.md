# jam-objc

Objective-C runtime bindings for the [Jam](../jam) programming language —
a port of [mitchellh/zig-objc](https://github.com/mitchellh/zig-objc)
(vendored in `references/zig-objc`).

```jam
const objc = import("objc");
const { Object, Class, sel } = import("objc");
const { Option } = import("std").option;

fn main() {
    objc.loadFoundation();

    match (objc.getClass("NSString")) {
        Option(Class).Some(NSString) {
            const msg: []u8 = "hello from jam";
            const s: Object = NSString.msgSend(Object, sel("stringWithUTF8String:"), msg.ptr as u64);
            const len: u64 = s.msgSend(u64, sel("length"));
            // ...
        }
        Option(Class).None { }
    }
}
```

Run the test suite (ports of every zig-objc `test` block):

```sh
make test          # = jam test -lobjc tests.jam
```

## Examples

[`examples/window.jam`](examples/window.jam) opens a native macOS window
straight through the runtime (`NSApplication` + `NSWindow`):

```sh
cd examples && jam run -lobjc window.jam   # close the window / Cmd-Q to quit
```

It also exercises the hardest send shape: a window needs
`-initWithContentRect:styleMask:backing:defer:`, whose first argument is
an `NSRect` (four `f64`s) passed **by value**. The same `msgSend` call
handles it — the argument's type shapes the synthesized C signature, and
jam lowers the homogeneous-float aggregate through the arm64 C ABI
(`v0–v3`) correctly.

## How it works

zig-objc's core trick is casting `objc_msgSend` to a function pointer
with the *target method's* signature, so arguments and returns travel
in the registers the C ABI expects. Jam's `@callC` intrinsic does that
cast: it synthesizes the exact function type from the call's argument
types and the explicit return type. The whole library boils down to one
variadic `cfn` forwarding into it:

```jam
pub extern fn objc_msgSend();             // declared only for its address

pub cfn msgSend(self: Object, R: type, op: Sel, args: ...) R {
    return @callC(R, objc_msgSend as u64, self.value, op.value, args...);
}
```

Each call site instantiates a clone specialized to its argument shape,
so every arity and every mix of ints/floats/by-value structs gets the
correct signature — the moral equivalent of zig-objc's comptime tuple
reflection (see `MSGSEND.md` for the design history). `id`, `Class`,
`SEL`, and object pointers all travel as `u64` (which also makes tagged
pointers a non-issue).

## API map (zig-objc → jam-objc)

| zig-objc                              | jam-objc                                        |
|---------------------------------------|-------------------------------------------------|
| `objc.getClass(name) ?Class`          | `objc.getClass(name) Option(Class)`             |
| `objc.getMetaClass`, `getProtocol`    | same names, `Option(...)` returns               |
| `objc.sel(name)` / `Sel.registerName` | same                                            |
| `obj.msgSend(u64, "hash", .{})`       | `obj.msgSend(u64, sel("hash"))`                 |
| `obj.msgSend(Object, "init", .{})`    | `obj.msgSend(Object, sel("init"))`              |
| `obj.msgSend(f64, sel, .{})`          | `obj.msgSend(f64, sel)`                         |
| `obj.msgSend(u64, sel, .{3.5})`       | `obj.msgSend(u64, sel, 3.5)`                    |
| `obj.msgSendSuper(Super, R, sel, a)`  | `obj.msgSendSuper(R, superclass, sel, a)`       |
| `Object.fromId(id)`                   | `Object.fromId(id)` (id is `u64`)               |
| `obj.getClass/getClassName/copy/...`  | same names                                      |
| `obj.retain/release`                  | same                                            |
| `obj.getProperty(T, "name")`          | `obj.getProperty("name") u64` / `getPropertyObj`|
| `obj.setProperty("name", v)`          | `obj.setProperty("name", v)` (v: u64)           |
| `cls.getProperty/copyPropertyList`    | same (`PropertyList` frees itself on drop)      |
| `cls.addMethod(name, imp)`            | `cls.addMethod(name, imp as u64, "i@:ii")`      |
| `cls.replaceMethod/addIvar`           | same                                            |
| `allocate/register/disposeClassPair`  | same                                            |
| `Property.getName/copyAttributeValue` | same (free with `objc.freeCopied`)              |
| `Protocol.*`                          | same                                            |
| `AutoreleasePool.init/deinit`         | `AutoreleasePool.init()`; pops itself on drop   |
| `objc.Iterator` (NSFastEnumeration)   | `import("iterator").Iterator`                   |
| `objc.Block(Captures, Args, Return)`  | `import("block").Block(Captures)`               |
| `objc.comptimeEncode(Fn)`             | — write the encoding string yourself            |
| `objc.boolResult/boolParam`           | `objc.fromBool/toBool`                          |
| `objc.free`                           | `objc.freeCopied`                               |

There are no per-signature wrappers to add: any argument mix works
directly (`obj.msgSend(u64, sel, 3.5, flags)`); argument types are taken
as-is, so spell scalars explicitly (`x.value`, `p as u64`, `0 as i64`).
For anything the wrappers can't express, drive `@callC` yourself with
`objc.msgSendAddr()` / `objc.msgSendSuperAddr()`.

## Frameworks

`jam` has no `-framework` linker flag, so Foundation/AppKit classes are
registered at runtime instead:

```jam
objc.loadFoundation();
objc.loadAppKit();
objc.loadFramework("/System/Library/Frameworks/Metal.framework/Metal");
```

Only `-lobjc` is needed at link time. One side effect (also visible in
plain C): protocols nothing references aren't registered — e.g.
`objc_getProtocol("NSFileManagerDelegate")` is NULL with Foundation
dlopen'd, while `NSURLSessionDelegate`, `NSCoding`, etc. are present.

## Blocks

Simplified relative to zig-objc (no comptime → no synthesized
copy/dispose helpers or signature strings): captures must be plain data,
and captured object pointers are **not** auto-retained on `_Block_copy`.

```jam
const block = import("block");
const { Block } = import("block");

const Caps = struct { x: i32, y: i32 };
const AddBlock = Block(Caps);

fn addImpl(ctx: u64) i32 {
    var caps: *const Caps = block.capturesAddr(ctx) as *const Caps;
    return caps.*.x + caps.*.y;
}

var b: AddBlock = AddBlock.init(Caps { x: 2, y: 3 }, addImpl as u64);
block.invoke0i32((&b) as u64);   // 5
b.deinit();                      // only after all copies are released
```

Pass `(&b) as u64` as a method argument wherever ObjC expects a block.

## Known limitations

* **Structs by value, both directions, work** (`NSPoint` / `NSSize` /
  `NSRect`, `CGPoint` / `CGRect`, `NSRange`) — `examples/window.jam`
  relies on by-value `NSRect` args, and `[win frame]`-style struct
  *returns* round-trip too. Both needed a compiler fix: jam's
  indirect-call path declared aggregates by value in the call signature
  but passed/received a pointer, so the registers the C ABI uses were
  garbage (blank Cocoa windows; segfaulting struct returns). Fixed in
  `../jam` by loading aggregate args and spilling aggregate returns at
  the `CallIndirect` site, so LLVM applies the platform ABI (arm64 HFA →
  v0–v3). **Requires a jam built at or after those fixes.**
* **arm64 only.** x86_64 needs `objc_msgSend_fpret`/`_stret` dispatch
  per return type (zig-objc selects these at comptime).
* Method type encodings for `addMethod` are hand-written strings.

## Jam compiler bugs found while porting

Kept as a punch list for ../jam:

1. **Struct args/returns through fn pointers** were miscompiled (args put
   a pointer where the C signature wanted a by-value HFA → garbage;
   returns handed back an aggregate value where jam's byref model wanted
   a pointer → segfault). **Both FIXED** in `../jam` (`CallIndirect`
   loads by-value aggregate args and spills by-value aggregate returns;
   LLVM then applies the platform ABI). Direct `extern fn` struct args
   are still by-pointer, but objc goes through the `CallIndirect` pun.
2. **`u64 as *const T` miscompiles inside generic instantiations**
   (concrete `T` works). Worked around in `block.jam` by keeping all
   pointer casts in non-generic code.
3. **Duplicate extern declarations with different signatures** silently
   produce renamed LLVM declarations (`objc_msgSend.1`) and call-site
   miscompiles; identical duplicates are fine.
4. Trailing commas in call argument lists are a parse error (struct
   literals accept them).
5. A direct `u64 as fn(...)` cast is unsupported — punning through a
   `union { addr: u64, f: fn(...) }` works and is what this library does.
