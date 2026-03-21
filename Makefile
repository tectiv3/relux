.PHONY: build open run clean generate

XCODEPROJ := Relux.xcodeproj

build:
	xcodebuild -project $(XCODEPROJ) -scheme Relux -destination 'platform=macOS' \
		build -skipPackageUpdates -skipMacroValidation \
		OTHER_SWIFT_FLAGS='$$(inherited) -Xfrontend -disable-sandbox'

open:
	@open $(XCODEPROJ)

run: build
	@open "$$(xcodebuild -project $(XCODEPROJ) -scheme Relux -configuration Debug -showBuildSettings 2>/dev/null | grep ' BUILT_PRODUCTS_DIR' | sed 's/.*= //')/Relux.app"

clean:
	xcodebuild -project $(XCODEPROJ) -scheme Relux clean

generate:
	xcodegen generate
