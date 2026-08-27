SCHEME := Cove
PROJECT := Cove.xcodeproj
CONFIGURATION ?= Debug

# Shared SwiftPM scratch path: all Framework packages build into one
# directory so shared dependencies (TraceKit, AMSMB2, ...) compile once
# instead of once per downstream package. The name `.build` is already
# covered by .gitignore.
SPM_SCRATCH := $(CURDIR)/.build

.PHONY: generate build test clean

generate:
	xcodegen

build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIGURATION) build

test:
	swift test --package-path Frameworks/TraceKit --scratch-path $(SPM_SCRATCH)
	swift test --package-path Frameworks/KeychainKit --scratch-path $(SPM_SCRATCH)
	swift test --package-path Frameworks/SourceKit --scratch-path $(SPM_SCRATCH)
	swift test --package-path Frameworks/ImagePipeline --scratch-path $(SPM_SCRATCH)
	swift test --package-path Frameworks/CacheKit --scratch-path $(SPM_SCRATCH)
	swift test --package-path Frameworks/PreheatKit --scratch-path $(SPM_SCRATCH)
	swift test --package-path Frameworks/ComicKit --scratch-path $(SPM_SCRATCH)
	swift test --package-path Frameworks/ReaderKit --scratch-path $(SPM_SCRATCH)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination 'platform=macOS' test
	swift build --package-path Frameworks/SourceKit --product smb-spike --scratch-path $(SPM_SCRATCH)

clean:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) clean || true
	rm -rf $(SPM_SCRATCH)
