PROJECT := macos/Mnemos.xcodeproj
SCHEME := Mnemos
DERIVED_DATA := .deriveddata
APP := $(DERIVED_DATA)/Build/Products/Debug/Mnemos.app

.PHONY: project build run open clean mcp-install mcp-build mcp-smoke

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

mcp-install:
	cd mcp && npm ci

mcp-build:
	cd mcp && npm run build

mcp-smoke:
	cd mcp && npm run smoke
