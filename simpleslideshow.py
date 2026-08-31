import sys
import os
from PyQt6.QtWidgets import (QApplication, QMainWindow, QLabel, QFileDialog, 
                             QPushButton, QHBoxLayout, QVBoxLayout, QWidget, 
                             QSpinBox, QFrame, QMessageBox)
from PyQt6.QtCore import Qt, QTimer, QEvent
from PyQt6.QtGui import QPixmap, QImage
from PIL import Image, ImageOps

class NoFocusSpinBox(QSpinBox):
    """Custom SpinBox that ignores keyboard focus to keep shortcuts functional."""
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.setFocusPolicy(Qt.FocusPolicy.NoFocus)

class PhotoSlideshow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("Simple Slideshow")
        self.setStyleSheet("background-color: black;")
        
        # Enable window Drag and Drop support
        self.setAcceptDrops(True)
        
        self.image_paths = []
        self.pending_icon_paths = []
        self.current_index = 0
        self.delay_ms = 5000
        self.is_paused = False
        self.valid_exts = ('.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp', '.heic')
        
        # Transition & Auto-hide Timers
        self.timer = QTimer(self)
        self.timer.timeout.connect(self.advance_slideshow)
        
        self.hide_timer = QTimer(self)
        self.hide_timer.setSingleShot(True)
        self.hide_timer.timeout.connect(self.hide_controls)

        # Timer to batch processing of files dropped onto icon / passed via argv
        self.icon_drop_timer = QTimer(self)
        self.icon_drop_timer.setSingleShot(True)
        self.icon_drop_timer.timeout.connect(self.process_icon_drops)

        # Central Image Display Label
        self.image_label = QLabel(self)
        self.image_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.setCentralWidget(self.image_label)

        # UI Overlay Panels
        self.init_welcome_ui()
        self.init_control_panel()

        self.setMouseTracking(True)
        self.centralWidget().setMouseTracking(True)

        # Check command-line arguments (handles initial launch via icon drop)
        if len(sys.argv) > 1:
            for arg in sys.argv[1:]:
                if os.path.exists(arg):
                    self.pending_icon_paths.append(arg)
            if self.pending_icon_paths:
                self.icon_drop_timer.start(50)

    def init_welcome_ui(self):
        self.welcome_widget = QWidget(self)
        self.welcome_widget.setStyleSheet("background-color: #1e1e1e; border-radius: 10px;")
        
        layout = QVBoxLayout()
        layout.setContentsMargins(30, 20, 30, 20)

        title = QLabel("Simple Slideshow")
        title.setStyleSheet("color: white; font-size: 18px; font-weight: bold;")
        title.setAlignment(Qt.AlignmentFlag.AlignCenter)
        layout.addWidget(title)

        subtitle = QLabel("Drag & Drop photos or a folder anywhere (or onto the App Icon)")
        subtitle.setStyleSheet("color: #888; font-size: 12px;")
        subtitle.setAlignment(Qt.AlignmentFlag.AlignCenter)
        layout.addWidget(subtitle)

        btn_open = QPushButton("📁 Choose Photo Folder")
        btn_open.setStyleSheet("background-color: #1a73e8; color: white; font-size: 14px; padding: 8px 15px; border-radius: 4px; margin-top: 10px;")
        btn_open.clicked.connect(self.select_folder)
        btn_open.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        layout.addWidget(btn_open)

        btn_quit = QPushButton("Quit")
        btn_quit.setStyleSheet("background-color: #444; color: white; padding: 5px; border-radius: 4px;")
        btn_quit.clicked.connect(QApplication.instance().quit)
        btn_quit.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        layout.addWidget(btn_quit)

        self.welcome_widget.setLayout(layout)
        self.welcome_widget.adjustSize()

    def init_control_panel(self):
        self.controls_widget = QFrame(self)
        self.controls_widget.setStyleSheet("background-color: rgba(30, 30, 30, 220); border-radius: 8px;")
        
        layout = QHBoxLayout()
        layout.setContentsMargins(12, 6, 12, 6)
        layout.setSpacing(10)

        btn_prev = QPushButton("◄ Back")
        btn_prev.setStyleSheet("color: white; background: #333; padding: 6px 12px; border-radius: 4px;")
        btn_prev.clicked.connect(self.prev_photo)
        btn_prev.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        layout.addWidget(btn_prev)

        self.btn_pause = QPushButton("Pause")
        self.btn_pause.setStyleSheet("color: white; background: #1a73e8; padding: 6px 14px; border-radius: 4px;")
        self.btn_pause.clicked.connect(self.toggle_pause)
        self.btn_pause.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        layout.addWidget(self.btn_pause)

        btn_next = QPushButton("Next ►")
        btn_next.setStyleSheet("color: white; background: #333; padding: 6px 12px; border-radius: 4px;")
        btn_next.clicked.connect(self.next_photo)
        btn_next.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        layout.addWidget(btn_next)

        lbl_delay = QLabel("Delay:")
        lbl_delay.setStyleSheet("color: #ccc; font-weight: bold;")
        layout.addWidget(lbl_delay)

        self.speed_spinbox = NoFocusSpinBox()
        self.speed_spinbox.setRange(1, 60)
        self.speed_spinbox.setSingleStep(1)
        self.speed_spinbox.setValue(5)
        self.speed_spinbox.setSuffix("s")
        self.speed_spinbox.setFixedWidth(52)
        self.speed_spinbox.setStyleSheet("""
            QSpinBox {
                background-color: #2a2a2a;
                color: #ffffff;
                border: 1px solid #444444;
                border-radius: 4px;
                padding: 3px 2px;
                font-weight: bold;
            }
            QSpinBox::up-button, QSpinBox::down-button {
                width: 0px;
            }
        """)
        self.speed_spinbox.valueChanged.connect(self.update_delay_from_spinbox)
        layout.addWidget(self.speed_spinbox)

        btn_folder = QPushButton("📁 Open")
        btn_folder.setStyleSheet("color: white; background: #444; padding: 6px 12px; border-radius: 4px;")
        btn_folder.clicked.connect(self.select_folder)
        btn_folder.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        layout.addWidget(btn_folder)

        btn_exit = QPushButton("✕ Exit")
        btn_exit.setStyleSheet("color: white; background: #ea4335; padding: 6px 12px; border-radius: 4px;")
        btn_exit.clicked.connect(QApplication.instance().quit)
        btn_exit.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        layout.addWidget(btn_exit)

        self.controls_widget.setLayout(layout)
        self.controls_widget.adjustSize()
        self.controls_widget.hide()

    def resizeEvent(self, event):
        if self.welcome_widget.isVisible():
            self.welcome_widget.move(
                (self.width() - self.welcome_widget.width()) // 2,
                (self.height() - self.welcome_widget.height()) // 2
            )
        self.controls_widget.move(
            (self.width() - self.controls_widget.width()) // 2,
            int(self.height() * 0.88)
        )
        if self.image_paths:
            self.show_photo()
        super().resizeEvent(event)

    # --- App Icon Drop Handling ---
    def handle_app_open_file(self, file_path):
        self.pending_icon_paths.append(file_path)
        self.icon_drop_timer.start(100)

    def process_icon_drops(self):
        paths_to_process = list(self.pending_icon_paths)
        self.pending_icon_paths.clear()
        self.load_paths(paths_to_process)

    # --- Window Drag & Drop Handlers ---
    def dragEnterEvent(self, event):
        if event.mimeData().hasUrls():
            event.acceptProposedAction()

    def dropEvent(self, event):
        dropped_files = [url.toLocalFile() for url in event.mimeData().urls()]
        self.load_paths(dropped_files)

    def load_paths(self, paths):
        parsed_paths = []
        for path in paths:
            if os.path.isdir(path):
                for root, _, files in os.walk(path):
                    for file in sorted(files):
                        if file.lower().endswith(self.valid_exts):
                            parsed_paths.append(os.path.join(root, file))
            elif os.path.isfile(path) and path.lower().endswith(self.valid_exts):
                parsed_paths.append(path)

        if parsed_paths:
            self.image_paths = sorted(list(set(parsed_paths)))
            self.welcome_widget.hide()
            self.show_controls()
            self.current_index = 0
            self.show_photo()
            self.start_timer()
        else:
            QMessageBox.information(self, "No Valid Images", "No supported image files found.")

    def select_folder(self):
        folder = QFileDialog.getExistingDirectory(self, "Select Folder with Photos")
        if folder:
            self.load_paths([folder])

    def show_photo(self):
        if not self.image_paths:
            return

        path = self.image_paths[self.current_index]
        try:
            pil_img = Image.open(path)
            pil_img = ImageOps.exif_transpose(pil_img).convert("RGBA")
            
            win_w, win_h = self.width(), self.height()
            pil_img.thumbnail((win_w, win_h), Image.Resampling.LANCZOS)

            data = pil_img.tobytes("raw", "RGBA")
            qimg = QImage(data, pil_img.width, pil_img.height, QImage.Format.Format_RGBA8888)
            pixmap = QPixmap.fromImage(qimg)

            self.image_label.setPixmap(pixmap)
        except Exception as e:
            print(f"Skipping {path}: {e}")
            self.next_photo()

    def advance_slideshow(self):
        if not self.is_paused and self.image_paths:
            self.current_index = (self.current_index + 1) % len(self.image_paths)
            self.show_photo()

    def start_timer(self):
        if not self.is_paused:
            self.timer.start(self.delay_ms)

    def next_photo(self):
        if self.image_paths:
            self.current_index = (self.current_index + 1) % len(self.image_paths)
            self.show_photo()
            self.start_timer()

    def prev_photo(self):
        if self.image_paths:
            self.current_index = (self.current_index - 1) % len(self.image_paths)
            self.show_photo()
            self.start_timer()

    def toggle_pause(self):
        self.is_paused = not self.is_paused
        self.btn_pause.setText("Play" if self.is_paused else "Pause")
        self.btn_pause.setStyleSheet(
            "color: white; background: #34a853; padding: 6px 14px; border-radius: 4px;" if self.is_paused 
            else "color: white; background: #1a73e8; padding: 6px 14px; border-radius: 4px;"
        )
        if self.is_paused:
            self.timer.stop()
        else:
            self.start_timer()

    def update_delay_from_spinbox(self, val):
        self.delay_ms = val * 1000
        if not self.is_paused and self.image_paths:
            self.start_timer()

    def adjust_speed(self, delta):
        new_val = self.speed_spinbox.value() + delta
        if 1 <= new_val <= 60:
            self.speed_spinbox.setValue(new_val)

    def mouseMoveEvent(self, event):
        if self.image_paths:
            self.show_controls()
        super().mouseMoveEvent(event)

    def show_controls(self):
        self.controls_widget.show()
        self.controls_widget.raise_()
        self.hide_timer.start(3000)

    def hide_controls(self):
        if self.image_paths:
            self.controls_widget.hide()

    def keyPressEvent(self, event):
        key = event.key()
        
        if self.image_paths and key in (Qt.Key.Key_Right, Qt.Key.Key_Left, Qt.Key.Key_Space, Qt.Key.Key_Up, Qt.Key.Key_Down):
            self.show_controls()

        if key == Qt.Key.Key_Right:
            self.next_photo()
        elif key == Qt.Key.Key_Left:
            self.prev_photo()
        elif key == Qt.Key.Key_Space:
            self.toggle_pause()
        elif key == Qt.Key.Key_Up:
            self.adjust_speed(1)
        elif key == Qt.Key.Key_Down:
            self.adjust_speed(-1)
        elif key == Qt.Key.Key_Escape:
            QApplication.instance().quit()
        else:
            super().keyPressEvent(event)

class ApplicationFilter(QApplication):
    """Custom Application object to intercept macOS FileOpen events."""
    def __init__(self, sys_argv):
        super().__init__(sys_argv)
        self.window = None

    def event(self, event):
        if event.type() == QEvent.Type.FileOpen:
            file_path = event.file()
            if self.window:
                self.window.handle_app_open_file(file_path)
            return True
        return super().event(event)

if __name__ == '__main__':
    app = ApplicationFilter(sys.argv)
    window = PhotoSlideshow()
    app.window = window
    window.showFullScreen()
    sys.exit(app.exec())
