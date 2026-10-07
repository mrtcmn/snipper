.PHONY: app run debug test test-extension clean

app:
	scripts/build-app.sh

debug:
	CONFIG=debug scripts/build-app.sh

run: app
	open build/Snipper.app

test:
	swift test

test-extension:
	node --test "Extension/tests/*.test.mjs"

clean:
	rm -rf .build build
