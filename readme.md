# SimpleSlideshow

A lightweight, distraction-free, native macOS photo and video slideshow viewer built with SwiftUI and AppKit. 

---

## Key Features

- **Full-Screen Playback:** Launches natively with auto-hiding controls and a clean, distraction-free interface.
- **Rich Media Support:** Seamlessly handles both images (`.png`, `.jpg`, `.jpeg`, `.gif`, `.bmp`, `.webp`, `.heic`, `.tiff`) and videos (`.mp4`, `.mkv`, `.mov`, `.avi`).
- **Interactive Gallery & Grid Navigation:** Browse folders visually with high-performance async thumbnails, clean 2D grid arrow navigation, and built-in folder traversal.
- **Robust Video Controls:** Precise scrubbing timeline, play/pause states, and fast-forward/rewind keyboard shortcuts for video playback.
- **Flexible File Ingestion:**
  - Drag and drop files or folders directly into the dropzone or running app window.
  - Open files directly from macOS Finder/Dock.
  - Choose folders via a native macOS dialog.

---

## Keyboard Shortcuts

| Key | Action |
| :--- | :--- |
| **`Space`** | Play / Pause slideshow |
| **`Right / Left Arrows (→ / ←)`** | Next / Previous item (strictly within row boundaries) |
| **`Up / Down Arrows (↑ / ↓)`** | Move up/down grid rows, or adjust slideshow delay / video seek |
| **`Cmd + Right / Left`** | Fast-forward / Rewind active video |
| **`Return`** | Open selected folder or start slideshow |
| **`Escape`** | Exit slideshow / Go back a folder / Exit app |

---

## Project Structure
```text
SimpleSlideshow/
├── Simple Slideshow.app/   # Compiled macOS Application Bundle
├── main.swift              # Main SwiftUI & AppKit Source Code
├── build.sh                # Build and compilation script
├── app_icon.icns           # macOS Application Icon
├── app_icon.png            # Source Icon Image
└── Info.plist              # macOS application metadata configuration