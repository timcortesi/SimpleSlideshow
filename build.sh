swiftc -O -parse-as-library -framework AVKit -framework AppKit main.swift -o simpleslideshow

mkdir -p "Simple Slideshow.app/Contents/MacOS"
mkdir -p "Simple Slideshow.app/Contents/Resources"

# Move the compiled binary into MacOS/ and rename it to match your Info.plist executable name
mv simpleslideshow "Simple Slideshow.app/Contents/MacOS/simpleslideshow"

# Save your XML configuration text into Info.plist and place it inside Contents/
# (Make sure your Info.plist file is saved in your current working directory first)
cp Info.plist "Simple Slideshow.app/Contents/Info.plist"

# Move your icon file into Resources/
cp app_icon.icns "Simple Slideshow.app/Contents/Resources/app_icon.icns"

chmod +x "Simple Slideshow.app/Contents/MacOS/simpleslideshow"
codesign --force --deep --sign - "Simple Slideshow.app"