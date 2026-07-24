JAM ?= jam

.PHONY: test run-example-window clean

test:
	$(JAM) test -lobjc tests.jam

# Open the native macOS window example (close it or Cmd-Q to quit).
run-example-window:
	cd examples && $(JAM) run -lobjc window.jam

clean:
	rm -f output output.o
