# jam-objc

Objective-C runtime bindings for the [Jam](https://github.com/raphamorim/jama) programming language. This project is a work in progress, as the language evolves it will be updated.

Credits note: I wrote/ported this mostly from [mitchellh/zig-objc](https://github.com/mitchellh/zig-objc), I kept Mitchell license in the repo just in case.

```jam
const objc = import("objc");
const { Object, Class, sel } = import("objc");
const { Option } = import("std/option");

fn main() {
    objc.loadFoundation();

    match (objc.getClass("NSString")) {
        Some(NSString) {
            const msg = "hello from jam";
            const s = NSString.msgSend(Object, sel("stringWithUTF8String:"), msg.ptr as u64);
            const len = s.msgSend(u64, sel("length"));
            // ...
        }
        None {
            // noop
        }
    }
}
```

Run the test suite:

```jam
jam test -lobjc tests.jam
```

Works as x86_64 too, cross-compile and macOS runs the binaries under rosetta 2:

```
jam -C target=x86_64-apple-darwin test -lobjc tests.jam
```

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
| `objc.comptimeEncode(Fn)`             | write the encoding string yourself              |
| `objc.boolResult/boolParam`           | `objc.fromBool/toBool`                          |
| `objc.free`                           | `objc.freeCopied`                               |

Note: there are no per-signature wrappers to maintain. Argument types are taken as-is, so spell scalars out (`x.value`, `p as u64`, `0 as i64`). If a call doesn't fit the wrappers, use `@callC` directly with `objc.msgSendAddr()` / `objc.msgSendSuperAddr()`.

## Frameworks

`jam` has no `-framework` linker flag yet! So Foundation/AppKit classes are registered at runtime instead:

```jam
objc.loadFoundation();
objc.loadAppKit();
objc.loadFramework("/System/Library/Frameworks/Metal.framework/Metal");
```

Only `-lobjc` is needed at link time. One side effect (also visible in plain C): protocols nothing references aren't registered, so `objc_getProtocol("NSFileManagerDelegate")` is NULL with Foundation dlopen'd while `NSURLSessionDelegate`, `NSCoding` etc. are present.

## Blocks

```jam
const block = import("block");

const Caps = struct {
    x: i32,
    y: i32
};

const AddBlock = block.Block(Caps);
fn addImpl(ctx: u64) i32 {
    var caps = AddBlock.capturesFrom(ctx);
    return caps.*.x + caps.*.y;
}

var b = AddBlock.init(Caps { x: 2, y: 3 }, addImpl as u64);

block.invoke0i32((&b) as u64); // 5

// TODO: hook this up in jam drop system
b.deinit();
```
