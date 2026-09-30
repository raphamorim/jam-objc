JAM ?= jam

.PHONY: test run-example-foundation run-example-subclass run-example-blocks \
        run-example-window run-example-draw run-example-button clean

test:
	$(JAM) test -lobjc tests.jam

# Console tour of Foundation (NSString/NSNumber/NSDate/NSArray).
run-example-foundation:
	cd examples && $(JAM) run -lobjc foundation.jam

# A runtime-built ObjC class with an ivar and jam-fn methods.
run-example-subclass:
	cd examples && $(JAM) run -lobjc subclass.jam

# Sort an NSArray with a jam-built comparator block.
run-example-blocks:
	cd examples && $(JAM) run -lobjc blocks.jam

# Open the native macOS window example (close it or Cmd-Q to quit).
run-example-window:
	cd examples && $(JAM) run -lobjc window.jam

# Custom NSView drawing — jam paints every drawRect:.
run-example-draw:
	cd examples && $(JAM) run -lobjc draw.jam

# Interactive click counter — NSButton target/action into a jam fn.
run-example-button:
	cd examples && $(JAM) run -lobjc button.jam

clean:
	rm -f output output.o examples/output examples/output.o
