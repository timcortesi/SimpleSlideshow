#!/bin/bash

# Set deployment target (e.g. 26.0 for macOS Ventura or higher)
export MACOSX_DEPLOYMENT_TARGET=26.0
ARCH=$(uname -m)

# Compile binary with explicit deployment target
swiftc -O -parse-as-library \
  -target "${ARCH}-apple-macosx26.0" \
  -framework AVKit \
  -framework AppKit \
  main.swift -o simpleslideshow

mkdir -p "Simple Slideshow.app/Contents/MacOS"
mkdir -p "Simple Slideshow.app/Contents/Resources"

mv simpleslideshow "Simple Slideshow.app/Contents/MacOS/simpleslideshow"
cp Info.plist "Simple Slideshow.app/Contents/Info.plist"

if [ -f app_icon.icns ]; then
  cp app_icon.icns "Simple Slideshow.app/Contents/Resources/app_icon.icns"
fi

chmod +x "Simple Slideshow.app/Contents/MacOS/simpleslideshow"
codesign --force --deep --sign - "Simple Slideshow.app"