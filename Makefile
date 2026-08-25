PROJECT := macos/Mnemos.xcodeproj
SCHEME := Mnemos
DERIVED_DATA := .deriveddata
APP := $(DERIVED_DATA)/Build/Products/Debug/Mnemos.app

.PHONY: project build test run open clean icons mcp-install mcp-build mcp-smoke

icons:
	swift scripts/generate-icons.swift

project:
	xcodegen generate --spec project.yml --project macos --project-root .

build: project
	xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" -configuration Debug -derivedDataPath "$(DERIVED_DATA)" CODE_SIGNING_ALLOWED=NO build

test: project
	xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" -configuration Debug -derivedDataPath "$(DERIVED_DATA)" CODE_SIGNING_ALLOWED=NO test

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
