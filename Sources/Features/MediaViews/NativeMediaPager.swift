import SwiftUI
import UIKit

// Adapted from LifeDrive's MediaGalleryPager and ZoomingImageView in FilesView.swift.
// UIKit owns gesture arbitration: fitted images yield drags to the pager, while
// zoomed images keep them for panning within the photograph.
struct NativeMediaPager<Page: View>: UIViewControllerRepresentable {
    let count: Int
    @Binding var index: Int
    let animateSelection: Bool
    let isVideo: (Int) -> Bool
    @ViewBuilder let content: (Int) -> Page

    func makeUIViewController(context: Context) -> NativeMediaPagingController<Page> {
        NativeMediaPagingController(count: count, index: index, content: content)
    }

    func updateUIViewController(_ controller: NativeMediaPagingController<Page>, context: Context) {
        controller.selected = { index = $0 }
        controller.isVideo = isVideo
        controller.content = content
        withTransaction(context.transaction) {
            controller.show(index, animated: animateSelection && !UIAccessibility.isReduceMotionEnabled)
            controller.refreshPages()
        }
    }
}

/// Retain only the selected page and its neighbours, as in LifeDrive. The media
/// browser still owns selection, loading, video playback and vertical navigation.
final class NativeMediaPagingController<Page: View>: UIViewController, UIScrollViewDelegate {
    private let count: Int
    private let paging = BrowserPagingScrollView()
    private let pageControl = UIPageControl()
    private var pages: [Int: UIHostingController<Page>] = [:]
    private var current: Int
    private var destination: Int
    private var pageSize: CGSize = .zero
    var content: (Int) -> Page
    var selected: (Int) -> Void = { _ in }
    var isVideo: (Int) -> Bool = { _ in false }

    init(count: Int, index: Int, content: @escaping (Int) -> Page) {
        self.count = count
        current = index
        destination = index
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        paging.backgroundColor = .clear
        paging.delegate = self
        paging.isPagingEnabled = true
        paging.showsHorizontalScrollIndicator = false
        paging.showsVerticalScrollIndicator = false
        paging.contentInsetAdjustmentBehavior = .never
        paging.panGestureRecognizer.maximumNumberOfTouches = 1
        paging.canBeginPaging = { [weak self] point in
            guard let self, self.count > 1 else { return false }
            if self.isVideo(self.current) {
                return point.y > self.view.safeAreaInsets.top + 64
                    && point.y < self.paging.bounds.height - self.view.safeAreaInsets.bottom - 100
            }
            return true
        }
        view.addSubview(paging)
        pageControl.numberOfPages = count
        pageControl.currentPage = current
        pageControl.hidesForSinglePage = true
        pageControl.backgroundStyle = .prominent
        pageControl.addTarget(self, action: #selector(selectPage), for: .valueChanged)
        view.addSubview(pageControl)
        retainPages(around: current)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let resized = pageSize != view.bounds.size
        paging.frame = view.bounds
        pageSize = view.bounds.size
        paging.contentSize = CGSize(width: pageSize.width * CGFloat(count), height: pageSize.height)
        layoutPages()
        let controlSize = pageControl.sizeThatFits(pageSize)
        pageControl.frame = CGRect(
            x: (pageSize.width - controlSize.width) / 2,
            y: pageSize.height - view.safeAreaInsets.bottom - controlSize.height - 8,
            width: controlSize.width, height: controlSize.height
        )
        if resized {
            paging.setContentOffset(CGPoint(x: CGFloat(current) * pageSize.width, y: 0), animated: false)
            destination = current
            pageControl.isEnabled = true
        }
    }

    func show(_ index: Int, animated: Bool) {
        guard (0..<count).contains(index), index != destination else { return }
        // Vertical auto-advance must take effect immediately, even during a flick.
        if animated && (paging.isDragging || paging.isDecelerating || destination != current) { return }
        destination = index
        retainPages(around: index, retaining: current)
        if !animated || pageSize.width == 0 {
            current = index
            pageControl.currentPage = index
            retainPages(around: index)
        }
        pageControl.isEnabled = !animated || pageSize.width == 0
        paging.setContentOffset(CGPoint(x: CGFloat(index) * pageSize.width, y: 0), animated: animated && pageSize.width > 0)
    }

    func refreshPages() {
        for (index, page) in pages { page.rootView = content(index) }
    }

    private func retainPages(around index: Int, retaining origin: Int? = nil) {
        guard count > 0 else { return }
        var wanted = Set(max(0, index - 1)...min(count - 1, index + 1))
        if let origin { wanted.insert(origin) }
        for key in Array(pages.keys) where !wanted.contains(key) {
            let page = pages.removeValue(forKey: key)!
            page.willMove(toParent: nil)
            page.view.removeFromSuperview()
            page.removeFromParent()
        }
        for key in wanted where pages[key] == nil {
            let page = UIHostingController(rootView: content(key))
            page.safeAreaRegions = []
            page.view.backgroundColor = .clear
            addChild(page)
            paging.addSubview(page.view)
            page.didMove(toParent: self)
            pages[key] = page
        }
        layoutPages()
    }

    private func layoutPages() {
        for (index, page) in pages {
            page.view.frame = CGRect(x: CGFloat(index) * pageSize.width, y: 0, width: pageSize.width, height: pageSize.height)
        }
    }

    @objc private func selectPage() { selected(pageControl.currentPage) }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        destination = current
        pageControl.isEnabled = false
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard pageSize.width > 0, count > 0 else { return }
        let proposed = Int((targetContentOffset.pointee.x / pageSize.width).rounded())
        let target = min(min(count - 1, current + 1), max(max(0, current - 1), proposed))
        targetContentOffset.pointee.x = CGFloat(target) * pageSize.width
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settled() }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { settled() }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { settled() }
    }

    private func settled() {
        guard pageSize.width > 0, count > 0 else { return }
        current = min(count - 1, max(0, Int((paging.contentOffset.x / pageSize.width).rounded())))
        destination = current
        pageControl.currentPage = current
        pageControl.isEnabled = true
        retainPages(around: current)
        selected(current)
    }
}

private final class BrowserPagingScrollView: UIScrollView {
    var canBeginPaging: (CGPoint) -> Bool = { _ in true }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === panGestureRecognizer else { return super.gestureRecognizerShouldBegin(gestureRecognizer) }
        let velocity = panGestureRecognizer.velocity(in: self)
        let point = panGestureRecognizer.location(in: self)
        guard abs(velocity.x) > abs(velocity.y), canBeginPaging(CGPoint(x: point.x - bounds.minX, y: point.y)) else { return false }
        var target = hitTest(point, with: nil)
        while let current = target, current !== self {
            if current is UIControl { return false }
            if let image = current as? BrowserZoomingImageView, image.zoomScale > image.minimumZoomScale + 0.001 { return false }
            target = current.superview
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}

struct BrowserZoomableImage: UIViewRepresentable {
    let image: UIImage?
    let onZoomChange: (Bool) -> Void
    let onTap: () -> Void
    let onLongPress: () -> Void

    func makeUIView(context: Context) -> BrowserZoomingImageView {
        BrowserZoomingImageView(image: image)
    }

    func updateUIView(_ view: BrowserZoomingImageView, context: Context) {
        // Layout can reset zoom after rotation or an image-size change. Publish
        // outside the SwiftUI update that triggered that layout.
        view.onZoomChange = { zoomed in
            DispatchQueue.main.async { onZoomChange(zoomed) }
        }
        view.onTap = onTap
        view.onLongPress = onLongPress
        if view.image !== image { view.image = image }
    }
}

final class BrowserZoomingImageView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private var fitted: CGSize = .zero
    var onZoomChange: (Bool) -> Void = { _ in }
    var onTap: () -> Void = {}
    var onLongPress: () -> Void = {}

    var image: UIImage? {
        get { imageView.image }
        set { imageView.image = newValue; setNeedsLayout() }
    }

    init(image: UIImage?) {
        super.init(frame: .zero)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 6
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        backgroundColor = .clear
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(revealControls))
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(saveImage(_:)))
        addGestureRecognizer(longPress)
        self.image = image
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // At fitted size the outer pager owns dragging. Pinch and double-tap
        // remain native; once zoomed, this scroll view owns panning instead.
        if gestureRecognizer === panGestureRecognizer && zoomScale <= minimumZoomScale + 0.001 { return false }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let size = image?.size, size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        // A picture of the same shape takes the old one's place at the current
        // zoom; a different shape, or a rotation, starts over at the whole picture.
        if abs(target.width - fitted.width) > 0.5 || abs(target.height - fitted.height) > 0.5 {
            zoomScale = 1
            fitted = target
            imageView.frame = CGRect(origin: .zero, size: target)
            contentSize = target
        }
        centerContent()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
        onZoomChange(zoomScale > minimumZoomScale + 0.001)
    }

    @objc private func revealControls() { onTap() }

    @objc private func saveImage(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began { onLongPress() }
    }

    /// Keeps a picture smaller than the screen in the middle of it.
    private func centerContent() {
        let horizontal = max(0, (bounds.width - contentSize.width) / 2)
        let vertical = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }

    /// Zooms in on the tapped point, or back out to the whole picture.
    @objc private func toggleZoom(_ gesture: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        let point = gesture.location(in: imageView)
        let scale: CGFloat = 2.5
        let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
        zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
    }
}
