import sys
import os
import time
from PyQt6.QtWidgets import (QApplication, QMainWindow, QLabel, QFileDialog, 
                             QPushButton, QHBoxLayout, QVBoxLayout, QWidget, 
                             QSpinBox, QFrame, QMessageBox, QScrollArea, QGridLayout,
                             QSlider, QProgressBar)
from PyQt6.QtCore import Qt, QTimer, QRunnable, QThreadPool, pyqtSignal, QObject, QUrl, QEvent
from PyQt6.QtGui import QPixmap, QImage
from PyQt6.QtMultimedia import QMediaPlayer, QAudioOutput
from PyQt6.QtMultimediaWidgets import QVideoWidget
from PIL import Image, ImageOps

# --- Global Thumbnail Memory Cache ---
THUMBNAIL_CACHE = {}
MAX_CACHE_SIZE = 1000

class WorkerSignals(QObject):
    finished = pyqtSignal(str, QPixmap)

class ThumbnailWorker(QRunnable):
    """Off-thread image loading and downsampling worker."""
    def __init__(self, file_path, is_video=False, target_size=(140, 110)):
        super().__init__()
        self.file_path = file_path
        self.is_video = is_video
        self.target_size = target_size
        self.signals = WorkerSignals()

    def run(self):
        try:
            mtime = os.path.getmtime(self.file_path)
            cache_key = f"{self.file_path}_{mtime}"
            
            if cache_key in THUMBNAIL_CACHE:
                self.signals.finished.emit(self.file_path, THUMBNAIL_CACHE[cache_key])
                return
            
            pil_img = None
            if self.is_video:
                try:
                    import cv2
                    cap = cv2.VideoCapture(self.file_path)
                    if cap.isOpened():
                        fps = cap.get(cv2.CAP_PROP_FPS)
                        total_frames = cap.get(cv2.CAP_PROP_FRAME_COUNT)
                        if fps > 0 and total_frames > 0:
                            duration_ms = (total_frames / fps) * 1000
                            target_ms = duration_ms * 0.1
                            cap.set(cv2.CAP_PROP_POS_MSEC, target_ms)
                        success, frame = cap.read()
                        if not success:
                            cap.set(cv2.CAP_PROP_POS_FRAMES, 0)
                            success, frame = cap.read()
                        cap.release()
                        if success:
                            frame_rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
                            pil_img = Image.fromarray(frame_rgb)
                except Exception:
                    pil_img = None
            else:
                pil_img = Image.open(self.file_path)
                pil_img = ImageOps.exif_transpose(pil_img)

            if pil_img:
                pil_img = pil_img.convert("RGBA")
                pil_img.thumbnail(self.target_size, Image.Resampling.LANCZOS)
                data = pil_img.tobytes("raw", "RGBA")
                qimg = QImage(data, pil_img.width, pil_img.height, QImage.Format.Format_RGBA8888)
                pixmap = QPixmap.fromImage(qimg)
            else:
                pixmap = QPixmap()

            if len(THUMBNAIL_CACHE) >= MAX_CACHE_SIZE:
                THUMBNAIL_CACHE.pop(next(iter(THUMBNAIL_CACHE)))

            if not pixmap.isNull():
                THUMBNAIL_CACHE[cache_key] = pixmap
            self.signals.finished.emit(self.file_path, pixmap)
        except Exception:
            self.signals.finished.emit(self.file_path, QPixmap())


class NonScrollingScrollArea(QScrollArea):
    """Custom QScrollArea ignoring arrow keys so grid item navigation works cleanly."""
    def keyPressEvent(self, event):
        if event.key() in (Qt.Key.Key_Up, Qt.Key.Key_Down, Qt.Key.Key_Left, Qt.Key.Key_Right):
            event.ignore()
        else:
            super().keyPressEvent(event)


class NoFocusSpinBox(QSpinBox):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.setFocusPolicy(Qt.FocusPolicy.NoFocus)


class NoFocusSlider(QSlider):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.setFocusPolicy(Qt.FocusPolicy.NoFocus)


class GalleryItemCard(QFrame):
    CARD_WIDTH = 180
    CARD_HEIGHT = 180

    def __init__(self, item_type, name, path, click_callback=None):
        super().__init__()
        self.item_type = item_type
        self.name = name
        self.path = path
        self.click_callback = click_callback
        
        self.setFixedSize(self.CARD_WIDTH, self.CARD_HEIGHT)
        self.setCursor(Qt.CursorShape.PointingHandCursor)
        self.setFocusPolicy(Qt.FocusPolicy.StrongFocus)

        self.normal_style = """
            QFrame {
                background-color: #1a1a1a;
                border: 2px solid #2a2a2a;
                border-radius: 12px;
            }
            QFrame:hover {
                background-color: #262626;
                border: 2px solid #1a73e8;
            }
        """
        self.focused_style = """
            QFrame {
                background-color: #262626;
                border: 2px solid #34a853;
                border-radius: 12px;
            }
        """
        self.setStyleSheet(self.normal_style)

        layout = QVBoxLayout(self)
        layout.setContentsMargins(10, 10, 10, 10)
        layout.setAlignment(Qt.AlignmentFlag.AlignCenter)

        if self.item_type == 'up':
            icon_label = QLabel("⬅")
            icon_label.setStyleSheet("font-size: 38px; color: #1a73e8; border: none; background: transparent;")
            icon_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
            layout.addWidget(icon_label)
        elif self.item_type == 'folder':
            icon_label = QLabel("📁")
            icon_label.setStyleSheet("font-size: 44px; border: none; background: transparent;")
            icon_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
            layout.addWidget(icon_label)
        elif self.item_type in ('image', 'video'):
            self.img_label = QLabel("⏳")
            self.img_label.setFixedSize(140, 110)
            self.img_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
            self.img_label.setStyleSheet("font-size: 24px; border: none; background: transparent; color: #555;")
            layout.addWidget(self.img_label)

        name_label = QLabel(self.name)
        name_label.setStyleSheet("color: white; font-size: 13px; font-weight: bold; border: none; background: transparent;")
        name_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        name_label.setWordWrap(True)
        layout.addWidget(name_label)

    def set_thumbnail(self, pixmap):
        if hasattr(self, 'img_label'):
            if not pixmap.isNull():
                self.img_label.setPixmap(pixmap)
                self.img_label.setText("")
            else:
                self.img_label.setText("🎥" if self.item_type == 'video' else "🖼️")

    def mousePressEvent(self, event):
        if event.button() == Qt.MouseButton.LeftButton and self.click_callback:
            self.click_callback(self)

    def keyPressEvent(self, event):
        if event.key() in (Qt.Key.Key_Return, Qt.Key.Key_Enter, Qt.Key.Key_Space) and self.click_callback:
            self.click_callback(self)
        else:
            super().keyPressEvent(event)

    def focusInEvent(self, event):
        self.setStyleSheet(self.focused_style)
        super().focusInEvent(event)

    def focusOutEvent(self, event):
        self.setStyleSheet(self.normal_style)
        super().focusOutEvent(event)


class PhotoSlideshow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("Simple Slideshow")
        self.setStyleSheet("background-color: #121212;")
        
        self.setAcceptDrops(True)
        self.setFocusPolicy(Qt.FocusPolicy.StrongFocus)
        self.resize(700, 480)
        self.center_on_screen()
        
        self.image_exts = ('.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp', '.heic')
        self.video_exts = ('.mp4', '.mkv', '.mov', '.avi')
        self.valid_exts = self.image_exts + self.video_exts

        self.root_folder = None
        self.current_folder = None
        self.media_paths = []
        self.current_index = 0
        self.delay_ms = 5000
        self.is_paused = False
        self.grid_cards = []
        self.card_map = {}

        # Ramp Tracking State
        self.last_scrub_time = 0
        self.scrub_ramp_step = 1.0

        self.thread_pool = QThreadPool()
        self.thread_pool.setMaxThreadCount(4)

        # Timers
        self.timer = QTimer(self)
        self.timer.timeout.connect(self.advance_slideshow)
        
        self.hide_timer = QTimer(self)
        self.hide_timer.setSingleShot(True)
        self.hide_timer.timeout.connect(self.hide_controls)

        self.pending_icon_paths = []
        self.icon_drop_timer = QTimer(self)
        self.icon_drop_timer.setSingleShot(True)
        self.icon_drop_timer.timeout.connect(self.process_icon_drops)

        # Central Layout
        self.central_widget = QWidget(self)
        self.setCentralWidget(self.central_widget)
        self.main_layout = QVBoxLayout(self.central_widget)
        self.main_layout.setContentsMargins(20, 20, 20, 20)

        # Fullscreen Image Display
        self.image_label = QLabel(self)
        self.image_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.main_layout.addWidget(self.image_label)
        self.image_label.hide()

        # Video Player Widgets
        self.video_widget = QVideoWidget(self)
        self.video_widget.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        self.main_layout.addWidget(self.video_widget)
        self.video_widget.hide()

        self.player = QMediaPlayer()
        self.audio_output = QAudioOutput()
        self.player.setAudioOutput(self.audio_output)
        self.player.setVideoOutput(self.video_widget)
        
        self.player.mediaStatusChanged.connect(self.on_media_status_changed)
        self.player.positionChanged.connect(self.on_video_position_changed)
        self.player.durationChanged.connect(self.on_video_duration_changed)

        self.init_welcome_ui()
        self.init_browser_ui()
        self.init_control_panel()

        self.setMouseTracking(True)
        self.centralWidget().setMouseTracking(True)

        if len(sys.argv) > 1:
            for arg in sys.argv[1:]:
                if os.path.exists(arg):
                    self.pending_icon_paths.append(arg)
            if self.pending_icon_paths:
                self.icon_drop_timer.start(50)

    def center_on_screen(self):
        screen = QApplication.primaryScreen().geometry()
        size = self.geometry()
        self.move((screen.width() - size.width()) // 2, (screen.height() - size.height()) // 2)

    def init_welcome_ui(self):
        self.welcome_widget = QFrame(self.central_widget)
        self.welcome_widget.setStyleSheet("""
            QFrame {
                background-color: #1a1a1a;
                border: 2px dashed #444444;
                border-radius: 12px;
            }
        """)
        
        layout = QVBoxLayout(self.welcome_widget)
        layout.setContentsMargins(40, 40, 40, 40)
        layout.setAlignment(Qt.AlignmentFlag.AlignCenter)
        layout.setSpacing(12)

        icon_label = QLabel("📷")
        icon_label.setStyleSheet("font-size: 54px; border: none; background: transparent;")
        icon_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        layout.addWidget(icon_label)

        title = QLabel("Drop Media or Folders Here")
        title.setStyleSheet("color: white; font-size: 22px; font-weight: bold; border: none; background: transparent;")
        title.setAlignment(Qt.AlignmentFlag.AlignCenter)
        layout.addWidget(title)

        subtitle = QLabel("Drag & drop images, videos, or click below to start")
        subtitle.setStyleSheet("color: #888888; font-size: 13px; border: none; background: transparent;")
        subtitle.setAlignment(Qt.AlignmentFlag.AlignCenter)
        layout.addWidget(subtitle)

        btn_open = QPushButton("📁 Choose Folder")
        btn_open.setStyleSheet("""
            QPushButton {
                background-color: #1a73e8; color: white; font-size: 14px;
                font-weight: bold; padding: 10px 24px; border: none;
                border-radius: 6px; margin-top: 10px;
            }
            QPushButton:hover { background-color: #1557b0; }
        """)
        btn_open.clicked.connect(self.select_folder)
        btn_open.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        layout.addWidget(btn_open)

        self.main_layout.addWidget(self.welcome_widget)

    def init_browser_ui(self):
        self.browser_widget = QWidget(self.central_widget)
        browser_layout = QVBoxLayout(self.browser_widget)
        browser_layout.setContentsMargins(40, 40, 40, 40)

        header_layout = QHBoxLayout()
        self.browser_title = QLabel("Folder Gallery")
        self.browser_title.setStyleSheet("color: white; font-size: 24px; font-weight: bold;")
        header_layout.addWidget(self.browser_title)
        header_layout.addStretch()

        btn_back = QPushButton("✕ Exit to Dropzone")
        btn_back.setStyleSheet("""
            QPushButton {
                background-color: #333333; color: white; font-size: 13px;
                padding: 8px 16px; border-radius: 6px;
            }
            QPushButton:hover { background-color: #ea4335; }
        """)
        btn_back.clicked.connect(self.return_to_dropzone)
        btn_back.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        header_layout.addWidget(btn_back)

        browser_layout.addLayout(header_layout)

        self.scroll_area = NonScrollingScrollArea()
        self.scroll_area.setWidgetResizable(True)
        self.scroll_area.setStyleSheet("QScrollArea { border: none; background: transparent; }")

        self.grid_container = QWidget()
        self.grid_layout = QGridLayout(self.grid_container)
        self.grid_layout.setSpacing(20)
        self.grid_layout.setAlignment(Qt.AlignmentFlag.AlignTop | Qt.AlignmentFlag.AlignLeft)
        
        self.scroll_area.setWidget(self.grid_container)
        browser_layout.addWidget(self.scroll_area)

        self.main_layout.addWidget(self.browser_widget)
        self.browser_widget.hide()

    def init_control_panel(self):
        self.controls_widget = QFrame(self)
        self.controls_widget.setStyleSheet("background-color: rgba(30, 30, 30, 230); border-radius: 8px;")
        
        # Explicit Native Compositor Binding
        self.controls_widget.setAttribute(Qt.WidgetAttribute.WA_NativeWindow, True)
        self.controls_widget.setAttribute(Qt.WidgetAttribute.WA_DontCreateNativeAncestors, True)

        v_layout = QVBoxLayout(self.controls_widget)
        v_layout.setContentsMargins(12, 8, 12, 8)
        v_layout.setSpacing(6)

        # Video Scrubber Row
        self.scrubber_container = QWidget()
        s_layout = QHBoxLayout(self.scrubber_container)
        s_layout.setContentsMargins(0, 0, 0, 0)
        s_layout.setSpacing(8)

        self.lbl_video_time = QLabel("0:00 / 0:00")
        self.lbl_video_time.setStyleSheet("color: #aaa; font-size: 11px; font-weight: bold;")
        s_layout.addWidget(self.lbl_video_time)

        self.video_slider = NoFocusSlider(Qt.Orientation.Horizontal)
        self.video_slider.setRange(0, 1000)
        self.video_slider.setStyleSheet("""
            QSlider::groove:horizontal {
                border: none; height: 4px; background: #444; border-radius: 2px;
            }
            QSlider::sub-page:horizontal {
                background: #1a73e8; border-radius: 2px;
            }
            QSlider::handle:horizontal {
                background: #ffffff; border: none; width: 12px; height: 12px;
                margin: -4px 0; border-radius: 6px;
            }
        """)
        self.video_slider.sliderMoved.connect(self.user_seek_video)
        s_layout.addWidget(self.video_slider)

        v_layout.addWidget(self.scrubber_container)

        # Controls Row
        h_layout = QHBoxLayout()
        h_layout.setContentsMargins(0, 0, 0, 0)
        h_layout.setSpacing(10)

        btn_prev = QPushButton("◄ Back")
        btn_prev.setStyleSheet("color: white; background: #333; padding: 6px 12px; border-radius: 4px;")
        btn_prev.clicked.connect(self.prev_media)
        btn_prev.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        h_layout.addWidget(btn_prev)

        self.btn_pause = QPushButton("Pause")
        self.btn_pause.setStyleSheet("color: white; background: #1a73e8; padding: 6px 14px; border-radius: 4px;")
        self.btn_pause.clicked.connect(self.toggle_pause)
        self.btn_pause.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        h_layout.addWidget(self.btn_pause)

        btn_next = QPushButton("Next ►")
        btn_next.setStyleSheet("color: white; background: #333; padding: 6px 12px; border-radius: 4px;")
        btn_next.clicked.connect(self.next_media)
        btn_next.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        h_layout.addWidget(btn_next)

        self.lbl_delay = QLabel("Delay:")
        self.lbl_delay.setStyleSheet("color: #ccc; font-weight: bold;")
        h_layout.addWidget(self.lbl_delay)

        self.speed_spinbox = NoFocusSpinBox()
        self.speed_spinbox.setRange(1, 60)
        self.speed_spinbox.setSingleStep(1)
        self.speed_spinbox.setValue(5)
        self.speed_spinbox.setSuffix("s")
        self.speed_spinbox.setFixedWidth(52)
        self.speed_spinbox.setStyleSheet("""
            QSpinBox {
                background-color: #2a2a2a; color: #ffffff;
                border: 1px solid #444444; border-radius: 4px;
                padding: 3px 2px; font-weight: bold;
            }
            QSpinBox::up-button, QSpinBox::down-button { width: 0px; }
        """)
        self.speed_spinbox.valueChanged.connect(self.update_delay_from_spinbox)
        h_layout.addWidget(self.speed_spinbox)

        btn_exit = QPushButton("✕ Exit")
        btn_exit.setStyleSheet("color: white; background: #ea4335; padding: 6px 12px; border-radius: 4px;")
        btn_exit.clicked.connect(self.return_to_dropzone)
        btn_exit.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        h_layout.addWidget(btn_exit)

        v_layout.addLayout(h_layout)

        # Progress bar overlay with native rendering pass-through
        self.video_progress_bar = QProgressBar(self)
        self.video_progress_bar.setAttribute(Qt.WidgetAttribute.WA_NativeWindow, True)
        self.video_progress_bar.setAttribute(Qt.WidgetAttribute.WA_DontCreateNativeAncestors, True)
        self.video_progress_bar.setRange(0, 1000)
        self.video_progress_bar.setTextVisible(False)
        self.video_progress_bar.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents)
        self.video_progress_bar.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        self.video_progress_bar.setStyleSheet("""
            QProgressBar {
                background: rgba(255, 255, 255, 30);
                border: none;
                height: 4px;
                border-radius: 8px;
            }
            QProgressBar::chunk {
                background-color: #1a73e8;
                border-radius: 8px;
            }
        """)
        self.video_progress_bar.hide()

        self.controls_widget.adjustSize()
        self.controls_widget.hide()

    def update_overlay_geometry(self):
        p_width = self.width()
        p_height = self.height()

        self.controls_widget.move(
            (p_width - self.controls_widget.width()) // 2,
            int(p_height * 0.84)
        )
        self.video_progress_bar.setGeometry(0, p_height - 4, p_width, 4)

    def get_dynamic_cols(self):
        available_width = self.scroll_area.viewport().width() - 80
        item_w = GalleryItemCard.CARD_WIDTH + 20
        return max(1, available_width // item_w)

    def reflow_grid(self):
        if not self.grid_cards:
            return
        cols = self.get_dynamic_cols()
        for idx, card in enumerate(self.grid_cards):
            row, col = idx // cols, idx % cols
            self.grid_layout.addWidget(card, row, col)

    def resizeEvent(self, event):
        self.update_overlay_geometry()
        if self.browser_widget.isVisible():
            self.reflow_grid()
        elif self.isFullScreen() and self.media_paths and (self.image_label.isVisible() or self.video_widget.isVisible()):
            self.show_current_media()
        super().resizeEvent(event)

    def handle_app_open_file(self, file_path):
        self.pending_icon_paths.append(file_path)
        self.icon_drop_timer.start(100)

    def process_icon_drops(self):
        paths = list(self.pending_icon_paths)
        self.pending_icon_paths.clear()
        self.load_paths(paths)

    def dragEnterEvent(self, event):
        if event.mimeData().hasUrls():
            event.acceptProposedAction()

    def dropEvent(self, event):
        dropped_files = [url.toLocalFile() for url in event.mimeData().urls()]
        self.load_paths(dropped_files)

    def select_folder(self):
        folder = QFileDialog.getExistingDirectory(self, "Select Folder")
        if folder:
            self.load_paths([folder])

    def load_paths(self, paths):
        if not paths:
            return
        target_path = paths[0]
        if os.path.isfile(target_path):
            target_path = os.path.dirname(target_path)

        if not os.path.exists(target_path):
            return

        self.root_folder = target_path
        self.render_directory(self.root_folder)

    def render_directory(self, folder_path):
        self.stop_video_pipeline()
        self.current_folder = folder_path
        self.welcome_widget.hide()
        self.image_label.hide()
        self.video_widget.hide()
        self.controls_widget.hide()
        self.video_progress_bar.hide()

        self.thread_pool.clear()

        for i in reversed(range(self.grid_layout.count())): 
            w = self.grid_layout.itemAt(i).widget()
            if w:
                w.setParent(None)

        self.grid_cards.clear()
        self.card_map.clear()
        self.browser_title.setText(f"📁 {os.path.basename(folder_path) or folder_path}")

        items_to_render = []
        if self.root_folder and os.path.abspath(folder_path) != os.path.abspath(self.root_folder):
            items_to_render.append(('up', "Back", os.path.dirname(folder_path)))

        try:
            entries = sorted(os.listdir(folder_path))
        except Exception:
            entries = []

        subfolders = []
        direct_files = []

        for entry in entries:
            full_path = os.path.join(folder_path, entry)
            if os.path.isdir(full_path):
                subfolders.append((entry, full_path))
            elif entry.lower().endswith(self.image_exts):
                direct_files.append(('image', entry, full_path))
            elif entry.lower().endswith(self.video_exts):
                direct_files.append(('video', entry, full_path))

        for name, path in subfolders:
            items_to_render.append(('folder', name, path))

        for item_type, name, path in direct_files:
            items_to_render.append((item_type, name, path))

        if not items_to_render:
            QMessageBox.information(self, "Empty Folder", "No media files or subfolders found.")
            self.return_to_dropzone()
            return

        cols = self.get_dynamic_cols()
        media_to_load = []

        for idx, (item_type, name, path) in enumerate(items_to_render):
            card = GalleryItemCard(item_type, name, path, self.on_card_clicked)
            row, col = idx // cols, idx % cols
            self.grid_layout.addWidget(card, row, col)
            self.grid_cards.append(card)

            if item_type in ('image', 'video'):
                self.card_map[path] = card
                media_to_load.append((path, item_type == 'video'))

        self.main_layout.setContentsMargins(0, 0, 0, 0)
        self.setStyleSheet("background-color: #121212;")
        self.browser_widget.show()
        self.showFullScreen()

        if self.grid_cards:
            self.grid_cards[0].setFocus()

        for m_path, is_vid in media_to_load:
            worker = ThumbnailWorker(m_path, is_video=is_vid)
            worker.signals.finished.connect(self.on_thumbnail_loaded)
            self.thread_pool.start(worker)

    def on_thumbnail_loaded(self, path, pixmap):
        if path in self.card_map:
            self.card_map[path].set_thumbnail(pixmap)

    def on_card_clicked(self, card):
        if card.item_type in ('folder', 'up'):
            self.render_directory(card.path)
        elif card.item_type in ('image', 'video'):
            self.media_paths = [
                c.path for c in self.grid_cards if c.item_type in ('image', 'video')
            ]
            if card.path in self.media_paths:
                self.current_index = self.media_paths.index(card.path)
            else:
                self.current_index = 0
            self.start_slideshow()

    def start_slideshow(self):
        self.browser_widget.hide()
        self.welcome_widget.hide()
        self.main_layout.setContentsMargins(0, 0, 0, 0)
        self.setStyleSheet("background-color: black;")
        self.showFullScreen()
        self.show_controls()
        self.show_current_media()

    def exit_slideshow_to_gallery(self):
        self.timer.stop()
        self.stop_video_pipeline()
        if self.current_folder and os.path.exists(self.current_folder):
            self.render_directory(self.current_folder)
        else:
            self.return_to_dropzone()

    def return_to_dropzone(self):
        self.timer.stop()
        self.stop_video_pipeline()
        self.thread_pool.clear()
        self.image_label.hide()
        self.video_widget.hide()
        self.controls_widget.hide()
        self.video_progress_bar.hide()
        self.browser_widget.hide()
        self.root_folder = None
        self.current_folder = None
        
        self.setStyleSheet("background-color: #121212;")
        self.main_layout.setContentsMargins(20, 20, 20, 20)
        self.showNormal()
        self.resize(700, 480)
        self.center_on_screen()
        self.welcome_widget.show()

    def stop_video_pipeline(self):
        if self.player.playbackState() != QMediaPlayer.PlaybackState.StoppedState:
            self.player.stop()
        self.player.setSource(QUrl())

    def format_time(self, ms):
        seconds = max(0, ms // 1000)
        m, s = divmod(seconds, 60)
        return f"{m}:{s:02d}"

    def on_video_position_changed(self, pos_ms):
        dur_ms = self.player.duration()
        if dur_ms > 0:
            val = int((pos_ms / dur_ms) * 1000)
            if not self.video_slider.isSliderDown():
                self.video_slider.setValue(val)
                self.lbl_video_time.setText(f"{self.format_time(pos_ms)} / {self.format_time(dur_ms)}")
            self.video_progress_bar.setValue(val)

    def on_video_duration_changed(self, dur_ms):
        pos_ms = self.player.position()
        self.lbl_video_time.setText(f"{self.format_time(pos_ms)} / {self.format_time(dur_ms)}")

    def user_seek_video(self, value):
        dur_ms = self.player.duration()
        if dur_ms > 0:
            target_ms = int((value / 1000.0) * dur_ms)
            self.player.setPosition(target_ms)

    def scrub_video(self, direction_factor):
        dur_ms = self.player.duration()
        if dur_ms <= 0:
            return

        now = time.time()
        time_since_last = now - self.last_scrub_time
        self.last_scrub_time = now

        if time_since_last < 0.4:
            self.scrub_ramp_step = min(5.0, self.scrub_ramp_step + 1.0)
        else:
            self.scrub_ramp_step = 1.0

        delta_ms = int(self.scrub_ramp_step * 1000) * direction_factor
        new_pos = max(0, min(dur_ms, self.player.position() + delta_ms))
        self.player.setPosition(new_pos)

    def show_current_media(self):
        if not self.media_paths:
            return

        path = self.media_paths[self.current_index]
        self.timer.stop()
        self.stop_video_pipeline()

        if path.lower().endswith(self.image_exts):
            self.video_widget.hide()
            self.video_progress_bar.hide()
            self.scrubber_container.hide()
            self.lbl_delay.show()
            self.speed_spinbox.show()
            self.image_label.show()
            try:
                pil_img = Image.open(path)
                pil_img = ImageOps.exif_transpose(pil_img).convert("RGBA")
                
                win_w, win_h = self.width(), self.height()
                pil_img.thumbnail((win_w, win_h), Image.Resampling.LANCZOS)

                qimg = QImage(pil_img.tobytes("raw", "RGBA"), pil_img.width, pil_img.height, QImage.Format.Format_RGBA8888)
                self.image_label.setPixmap(QPixmap.fromImage(qimg))
                self.start_timer()
            except Exception as e:
                print(f"Skipping {path}: {e}")
                self.next_media()

        elif path.lower().endswith(self.video_exts):
            self.image_label.hide()
            self.lbl_delay.hide()
            self.speed_spinbox.hide()
            self.scrubber_container.show()
            self.video_widget.show()
            
            self.player.setSource(QUrl.fromLocalFile(path))
            self.audio_output.setVolume(0.8)
            self.player.play()

        self.controls_widget.adjustSize()
        self.update_overlay_geometry()
        self.setFocus()
        self.activateWindow()

    def on_media_status_changed(self, status):
        if status == QMediaPlayer.MediaStatus.EndOfMedia:
            if not self.is_paused:
                self.next_media()

    def advance_slideshow(self):
        if not self.is_paused and self.media_paths:
            self.next_media()

    def start_timer(self):
        if not self.is_paused:
            self.timer.start(self.delay_ms)

    def next_media(self):
        if self.media_paths:
            self.current_index = (self.current_index + 1) % len(self.media_paths)
            self.show_current_media()

    def prev_media(self):
        if self.media_paths:
            self.current_index = (self.current_index - 1) % len(self.media_paths)
            self.show_current_media()

    def toggle_pause(self):
        self.is_paused = not self.is_paused
        self.btn_pause.setText("Play" if self.is_paused else "Pause")
        self.btn_pause.setStyleSheet(
            "color: white; background: #34a853; padding: 6px 14px; border-radius: 4px;" if self.is_paused 
            else "color: white; background: #1a73e8; padding: 6px 14px; border-radius: 4px;"
        )

        path = self.media_paths[self.current_index] if self.media_paths else ""
        if path.lower().endswith(self.video_exts):
            if self.is_paused:
                self.player.pause()
            else:
                self.player.play()
        else:
            if self.is_paused:
                self.timer.stop()
            else:
                self.start_timer()

    def update_delay_from_spinbox(self, val):
        self.delay_ms = val * 1000
        if not self.is_paused and self.image_label.isVisible():
            self.start_timer()

    def adjust_speed(self, delta):
        new_val = self.speed_spinbox.value() + delta
        if 1 <= new_val <= 60:
            self.speed_spinbox.setValue(new_val)

    def mouseMoveEvent(self, event):
        in_slideshow = self.isFullScreen() and (self.image_label.isVisible() or self.video_widget.isVisible())
        if in_slideshow:
            self.show_controls()
        super().mouseMoveEvent(event)

    def show_controls(self):
        self.update_overlay_geometry()
        self.controls_widget.show()
        self.controls_widget.raise_()

        current_path = self.media_paths[self.current_index] if self.media_paths else ""
        if current_path.lower().endswith(self.video_exts):
            self.video_progress_bar.show()
            self.video_progress_bar.raise_()

        self.hide_timer.start(3000)

    def hide_controls(self):
        in_slideshow = self.isFullScreen() and (self.image_label.isVisible() or self.video_widget.isVisible())
        if in_slideshow:
            self.controls_widget.hide()
            self.video_progress_bar.hide()

    def keyPressEvent(self, event):
        key = event.key()
        modifiers = event.modifiers()
        is_cmd = bool(modifiers & Qt.KeyboardModifier.ControlModifier) or bool(modifiers & Qt.KeyboardModifier.MetaModifier)

        # 1. Gallery View Grid Navigation
        if self.browser_widget.isVisible() and self.grid_cards:
            focused = self.focusWidget()
            if isinstance(focused, GalleryItemCard):
                idx = self.grid_cards.index(focused)
                cols = self.get_dynamic_cols()
                
                if key == Qt.Key.Key_Right and idx + 1 < len(self.grid_cards):
                    self.grid_cards[idx + 1].setFocus()
                    self.scroll_area.ensureWidgetVisible(self.grid_cards[idx + 1])
                elif key == Qt.Key.Key_Left and idx - 1 >= 0:
                    self.grid_cards[idx - 1].setFocus()
                    self.scroll_area.ensureWidgetVisible(self.grid_cards[idx - 1])
                elif key == Qt.Key.Key_Down and idx + cols < len(self.grid_cards):
                    self.grid_cards[idx + cols].setFocus()
                    self.scroll_area.ensureWidgetVisible(self.grid_cards[idx + cols])
                elif key == Qt.Key.Key_Up and idx - cols >= 0:
                    self.grid_cards[idx - cols].setFocus()
                    self.scroll_area.ensureWidgetVisible(self.grid_cards[idx - cols])
                elif key in (Qt.Key.Key_Backspace, Qt.Key.Key_Escape):
                    if self.root_folder and os.path.abspath(self.current_folder) != os.path.abspath(self.root_folder):
                        self.render_directory(os.path.dirname(self.current_folder))
                    else:
                        self.return_to_dropzone()
                return

        # 2. Presentation / Slideshow Mode Navigation
        in_slideshow = self.isFullScreen() and (self.image_label.isVisible() or self.video_widget.isVisible())
        if in_slideshow:
            if key in (Qt.Key.Key_Right, Qt.Key.Key_Left, Qt.Key.Key_Space, Qt.Key.Key_Up, Qt.Key.Key_Down):
                self.show_controls()

            current_path = self.media_paths[self.current_index] if self.media_paths else ""
            is_video = current_path.lower().endswith(self.video_exts)

            if key == Qt.Key.Key_Right:
                if is_video and is_cmd:
                    self.scrub_video(1)
                else:
                    self.next_media()
            elif key == Qt.Key.Key_Left:
                if is_video and is_cmd:
                    self.scrub_video(-1)
                else:
                    self.prev_media()
            elif key == Qt.Key.Key_Space:
                self.toggle_pause()
            elif key == Qt.Key.Key_Up:
                if not is_video:
                    self.adjust_speed(1)
            elif key == Qt.Key.Key_Down:
                if not is_video:
                    self.adjust_speed(-1)
            elif key in (Qt.Key.Key_Escape, Qt.Key.Key_Backspace):
                self.exit_slideshow_to_gallery()
            else:
                super().keyPressEvent(event)
        elif key == Qt.Key.Key_Escape:
            self.return_to_dropzone()
        else:
            super().keyPressEvent(event)


class ApplicationFilter(QApplication):
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
    window.show()
    sys.exit(app.exec())