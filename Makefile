PROJECT := macos/Mnemos.xcodeproj
SCHEME := Mnemos
DERIVED_DATA := .deriveddata
APP := $(DERIVED_DATA)/Build/Products/Debug/Mnemos.app

.PHONY: project build run open clean

project:
	xcodegen generate --spec project.yml --project macos --project-root .

build: project
	xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" -configuration Debug -derivedDataPath "$(DERIVED_DATA)" CODE_SIGNING_ALLOWED=NO build

run: build
	open "$(APP)"

open: project
	open "$(PROJECT)"

clean:
	xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" -derivedDataPath "$(DERIVED_DATA)" clean
