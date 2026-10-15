.PHONY: app run debug test test-extension extension-zip clean

app:
	scripts/build-app.sh

debug:
	CONFIG=debug scripts/build-app.sh

run: app
	open build/Stash.app

test:
	swift test

test-extension:
	node --test "Extension/tests/*.test.mjs"

clean:
	rm -rf .build build

# Chrome Web Store package: the extension without its tests.
extension-zip:
	rm -f Extension/stash-extension.zip
	cd Extension && zip -rX stash-extension.zip . -x 'tests/*' '*.DS_Store' '*.zip'
