import SwiftUI
import AppKit

/// Where the map is scrolled and how far it's zoomed. Backed by a native scroll view, so trackpad pinch zooms
/// around the pointer and two-finger scrolling pans, exactly like other Mac apps.
@MainActor
final class MapViewport: ObservableObject {
    static let minZoom: CGFloat = 0.25
    static let maxZoom: CGFloat = 2

    @Published private(set) var zoom: CGFloat = 1
    fileprivate weak var scrollView: NSScrollView?
    private var panAnchor: NSPoint?

    var window: NSWindow? { scrollView?.window }

    /// The part of the map on screen, in map coordinates.
    var visibleRect: CGRect { scrollView?.documentVisibleRect ?? CGRect(origin: .zero, size: CGSize(width: 1200, height: 800)) }
    var visibleCenter: CGPoint { CGPoint(x: visibleRect.midX, y: visibleRect.midY) }

    func setZoom(_ value: CGFloat, around point: CGPoint? = nil) {
        guard let scrollView else { return }
        scrollView.setMagnification(min(max(value, Self.minZoom), Self.maxZoom), centeredAt: point ?? visibleCenter)
        zoom = scrollView.magnification
    }

    func zoomIn() { setZoom(zoom * 1.25) }
    func zoomOut() { setZoom(zoom / 1.25) }

    /// Shows `rect` (map coordinates) as large as fits, never above 100%.
    func fit(_ rect: CGRect) {
        guard let scrollView, scrollView.bounds.width > 0 else { return }
        let padded = rect.insetBy(dx: -70, dy: -70)
        let scale = min(scrollView.bounds.width / padded.width, scrollView.bounds.height / padded.height, 1)
        scrollView.magnification = min(max(scale, Self.minZoom), Self.maxZoom)
        center(on: CGPoint(x: padded.midX, y: padded.midY))
        zoom = scrollView.magnification
    }

    func center(on point: CGPoint) {
        guard let scrollView else { return }
        let size = scrollView.contentView.bounds.size
        scroll(to: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2))
    }

    /// Drag-to-pan: call with the pointer's screen position while a drag on empty space goes on.
    func pan(to screenPoint: NSPoint) {
        defer { panAnchor = screenPoint }
        guard let scrollView, let anchor = panAnchor else { NSCursor.closedHand.set(); return }
        let origin = scrollView.contentView.bounds.origin
        // The map is flipped (y grows downwards) while screen coordinates grow upwards.
        scroll(to: CGPoint(x: origin.x - (screenPoint.x - anchor.x) / scrollView.magnification,
                           y: origin.y + (screenPoint.y - anchor.y) / scrollView.magnification))
    }

    func endPan() {
        panAnchor = nil
        NSCursor.arrow.set()
    }

    private func scroll(to origin: CGPoint) {
        guard let scrollView, let document = scrollView.documentView else { return }
        let size = scrollView.contentView.bounds.size
        let clamped = CGPoint(x: min(max(0, origin.x), max(0, document.frame.width - size.width)),
                              y: min(max(0, origin.y), max(0, document.frame.height - size.height)))
        scrollView.contentView.scroll(to: clamped)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    fileprivate func attach(_ scrollView: NSScrollView) {
        self.scrollView = scrollView
        zoom = scrollView.magnification
    }

    fileprivate func magnificationChanged() {
        if let scrollView { zoom = scrollView.magnification }
    }
}

/// Hosts the SwiftUI map inside a magnifiable `NSScrollView`.
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
        scroll.allowsMagnification = true
        scroll.minMagnification = MapViewport.minZoom
        scroll.maxMagnification = MapViewport.maxZoom
        scroll.usesPredominantAxisScrolling = false

        let document = FlippedView(frame: CGRect(origin: .zero, size: size))
        let host = NSHostingView(rootView: AnyView(content))
        host.sizingOptions = []
        host.frame = document.bounds
        host.autoresizingMask = [.width, .height]
        document.addSubview(host)
        scroll.documentView = document
        context.coordinator.host = host

        scroll.onFirstLayout = onReady
        scroll.onZoom = { [weak viewport] in viewport?.magnificationChanged() }
        context.coordinator.observer = NotificationCenter.default.addObserver(forName: NSScrollView.didEndLiveMagnifyNotification, object: scroll, queue: .main) { [weak viewport] _ in
            MainActor.assumeIsolated { viewport?.magnificationChanged() }
        }
        viewport.attach(scroll)
        return scroll
    }

    func updateNSView(_ scroll: MapNSScrollView, context: NSViewRepresentableContext<MapScrollView>) {
        context.coordinator.host?.rootView = AnyView(content)
        if viewport.scrollView !== scroll { viewport.attach(scroll) }
    }

    static func dismantleNSView(_ scroll: MapNSScrollView, coordinator: Coordinator) {
        if let observer = coordinator.observer { NotificationCenter.default.removeObserver(observer) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var host: NSHostingView<AnyView>?
        var observer: NSObjectProtocol?
    }
}

final class MapNSScrollView: NSScrollView {
    var onFirstLayout: (() -> Void)?
    var onZoom: (() -> Void)?

    override func layout() {
        super.layout()
        if bounds.width > 0, let action = onFirstLayout {
            onFirstLayout = nil
            DispatchQueue.main.async(execute: action)
        }
    }

    /// ⌘-scroll zooms around the pointer, for mice without pinch.
    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command), let document = documentView else { super.scrollWheel(with: event); return }
        let point = document.convert(event.locationInWindow, from: nil)
        let factor = exp(event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.08))
        setMagnification(min(max(magnification * factor, minMagnification), maxMagnification), centeredAt: point)
        onZoom?()
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
