# jam-objc

Objective-C runtime bindings for the [Jam](../jam) programming language.
A port of [mitchellh/zig-objc](https://github.com/mitchellh/zig-objc)
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

The window init takes an `NSRect` (four f64s) by value. `msgSend` handles
that like anything else: the argument type ends up in the synthesized
signature and jam lowers the aggregate the way the arm64 ABI wants it
(v0-v3).

## How it works

zig-objc casts `objc_msgSend` to a function pointer with the target
method's signature, so arguments and returns travel in the right
registers. Jam's `@callC` intrinsic does the same cast: it builds the
function type from the argument types plus an explicit return type.
`msgSend` is a variadic `cfn` that forwards into it:

```jam
pub extern fn objc_msgSend();             // declared only for its address

pub cfn msgSend(self: Object, R: type, op: Sel, args: ...) R {
    return @callC(R, objc_msgSend as u64, self.value, op.value, args...);
}
```

Each call site gets a clone specialized to its argument shape, so any
arity and any mix of ints, floats and by-value structs comes out with
the right signature. What zig-objc does with comptime tuples, jam does
with per-callsite clones; `MSGSEND.md` has the whole story. `id`,
`Class`, `SEL` and object pointers all travel as `u64`, which also means
tagged pointers just work.

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

There are no per-signature wrappers to maintain. Argument types are
taken as-is, so spell scalars out (`x.value`, `p as u64`, `0 as i64`).
If a call doesn't fit the wrappers, use `@callC` directly with
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
plain C): protocols nothing references aren't registered, so
`objc_getProtocol("NSFileManagerDelegate")` is NULL with Foundation
dlopen'd while `NSURLSessionDelegate`, `NSCoding` etc. are present.

## Blocks

Simplified relative to zig-objc (no comptime, so no synthesized
copy/dispose helpers or signature strings): captures must be plain data,
and captured object pointers are not auto-retained on `_Block_copy`.

```jam
const block = import("block");
const { Block } = import("block");

const Caps = struct { x: i32, y: i32 };
const AddBlock = Block(Caps);

fn addImpl(ctx: u64) i32 {
    var caps: *const Caps = AddBlock.capturesFrom(ctx);
    return caps.*.x + caps.*.y;
}

var b: AddBlock = AddBlock.init(Caps { x: 2, y: 3 }, addImpl as u64);
block.invoke0i32((&b) as u64);   // 5
b.deinit();                      // only after all copies are released
```

Pass `(&b) as u64` as a method argument wherever ObjC expects a block.

## Known limitations

(`LIMITATIONS.md` has the analysis of what fixing each would take.)

* Method type encodings for `addMethod` are hand-written strings.

x86_64 works: build with `jam -C target=x86_64-apple-darwin` and the
suite runs under Rosetta 2. `msgSend` picks `objc_msgSend_stret` for
memory-class returns per instantiation (the branch folds away on arm64,
which has no stret entry point), and jam classifies aggregates per SysV
on that target — byval stack args, eightbyte coercion, sret returns.

By-value structs of any size work: jam classifies aggregates per the
C ABI on indirect calls (HFAs in v-registers, small structs packed into
GP words, big ones caller-copied with sret returns) — the 48-byte
`NSAffineTransformStruct` round trip in tests.jam is the proof.

## Jam compiler bugs found while porting

All fixed in ../jam since:

1. `u64 as *const T` miscompiled inside generic instantiations — the
   cast target skipped the active substitution, and returning `p.*` of a
   struct broke the byref model. `block.jam`'s captures cast lives
   inside the generic now.
2. Duplicate extern declarations with different signatures silently
   produced renamed LLVM declarations (`objc_msgSend.1`); mismatched
   duplicates are a compile error now.
3. Trailing commas in call argument lists were a parse error.
