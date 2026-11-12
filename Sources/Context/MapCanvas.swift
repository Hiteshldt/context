import SwiftUI
import AppKit

/// Where the map is scrolled and how far it's zoomed.
///
/// The map scrolls in a native scroll view (smooth two-finger panning), but zooming is done by SwiftUI, scaling the
/// map inside it. The scroll view's own magnification isn't used: SwiftUI doesn't account for it when it works out
/// where a click landed, so at any zoom other than 100% clicks and drags hit the wrong place.
@MainActor
final class MapViewport: ObservableObject {
    static let minZoom: CGFloat = 0.25
    static let maxZoom: CGFloat = 2

    @Published private(set) var zoom: CGFloat = 1
    fileprivate weak var scrollView: NSScrollView?
    fileprivate var canvasSize = DiagramLayout.canvas
    private var panAnchor: NSPoint?

    var window: NSWindow? { scrollView?.window }

    /// The part of the map on screen, in map coordinates.
    var visibleRect: CGRect {
        guard let scrollView else { return CGRect(origin: .zero, size: CGSize(width: 1200, height: 800)) }
        let shown = scrollView.contentView.bounds
        return CGRect(x: shown.minX / zoom, y: shown.minY / zoom, width: shown.width / zoom, height: shown.height / zoom)
    }
    var visibleCenter: CGPoint { CGPoint(x: visibleRect.midX, y: visibleRect.midY) }

    /// Zooms, keeping `point` (map coordinates; the middle of the screen by default) where it is on screen.
    func setZoom(_ value: CGFloat, around point: CGPoint? = nil) {
        guard let scrollView, let document = scrollView.documentView else { zoom = value; return }
        let clamped = min(max(value, Self.minZoom), Self.maxZoom)
        let anchor = point ?? visibleCenter
        let origin = scrollView.contentView.bounds.origin
        let onScreen = CGPoint(x: anchor.x * zoom - origin.x, y: anchor.y * zoom - origin.y)
        zoom = clamped
        document.setFrameSize(CGSize(width: canvasSize.width * clamped, height: canvasSize.height * clamped))
        scroll(to: CGPoint(x: anchor.x * clamped - onScreen.x, y: anchor.y * clamped - onScreen.y))
    }

    func zoomIn() { setZoom(zoom * 1.25) }
    func zoomOut() { setZoom(zoom / 1.25) }

    /// Room kept clear when fitting the map: the toolbar floats over the top and the hint over the bottom.
    static let fitInsets = (top: 64.0, bottom: 44.0)

    /// Shows `rect` (map coordinates) as large as fits between the toolbar and the hint, never above 100%.
    func fit(_ rect: CGRect) {
        guard let scrollView, scrollView.bounds.width > 0 else { return }
        let padded = rect.insetBy(dx: -40, dy: -30)
        let height = max(100, scrollView.bounds.height - Self.fitInsets.top - Self.fitInsets.bottom)
        setZoom(min(scrollView.bounds.width / padded.width, height / padded.height, 1))
        // Centre the map in the clear area rather than the whole view.
        scroll(to: CGPoint(x: padded.midX * zoom - scrollView.contentView.bounds.width / 2,
                           y: padded.midY * zoom - (Self.fitInsets.top + height / 2)))
    }

    func center(on point: CGPoint) {
        guard let scrollView else { return }
        let size = scrollView.contentView.bounds.size
        scroll(to: CGPoint(x: point.x * zoom - size.width / 2, y: point.y * zoom - size.height / 2))
    }

    /// Drag-to-pan: call with the pointer's screen position while a drag on empty space goes on.
    func pan(to screenPoint: NSPoint) {
        defer { panAnchor = screenPoint }
        guard let scrollView, let anchor = panAnchor else { NSCursor.closedHand.set(); return }
        let origin = scrollView.contentView.bounds.origin
        // The map is flipped (y grows downwards) while screen coordinates grow upwards.
        scroll(to: CGPoint(x: origin.x - (screenPoint.x - anchor.x), y: origin.y + (screenPoint.y - anchor.y)))
    }

    func endPan() {
        panAnchor = nil
        NSCursor.arrow.set()
    }

    private func scroll(to origin: CGPoint) {
        guard let scrollView, let document = scrollView.documentView else { return }
        let size = scrollView.contentView.bounds.size
        let insets = scrollView.contentInsets
        let clamped = CGPoint(x: min(max(0, origin.x), max(0, document.frame.width - size.width)),
                              y: min(max(-insets.top, origin.y), max(-insets.top, document.frame.height - size.height + insets.bottom)))
        scrollView.contentView.scroll(to: clamped)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Map coordinates of a point in the window.
    fileprivate func mapPoint(_ windowPoint: NSPoint) -> CGPoint? {
        guard let document = scrollView?.documentView else { return nil }
        let point = document.convert(windowPoint, from: nil)
        return CGPoint(x: point.x / zoom, y: point.y / zoom)
    }

    fileprivate func attach(_ scrollView: NSScrollView) {
        self.scrollView = scrollView
    }
}

/// Hosts the SwiftUI map inside a native `NSScrollView`.
struct MapScrollView<Content: View>: NSViewRepresentable {
    let viewport: MapViewport
    let size: CGSize
    /// Runs once the scroll view has its size, e.g. to fit the map on screen.
    let onReady: () -> Void
    @ViewBuilder let content: Content

    func makeNSView(context: NSViewRepresentableContext<MapScrollView>) -> MapNSScrollView {
        let scroll = MapNSScrollView()
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.allowsMagnification = false
        scroll.usesPredominantAxisScrolling = false
        // Room to scroll the map's edges clear of the toolbar floating over the top and the hint over the bottom.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: MapViewport.fitInsets.top, left: 0, bottom: MapViewport.fitInsets.bottom, right: 0)

        viewport.canvasSize = size
        let document = FlippedView(frame: CGRect(origin: .zero, size: CGSize(width: size.width * viewport.zoom, height: size.height * viewport.zoom)))
        let host = NSHostingView(rootView: AnyView(ZoomedMap(viewport: viewport, size: size, content: content)))
        host.sizingOptions = []
        host.frame = document.bounds
        host.autoresizingMask = [.width, .height]
        document.addSubview(host)
        scroll.documentView = document
        context.coordinator.host = host

        scroll.viewport = viewport
        scroll.onFirstLayout = onReady
        viewport.attach(scroll)
        return scroll
    }

    func updateNSView(_ scroll: MapNSScrollView, context: NSViewRepresentableContext<MapScrollView>) {
        context.coordinator.host?.rootView = AnyView(ZoomedMap(viewport: viewport, size: size, content: content))
        if viewport.scrollView !== scroll { viewport.attach(scroll); scroll.viewport = viewport }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var host: NSHostingView<AnyView>?
    }
}

/// The map at the current zoom. SwiftUI's own scaling keeps clicks and drags lined up with what's drawn.
private struct ZoomedMap<Content: View>: View {
    @ObservedObject var viewport: MapViewport
    let size: CGSize
    let content: Content

    var body: some View {
        content
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .scaleEffect(viewport.zoom, anchor: .topLeading)
            .frame(width: size.width * viewport.zoom, height: size.height * viewport.zoom, alignment: .topLeading)
    }
}

final class MapNSScrollView: NSScrollView {
    var onFirstLayout: (() -> Void)?
    weak var viewport: MapViewport?

    override func layout() {
        super.layout()
        if bounds.width > 0, let action = onFirstLayout {
            onFirstLayout = nil
            DispatchQueue.main.async(execute: action)
        }
    }

    /// Trackpad pinch zooms around the pointer.
    override func magnify(with event: NSEvent) {
        MainActor.assumeIsolated {
            guard let viewport else { return }
            viewport.setZoom(viewport.zoom * (1 + event.magnification), around: viewport.mapPoint(event.locationInWindow))
        }
    }

    /// A two-finger double-tap switches between 100% and the whole map, like Safari's smart zoom.
    override func smartMagnify(with event: NSEvent) {
        MainActor.assumeIsolated {
            guard let viewport else { return }
            if abs(viewport.zoom - 1) > 0.01 { viewport.setZoom(1, around: viewport.mapPoint(event.locationInWindow)) }
            else { NotificationCenter.default.post(name: .contextFitMap, object: nil) }
        }
    }

    /// ⌘-scroll zooms around the pointer, for mice without pinch.
    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else { super.scrollWheel(with: event); return }
        MainActor.assumeIsolated {
            guard let viewport else { return }
            let factor = exp(event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.08))
            viewport.setZoom(viewport.zoom * factor, around: viewport.mapPoint(event.locationInWindow))
        }
    }
}

extension Notification.Name {
    /// Fit the map on screen (from a two-finger double-tap).
    static let contextFitMap = Notification.Name("ContextFitMap")
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
