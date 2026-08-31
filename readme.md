# SimpleSlideshow

A lightweight, distraction-free, full-screen photo slideshow viewer for macOS. Built with Python, PyQt6, and Pillow, and packaged into a native macOS app bundle via PyInstaller.

---

## Key Features

- **Full-Screen Playback:** Launches natively in borderless full-screen mode with auto-hiding navigation controls.
- **EXIF Auto-Rotation:** Leverages Pillow (`ImageOps.exif_transpose`) to correctly rotate images taken on modern camera and smartphone orientation sensors.
- **Multi-Format Support:** Compatible with `.png`, `.jpg`, `.jpeg`, `.gif`, `.bmp`, `.webp`, and `.heic` image formats.
- **Flexible File Ingestion:**
  - Drag and drop files or folders directly into the running application window.
  - Drag files or folders directly onto the application icon in macOS Finder/Dock.
  - Choose folders via a native macOS file dialog.
- **Keyboard Shortcuts & On-Screen Controls:** Complete control over playback, frame progression, and transition delays using hotkeys or overlay GUI controls.

---

## Keyboard Shortcuts

| Key | Action |
| :--- | :--- |
| **`Space`** | Play / Pause slideshow |
| **`Right Arrow (→)`** | Next photo |
| **`Left Arrow (←)`** | Decrease photo index (Previous photo) |
| **`Up Arrow (↑)`** | Increase slide delay (+1 sec) |
| **`Down Arrow (↓)`** | Decrease slide delay (-1 sec) |
| **`Escape`** | Exit Application |

---

## Prerequisites

- **macOS**
- **Python 3.10+** (specifically built with Homebrew's Python 3.14)

---

## Complete Setup, Development & Build Guide

Run these commands in order from your terminal to go from setup to a fully compiled macOS `.app` bundle:

```bash
# 1. Navigate to the project directory
cd SimpleSlideshow

# 2. Create the virtual environment
/opt/homebrew/opt/python@3.14/bin/python3.14 -m venv myenv

# 3. Activate the virtual environment
source myenv/bin/activate

# 4. Install dependencies
pip install --upgrade pip
pip install -r requirements.txt

# 5. (Optional) Run and test from source code directly
python simpleslideshow.py

# 6. Make the build script executable and compile the .app bundle
chmod +x build.sh
./build.sh

# 7. Test run the built macOS application binary
dist/SimpleSlideshow.app/Contents/MacOS/SimpleSlideshow


## Project Structure
SimpleSlideshow/
├── build.sh                # Clean and build shell script
├── simpleslideshow.py      # Main Application Source Code
├── simpleslideshow.spec    # PyInstaller specification configuration
├── requirements.txt        # Python package dependencies
├── Info.plist              # macOS application metadata configuration
├── README.md               # Documentation