#!/bin/zsh
set -e
cd "$(dirname "$0")/.."
mkdir -p build && cp Tests/test_main.swift build/main.swift
swiftc -swift-version 5 -target arm64-apple-macosx13.0 -framework AppKit -framework IOKit -framework Carbon \
  Sources/MacTouch/HIDDescriptor.swift Sources/MacTouch/TouchDevice.swift Sources/MacTouch/Config.swift Sources/MacTouch/DisplayMapper.swift \
  Sources/MacTouch/GestureRecognizer.swift Sources/MacTouch/Actions.swift Sources/MacTouch/MA3Bridge.swift build/main.swift -o build/tests
build/tests
