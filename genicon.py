import sys
from PyQt6.QtWidgets import (
    QApplication, QGraphicsScene, QGraphicsTextItem, 
    QGraphicsDropShadowEffect, QGraphicsPathItem
)
from PyQt6.QtGui import (
    QFont, QColor, QPainter, QPixmap, QPainterPath, 
    QLinearGradient, QPen, QBrush
)
from PyQt6.QtCore import Qt, QRectF

def create_emoji_png(emoji_char="📷", output_path="app_icon.png"):
    QApplication.setHighDpiScaleFactorRoundingPolicy(
        Qt.HighDpiScaleFactorRoundingPolicy.PassThrough
    )
    
    app = QApplication(sys.argv)

    canvas_size = 1024
    scene = QGraphicsScene(0, 0, canvas_size, canvas_size)

    # 1. Background Squircle Path (Rounded Rect)
    tile_rect = QRectF(64, 64, 896, 896)
    path = QPainterPath()
    path.addRoundedRect(tile_rect, 200, 200)

    # Gradient Fill: Midnight blue to deep slate
    gradient = QLinearGradient(64, 64, 960, 960)
    gradient.setColorAt(0.0, QColor("#1e2638"))
    gradient.setColorAt(0.5, QColor("#11141d"))
    gradient.setColorAt(1.0, QColor("#0a0c10"))

    # Border: Semi-translucent white metallic accent
    pen = QPen(QColor(255, 255, 255, 36), 12)

    bg_item = QGraphicsPathItem(path)
    bg_item.setBrush(QBrush(gradient))
    bg_item.setPen(pen)
    scene.addItem(bg_item)

    # 2. Add Emoji (Backed down to standard macOS proportions)
    item = QGraphicsTextItem(emoji_char)
    font = QFont("Apple Color Emoji")
    font.setPixelSize(540) 
    font.setStyleStrategy(QFont.StyleStrategy.PreferAntialias)
    item.setFont(font)

    # Center origin and tilt
    bounds = item.boundingRect()
    item.setTransformOriginPoint(bounds.width() / 2, bounds.height() / 2)
    item.setPos(
        (canvas_size - bounds.width()) / 2,
        (canvas_size - bounds.height()) / 2
    )
    item.setRotation(-14)

    # 3. Drop Shadow (Tightened for the smaller size)
    shadow = QGraphicsDropShadowEffect()
    shadow.setBlurRadius(60)
    shadow.setColor(QColor(0, 0, 0, 180))
    shadow.setOffset(0, 20)
    item.setGraphicsEffect(shadow)

    scene.addItem(item)

    # 4. Render Super-Sampled Retina Canvas
    retina_pixmap = QPixmap(canvas_size * 2, canvas_size * 2)
    retina_pixmap.setDevicePixelRatio(2.0)
    retina_pixmap.fill(Qt.GlobalColor.transparent)

    painter = QPainter(retina_pixmap)
    painter.setRenderHints(
        QPainter.RenderHint.Antialiasing | 
        QPainter.RenderHint.TextAntialiasing | 
        QPainter.RenderHint.SmoothPixmapTransform
    )

    target_rect = QRectF(0, 0, canvas_size, canvas_size)
    source_rect = QRectF(0, 0, canvas_size, canvas_size)
    scene.render(painter, target_rect, source_rect)
    
    painter.end()

    # Save to PNG
    final_img = retina_pixmap.toImage()
    final_img.save(output_path, "PNG")
    print(f"Saved perfectly proportioned high-res icon to {output_path}!")

if __name__ == "__main__":
    create_emoji_png("📷")