SCHEME := Cove
PROJECT := Cove.xcodeproj
CONFIGURATION ?= Debug

.PHONY: generate build test clean

generate:
	xcodegen

build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIGURATION) build

test:
	swift test --package-path Frameworks/TraceKit
	swift test --package-path Frameworks/KeychainKit
	swift test --package-path Frameworks/SourceKit
	swift test --package-path Frameworks/ImagePipeline
	swift test --package-path Frameworks/CacheKit
	swift test --package-path Frameworks/PreheatKit
	swift test --package-path Frameworks/ComicKit
	swift test --package-path Frameworks/ReaderKit
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination 'platform=macOS' test
	swift build --package-path Frameworks/SourceKit --product smb-spike

clean:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) clean || true
	rm -rf Frameworks/TraceKit/.build Frameworks/KeychainKit/.build Frameworks/SourceKit/.build Frameworks/ImagePipeline/.build Frameworks/CacheKit/.build Frameworks/PreheatKit/.build Frameworks/ComicKit/.build Frameworks/ReaderKit/.build
