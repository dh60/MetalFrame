import SwiftUI
import Observation
import Metal
import MetalKit
import MetalFX
import AVFoundation
import CoreVideo
import CoreMedia
import UniformTypeIdentifiers
import simd

extension Notification.Name {
    static let openFileRequested = Notification.Name("MetalFrame.openFileRequested")
}

@main
struct MetalFrame: App {
    var body: some Scene {
        Window("MetalFrame", id: "main") {
            MetalView()
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") {
                    NotificationCenter.default.post(name: .openFileRequested, object: nil)
                }
                .keyboardShortcut("o")
            }
        }
    }
}

struct MetalView: View {
    @State private var renderer = Renderer()
    @State private var mouseHideTimer: Timer?
    @State private var showProgressBar = false
    @State private var showStatusOverlay = false
    @State private var statusTimer: Timer?
    @State private var isImporting = false
    @State private var didReceiveURL = false

    func flashStatusOverlay() {
        withAnimation { showStatusOverlay = true }
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in
            withAnimation { showStatusOverlay = false }
        }
    }

    var body: some View {
        @Bindable var renderer = renderer
        ZStack(alignment: .topLeading) {
            MetalViewRepresentable(renderer: renderer)
            if renderer.duration > 0 {
                VStack {
                    Spacer()
                    ProgressBar(currentTime: $renderer.currentTime, duration: renderer.duration, onSeek: { time in
                        renderer.seek(to: time)
                    }, isVisible: $showProgressBar)
                    .frame(height: 20)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
                }
            }
            if showStatusOverlay {
                Text(renderer.statusLabel)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(in: .capsule)
                    .padding()
                    .transition(.blurReplace)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if renderer.selectedSubtitleIndex >= 0 && !renderer.subtitleText.isEmpty {
                VStack {
                    Spacer()
                    Text(renderer.subtitleText)
                        .font(.system(size: 36, weight: .medium, design: .serif))
                        .tracking(1.2)
                        .foregroundStyle(.white)
                        .shadow(color: .black, radius: 0, x: 1.5, y: 1.5)
                        .shadow(color: .black, radius: 1, x: 0, y: 0)
                        .shadow(color: .black.opacity(0.4), radius: 3, x: 0, y: 1)
                        .padding(.horizontal, 40)
                        .padding(.bottom, 60)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
            }
            if renderer.showInfo {
                VStack(alignment: .leading) {
                    Text(renderer.info)
                    Picker("Scale", selection: $renderer.scaleMode) {
                        ForEach(ScaleMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .padding()
                .glassEffect(in: .rect(cornerRadius: 30))
                .padding()
            }
            if let error = renderer.errorMessage {
                VStack {
                    Text(error)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .glassEffect(in: .rect(cornerRadius: 14))
                        .onTapGesture { renderer.errorMessage = nil }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.blurReplace)
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active:
                NSCursor.unhide()
                showProgressBar = true
                mouseHideTimer?.invalidate()
                mouseHideTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in
                    NSCursor.hide()
                    showProgressBar = false
                }
            case .ended:
                mouseHideTimer?.invalidate()
                NSCursor.unhide()
                showProgressBar = false
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            // .movie covers registered formats; MKV only conforms to public.movie
            // when some installed app declares it, so also pass our imported UTI
            // (declared in Info.plist) to keep .mkv selectable on clean systems.
            allowedContentTypes: [.movie] + (UTType("org.matroska.mkv").map { [$0] } ?? []),
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first, let view = renderer.view else { return }
                renderer.setupVideo(url: url, view: view)
            case .failure(let error):
                renderer.errorMessage = "Open failed: \(error.localizedDescription)"
            }
        }
        .onOpenURL { url in
            didReceiveURL = true
            isImporting = false
            guard let view = renderer.view else { return }
            renderer.setupVideo(url: url, view: view)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openFileRequested)) { _ in
            isImporting = true
        }
        .task {
            // Give onOpenURL (Finder double-click / `open` from Terminal) a chance
            // to fire before falling back to the file picker. Without this delay
            // the picker would briefly appear and then dismiss when the URL arrives.
            try? await Task.sleep(for: .milliseconds(200))
            if !didReceiveURL { isImporting = true }
        }
        .focusable()
        .focusEffectDisabled()
        .onMoveCommand { direction in
            switch direction {
            case .left, .up: renderer.seek(by: -10)
            case .right, .down: renderer.seek(by: 10)
            default: break
            }
        }
        .onKeyPress(.space) { renderer.togglePlayback(); return .handled }
        .onExitCommand { NSApplication.shared.terminate(nil) }
        .onKeyPress("i") { renderer.showInfo.toggle(); return .handled }
        .onKeyPress("s") {
            renderer.cycleSubtitles()
            flashStatusOverlay()
            return .handled
        }
        .onKeyPress("a") {
            renderer.cycleAudio()
            flashStatusOverlay()
            return .handled
        }
        // Engine-initiated status messages (audio fallback notes, track
        // switches it performs on its own) flash the same overlay the
        // keyboard shortcuts use.
        .onChange(of: renderer.statusLabel) {
            if !renderer.statusLabel.isEmpty { flashStatusOverlay() }
        }
        .onKeyPress("f") { NSApplication.shared.keyWindow?.toggleFullScreen(nil); return .handled }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            // Native fullscreen already hides the menu bar / Dock via auto-hide, which
            // reveals them on mouse-to-edge. Force the hide so we get a closer-to-
            // exclusive feel — nothing about the OS chrome can come back without an
            // explicit toggle out of fullscreen.
            NSApp.presentationOptions = [.fullScreen, .hideMenuBar, .hideDock]
            NSApp.activate(ignoringOtherApps: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { _ in
            NSApp.presentationOptions = []
        }
    }
}

struct ProgressBar: View {
    @Binding var currentTime: Double
    let duration: Double
    let onSeek: (Double) -> Void
    @Binding var isVisible: Bool
    @State private var isDragging = false
    @State private var dragTime: Double = 0

    func formatTime(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = Int(seconds) / 60 % 60
        let secs = Int(seconds) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%d:%02d", minutes, secs)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Color.clear
                    .frame(width: geometry.size.width)
                    .glassEffect()
                    .opacity(isVisible ? 1 : 0)

                Color.clear
                    .frame(width: geometry.size.width * CGFloat((isDragging ? dragTime : currentTime) / duration))
                    .glassEffect(.regular.tint(.purple.opacity(0.1)))
                    .opacity(isVisible ? 1 : 0)

                if isVisible {
                    HStack {
                        Text(formatTime(isDragging ? dragTime : currentTime))
                        Spacer()
                        Text(formatTime(duration))
                    }
                    .padding(.horizontal, 8)
                }

                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        dragTime = max(0, min(duration, Double(value.location.x / geometry.size.width) * duration))
                    }
                    .onEnded { value in
                        isDragging = false
                        let newTime = max(0, min(duration, Double(value.location.x / geometry.size.width) * duration))
                        onSeek(newTime)
                    }
            )
        }
    }
}

struct MetalViewRepresentable: NSViewRepresentable {
    let renderer: Renderer

    func makeCoordinator() -> Renderer { renderer }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = .rgba16Float
        view.delegate = context.coordinator
        // Drive draws ourselves from a NSScreen-bound CADisplayLink so we can use
        // its targetTimestamp for both AVPlayerItemVideoOutput.itemTime(forHostTime:)
        // and CAMetalDrawable.present(atTime:) — vsync-aligned frame pull and
        // presentation. MTKView's built-in display loop only exposes a coarse
        // preferredFramesPerSecond knob.
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        context.coordinator.view = view

        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}
}

enum ScaleMode: String, CaseIterable {
    case off = "Off"
    case fit = "Fit"
    case fill = "Fill"
}

// Identifies the EOTF / OETF the source content is encoded with — used by the
// EWA shader to round-trip through linear light. PQ and HLG share the file's
// `linear` branch (no conversion) only when content is already pre-linearized,
// which AVFoundation does NOT do unless `AVVideoTransferFunction_Linear` is
// explicitly requested, so HDR sources land on `.pq` or `.hlg`.
enum TransferFunction: Int32 {
    case linear = 0
    case sRGB = 1
    case pq = 2
    case hlg = 3
}

@Observable
class Renderer: NSObject, MTKViewDelegate, AVPlayerItemLegibleOutputPushDelegate {
    var device: MTLDevice!
    var queue: MTL4CommandQueue!
    var renderPipelineIntake: MTLRenderPipelineState?
    var renderPipelineBilinear: MTLRenderPipelineState?
    var renderPipelineEWA: MTLRenderPipelineState?
    var allocator: MTL4CommandAllocator!
    var argumentTable: MTL4ArgumentTable!
    var residencySet: MTLResidencySet!
    var uniformsBuffer: MTLBuffer!
    var intakeUniformsBuffer: MTLBuffer!
    var compiler: MTL4Compiler!
    var scaler: (MTL4FXSpatialScaler, MTLTexture)?
    var intakeFence: MTLFence!
    var kernelLUT: MTLTexture!
    var transferFunction: TransferFunction = .sRGB
    var isHDR: Bool = false
    var ycbcrMatrix: simd_float3x3 = matrix_identity_float3x3
    // Display-side orientation derived from the source track's preferredTransform.
    // rotationQuadrant ∈ {0, 1, 2, 3} = {0°, 90° CW, 180°, 270° CW}. rotation maps
    // display-space texCoord (centered at 0.5) back into source space, so the
    // intake pass samples the unrotated source planes while writing a display-
    // oriented intermediate. displayAspect bakes in both rotation and pixel
    // aspect ratio for the final fit/fill quad; 0 = not yet known (track metadata
    // loads async), in which case draw() falls back to the texture's own aspect.
    var rotationQuadrant: Int = 0
    var rotation: simd_float2x2 = matrix_identity_float2x2
    var displayAspect: CGFloat = 0
    var commandBuffer: MTL4CommandBuffer!
    var frameEvent: MTLSharedEvent!
    var pendingFrameValue: UInt64 = 0
    var player: AVPlayer?
    var playerItem: AVPlayerItem?
    var videoOutput: AVPlayerItemVideoOutput?
    var textureCache: CVMetalTextureCache!
    var yTexture: MTLTexture?
    var cbcrTexture: MTLTexture?
    var linearTexture: MTLTexture?
    var lastPixelFormat: OSType = 0
    // Cached strong refs to the CVMetalTextures backing yTexture / cbcrTexture for
    // the current frame — if these go out of scope, the MTLTextures stop being
    // valid views into the underlying IOSurface.
    var ySource: CVMetalTexture?
    var cbcrSource: CVMetalTexture?
    weak var view: MTKView?
    var activity: NSObjectProtocol?
    // Native playback engine — owns demux/decode for MKV. When non-nil it is
    // the frame producer; otherwise the AVPlayer path (MP4/MOV) is.
    var engine: PlaybackEngine?
    var currentSetupTask: Task<Void, Never>?
    var pendingSeekTime: Double?
    var isSeeking = false
    var info = ""
    var showInfo = false
    var scaleMode: ScaleMode = .fit {
        didSet {
            scaler = nil
        }
    }
    var currentTime: Double = 0
    var duration: Double = 0
    var colorspaceLabel = "sRGB"
    var subtitleText = ""
    var statusLabel = ""
    var selectedSubtitleIndex = -1
    var errorMessage: String?
    var subtitleOptions: [AVMediaSelectionOption] = []
    var subtitleGroup: AVMediaSelectionGroup?
    var legibleOutput: AVPlayerItemLegibleOutput?
    var didSetColorSpace = false
    var scalerColorMode: MTLFXSpatialScalerColorProcessingMode = .perceptual
    var itemStatusObservation: NSKeyValueObservation?
    var endObservation: NSObjectProtocol?
    var displayLink: CADisplayLink?
    // Render-rate + drop accounting for the info overlay. FPS is presented frames
    // over a ~0.5s sliding window. Drops are detected from gaps between the PTS of
    // consecutively pulled video frames — that catches frames that went by without
    // being displayed whether decode or render was late. lastPulledItemTime = -1 is
    // a sentinel meaning "don't judge the next gap" (fresh video, seek, loop).
    var measuredFPS: Double = 0
    var fpsFrameCount = 0
    var fpsWindowStart: CFTimeInterval = 0
    var droppedFrames = 0
    var lastPulledItemTime: Double = -1
    var nextOutputHostTime: CFTimeInterval = 0
    var screenObservation: NSObjectProtocol?

    // Compare CFString names directly against CGColorSpace constants — substring
    // matching on `cs.name` was broken because the runtime returns e.g.
    // "kCGColorSpaceITUR_2100_PQ" (no underscore between ITU and R).
    // BT.709 / BT.2020 SDR use BT.1886 (~pure 2.4 gamma) in spec, but
    // approximating with the sRGB piecewise EOTF is close enough that the
    // residual error is far below the EWA-in-linear-vs-encoded-space gap.
    static func classify(colorspace cs: CGColorSpace) -> (label: String, isHDR: Bool, tf: TransferFunction) {
        guard let cfName = cs.name else { return ("Unknown", false, .sRGB) }
        switch cfName {
        case CGColorSpace.itur_2100_PQ:            return ("BT.2100 PQ",                true,  .pq)
        case CGColorSpace.displayP3_PQ:            return ("Display P3 PQ",             true,  .pq)
        case CGColorSpace.itur_2100_HLG:           return ("BT.2100 HLG",               true,  .hlg)
        case CGColorSpace.displayP3_HLG:           return ("Display P3 HLG",            true,  .hlg)
        case CGColorSpace.itur_2020:               return ("BT.2020",                   false, .sRGB)
        case CGColorSpace.itur_709:                return ("BT.709",                    false, .sRGB)
        case CGColorSpace.sRGB:                    return ("sRGB",                      false, .sRGB)
        case CGColorSpace.displayP3:               return ("Display P3",                false, .sRGB)
        case CGColorSpace.extendedLinearDisplayP3: return ("Extended Linear Display P3", true,  .linear)
        case CGColorSpace.extendedLinearSRGB:      return ("Extended Linear sRGB",       true,  .linear)
        default:                                   return (cfName as String,            false, .sRGB)
        }
    }

    deinit {
        currentSetupTask?.cancel()
        engine?.shutdown()
        displayLink?.invalidate()
        if let screenObservation { NotificationCenter.default.removeObserver(screenObservation) }
        if let endObservation { NotificationCenter.default.removeObserver(endObservation) }
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }

    // Hold the idle-sleep assertion only while actually playing — a paused player
    // shouldn't keep the display awake indefinitely.
    func setPlaybackActivity(_ playing: Bool) {
        if playing, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: .idleDisplaySleepDisabled, reason: "Video playback")
        } else if !playing, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    // Attach (or re-attach) a CADisplayLink bound to the view's current screen.
    // Called after the view is in a window and on screen changes — the link is
    // screen-specific, so dragging the window to a 60Hz panel from a 120Hz panel
    // must rebuild it to get the new vsync cadence.
    @MainActor
    func ensureDisplayLink(view: MTKView, preferredFPS: Int? = nil) {
        let screen = view.window?.screen ?? NSScreen.main
        guard let screen else { return }
        displayLink?.invalidate()
        let link = screen.displayLink(target: self, selector: #selector(displayLinkFired(_:)))
        if let fps = preferredFPS, fps > 0 {
            // Lock the link to the content rate so VRR/ProMotion panels can drop to
            // the content frame rate (e.g., 120Hz panel → 24Hz refresh for 24fps film).
            let f = Float(fps)
            link.preferredFrameRateRange = CAFrameRateRange(minimum: f, maximum: f, preferred: f)
        }
        link.add(to: .main, forMode: .common)
        displayLink = link

        if screenObservation == nil, let window = view.window {
            screenObservation = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeScreenNotification,
                object: window,
                queue: .main
            ) { [weak self, weak view] _ in
                guard let self, let view else { return }
                // Delivered on .main (see queue: above), so we're already on the main
                // actor — assert it so the @MainActor call is statically legal.
                MainActor.assumeIsolated {
                    self.ensureDisplayLink(view: view, preferredFPS: self.contentFPS)
                }
            }
        }
    }

    var contentFPS: Int?

    @objc func displayLinkFired(_ link: CADisplayLink) {
        nextOutputHostTime = link.targetTimestamp
        view?.draw()
    }

    // YUV→RGB matrix for a given (Kr, Kb) pair, expecting Y ∈ [0,1] and Cb/Cr ∈ [-0.5,0.5].
    // Columns map to Y, Cb, Cr — Metal does matrix * vector, with columns in memory order.
    static func yuvToRgb(kr: Float, kb: Float) -> simd_float3x3 {
        let kg = 1.0 - kr - kb
        let col0 = simd_float3(1, 1, 1)
        let col1 = simd_float3(0, -2 * kb * (1 - kb) / kg, 2 * (1 - kb))
        let col2 = simd_float3(2 * (1 - kr), -2 * kr * (1 - kr) / kg, 0)
        return simd_float3x3(columns: (col0, col1, col2))
    }

    // Populate intakeUniformsBuffer from a pixel buffer's format, range, bit depth,
    // YCbCr matrix and chroma siting. Called once per video — these parameters don't
    // change frame-to-frame within a stream.
    func writeIntakeUniforms(pixelBuffer: CVPixelBuffer, attachments: NSDictionary) {
        let pixFmt = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let isVideoRange: Bool
        let bitDepth: Int
        switch pixFmt {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:  isVideoRange = true;  bitDepth = 8
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:   isVideoRange = false; bitDepth = 8
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange: isVideoRange = true;  bitDepth = 10
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:  isVideoRange = false; bitDepth = 10
        default:
            // Unexpected format slipped past our negotiated list — fall back to
            // 8-bit video range BT.709, which is the safest assumption for SDR.
            isVideoRange = true; bitDepth = 8
        }

        // Sample → 10-bit-normalized scale. 8-bit r8Unorm already returns V/255 ∈ [0,1];
        // 10-bit MSB-aligned in r16Unorm returns V*64/65535, so multiply by 65535/65472
        // to recover V/1023. Negligible (≈0.1%) but exact.
        let bdScale: Float = bitDepth == 10 ? 65535.0 / 65472.0 : 1.0
        let yScale: Float
        let yBias:  Float
        let cScale: Float
        let cBias:  Float
        if isVideoRange {
            if bitDepth == 8 {
                yScale = bdScale * 255.0 / 219.0;  yBias = -16.0 / 219.0
                cScale = bdScale * 255.0 / 224.0;  cBias = -128.0 / 224.0
            } else {
                yScale = bdScale * 1023.0 / 876.0; yBias = -64.0 / 876.0
                cScale = bdScale * 1023.0 / 896.0; cBias = -512.0 / 896.0
            }
        } else {
            // Full range: 8-bit chroma is biased around 128/255; 10-bit around 512/1023.
            let chromaCenter: Float = bitDepth == 8 ? 128.0 / 255.0 : 512.0 / 1023.0
            yScale = bdScale;        yBias = 0
            cScale = bdScale;        cBias = -chromaCenter
        }

        // YCbCr matrix from the attached identifier. Fall back to BT.709 — that's
        // what the OS does when the source omits the matrix tag.
        let matrixKey = attachments[kCVImageBufferYCbCrMatrixKey] as? String
        let m2020 = kCVImageBufferYCbCrMatrix_ITU_R_2020       as String
        let m601  = kCVImageBufferYCbCrMatrix_ITU_R_601_4      as String
        let m240  = kCVImageBufferYCbCrMatrix_SMPTE_240M_1995  as String
        let m: simd_float3x3
        if matrixKey == m2020 {
            m = Self.yuvToRgb(kr: 0.2627, kb: 0.0593)
        } else if matrixKey == m601 {
            m = Self.yuvToRgb(kr: 0.299, kb: 0.114)
        } else if matrixKey == m240 {
            m = Self.yuvToRgb(kr: 0.212, kb: 0.087)
        } else {
            m = Self.yuvToRgb(kr: 0.2126, kb: 0.0722)  // BT.709 default
        }

        // Chroma siting. Per CVImageBuffer.h:104-112, the values describe where
        // the chroma sample sits inside its 2×2 luma block. Convert each named
        // position to a chroma-Metal-coord offset (in chroma-pixel units) such
        // that `chromaMetal = lumaMetal/2 - chromaOffset` lands on the right spot.
        // Derivations:
        //   Left:        chroma at luma (2i, 2j+0.5) → cMetal = (lx/2+0.25, ly/2)        ⇒ offset (-0.25,  0)
        //   TopLeft:     chroma at luma (2i,   2j  ) → cMetal = (lx/2+0.25, ly/2+0.25)   ⇒ offset (-0.25, -0.25)
        //   Top:         chroma at luma (2i+0.5,2j ) → cMetal = (lx/2,      ly/2+0.25)   ⇒ offset ( 0,    -0.25)
        //   Center:      chroma at luma (2i+0.5,2j+0.5) → cMetal = (lx/2,    ly/2)        ⇒ offset ( 0,     0)
        //   BottomLeft:  chroma at luma (2i,   2j+1) → cMetal = (lx/2+0.25, ly/2-0.25)   ⇒ offset (-0.25,  0.25)
        //   Bottom:      chroma at luma (2i+0.5,2j+1) → cMetal = (lx/2,      ly/2-0.25)  ⇒ offset ( 0,     0.25)
        let chromaSite = attachments[kCVImageBufferChromaLocationTopFieldKey] as? String
        let chromaTopLeft    = kCVImageBufferChromaLocation_TopLeft    as String
        let chromaTop        = kCVImageBufferChromaLocation_Top        as String
        let chromaCenter     = kCVImageBufferChromaLocation_Center     as String
        let chromaBottomLeft = kCVImageBufferChromaLocation_BottomLeft as String
        let chromaBottom     = kCVImageBufferChromaLocation_Bottom     as String
        let chromaOffset: simd_float2
        if chromaSite == chromaTopLeft {
            chromaOffset = simd_float2(-0.25, -0.25)
        } else if chromaSite == chromaTop {
            chromaOffset = simd_float2(0, -0.25)
        } else if chromaSite == chromaCenter {
            chromaOffset = simd_float2(0, 0)
        } else if chromaSite == chromaBottomLeft {
            chromaOffset = simd_float2(-0.25, 0.25)
        } else if chromaSite == chromaBottom {
            chromaOffset = simd_float2(0, 0.25)
        } else {
            // _Left / _DV420 / nil → MPEG-2 / H.264 / HEVC default
            chromaOffset = simd_float2(-0.25, 0)
        }

        ycbcrMatrix = m

        // Layout matches shader IntakeUniforms exactly: float3x3 (48, columns padded
        // to 16) + 3× float2 (24) + float2x2 (16, 8-aligned at offset 72) + tf + pad
        // = 96 bytes.
        let p = intakeUniformsBuffer.contents()
        p.assumingMemoryBound(to: simd_float3x3.self).pointee = m
        let offset0 = MemoryLayout<simd_float3x3>.size
        let f = p.advanced(by: offset0).assumingMemoryBound(to: Float.self)
        f[0] = yScale;       f[1] = yBias
        f[2] = cScale;       f[3] = cBias
        f[4] = chromaOffset.x; f[5] = chromaOffset.y
        f[6] = rotation.columns.0.x; f[7] = rotation.columns.0.y
        f[8] = rotation.columns.1.x; f[9] = rotation.columns.1.y
        f[10] = Float(transferFunction.rawValue)
        f[11] = 0
    }

    func cycleSubtitles() {
        if let engine {
            let tracks = engine.subtitleTracks
            guard !tracks.isEmpty else {
                statusLabel = "Subtitles: None Available"
                return
            }
            selectedSubtitleIndex += 1
            if selectedSubtitleIndex >= tracks.count {
                selectedSubtitleIndex = -1
                subtitleText = ""
                statusLabel = "Subtitles: Off"
            } else {
                let t = tracks[selectedSubtitleIndex]
                let label = t.name ?? t.language
                statusLabel = "Subtitles \(selectedSubtitleIndex + 1)/\(tracks.count): \(label)"
            }
            return
        }
        guard let group = subtitleGroup, !subtitleOptions.isEmpty else {
            statusLabel = "Subtitles: None Available"
            return
        }
        selectedSubtitleIndex += 1
        if selectedSubtitleIndex >= subtitleOptions.count {
            selectedSubtitleIndex = -1
            playerItem?.select(nil, in: group)
            subtitleText = ""
            statusLabel = "Subtitles: Off"
        } else {
            let option = subtitleOptions[selectedSubtitleIndex]
            playerItem?.select(option, in: group)
            let lang = option.displayName
            statusLabel = "Subtitles: \(lang)"
        }
    }

    func cycleAudio() {
        guard let engine else {
            statusLabel = "Audio: track switching is MKV-only for now"
            return
        }
        statusLabel = engine.cycleAudioTrack()
    }

    func seek(to time: Double) {
        let clamped = max(0, min(duration, time))
        pendingSeekTime = clamped
        isSeeking = true
        lastPulledItemTime = -1
        if let engine {
            engine.seek(toSeconds: clamped) { [weak self] in
                guard let self else { return }
                if self.pendingSeekTime == clamped {
                    self.pendingSeekTime = nil
                    self.isSeeking = false
                    self.currentTime = clamped
                }
            }
            return
        }
        let target = CMTime(seconds: clamped, preferredTimescale: 600)
        player?.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self else { return }
            if self.pendingSeekTime == clamped {
                self.pendingSeekTime = nil
                self.isSeeking = false
            }
        }
    }

    func seek(by seconds: Double) {
        let current = pendingSeekTime
            ?? engine.map { $0.currentTimeSeconds() }
            ?? player?.currentTime().seconds
            ?? 0
        seek(to: current + seconds)
    }

    func togglePlayback() {
        if let engine {
            setPlaybackActivity(engine.togglePlayPause())
            return
        }
        guard let player else { return }
        if player.rate == 0 {
            player.play()
            setPlaybackActivity(true)
        } else {
            player.pause()
            setPlaybackActivity(false)
        }
    }

    @MainActor
    func setupVideo(url: URL, view: MTKView) {
        currentSetupTask?.cancel()
        currentSetupTask = nil
        errorMessage = nil
        engine?.shutdown()
        engine = nil
        player?.pause()
        player = nil
        let ext = url.pathExtension.lowercased()
        if ext == "mkv" || ext == "webm" {
            setupEnginePipeline(url: url, view: view)
        } else {
            setupVideoPipeline(url: url, view: view)
        }
    }

    // MKV/WebM go through the native engine: our own Matroska demuxer feeding
    // VideoToolbox and AVSampleBufferAudioRenderer. The AVPlayer path below
    // remains for MP4/MOV until Phase 4 unifies the two.
    @MainActor
    func setupEnginePipeline(url: URL, view: MTKView) {
        setPlaybackActivity(false)
        let newEngine: PlaybackEngine
        do {
            newEngine = try PlaybackEngine(url: url)
        } catch {
            errorMessage = "Cannot play this file: \(error)"
            return
        }
        engine = newEngine
        setupMetalCore(view: view)
        guard errorMessage == nil else {
            engine = nil
            return
        }

        selectedSubtitleIndex = -1
        subtitleText = ""
        subtitleOptions = []
        subtitleGroup = nil
        currentTime = 0
        pendingSeekTime = nil
        measuredFPS = 0
        fpsFrameCount = 0
        fpsWindowStart = 0
        droppedFrames = 0
        lastPulledItemTime = -1

        duration = newEngine.durationSeconds
        displayAspect = CGFloat(newEngine.displayAspect ?? 0)
        rotationQuadrant = 0
        rotation = matrix_identity_float2x2
        if let fps = newEngine.contentFPS, fps > 0 {
            let rounded = max(1, Int(fps.rounded()))
            contentFPS = rounded
            ensureDisplayLink(view: view, preferredFPS: rounded)
        }

        newEngine.onStatus = { [weak self] message in
            self?.statusLabel = message
        }
        // At end of playback, rewind and pause so Space replays from the start
        // (mirrors the AVPlayer end-of-item behavior). Uses the same
        // isSeeking freeze as user seeks so draw() doesn't pull the new run's
        // first frames against the stale end-of-file timebase.
        newEngine.onEnded = { [weak self] in
            guard let self else { return }
            self.engine?.setPlaying(false)
            self.setPlaybackActivity(false)
            self.isSeeking = true
            self.pendingSeekTime = 0
            self.lastPulledItemTime = -1
            self.engine?.seek(toSeconds: 0) { [weak self] in
                guard let self else { return }
                if self.pendingSeekTime == 0 {
                    self.pendingSeekTime = nil
                    self.isSeeking = false
                }
                self.currentTime = 0
            }
        }
    }


    // MP4/MOV playback via AVPlayer (unchanged legacy path — Phase 4 moves
    // this onto the engine through an AVAssetReader-backed demuxer).
    @MainActor
    func setupVideoPipeline(url: URL, view: MTKView) {
        setupMetalCore(view: view)
        guard errorMessage == nil else { return }

        let asset = AVURLAsset(url: url)
        playerItem = AVPlayerItem(asset: asset)

        // Surface unplayable formats (.webm, .avi, broken codec, etc.) instead of a
        // silent black screen. AVPlayerItem.status transitions to .failed when the
        // asset can't be loaded; .error carries the diagnostic.
        itemStatusObservation = playerItem?.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self, item.status == .failed else { return }
            let msg = item.error?.localizedDescription ?? "Unknown decode error"
            Task { @MainActor in self.errorMessage = "Cannot play this file: \(msg)" }
        }

        // At end of playback, rewind and pause so Space replays from the start
        // (and the idle-sleep assertion is released while we sit on the end frame).
        if let endObservation { NotificationCenter.default.removeObserver(endObservation) }
        endObservation = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.player?.pause()
                self.player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                self.currentTime = 0
                self.lastPulledItemTime = -1
                self.setPlaybackActivity(false)
            }
        }

        // Bi-planar YUV intake. CVPixelBuffer.h:232 says the format-type key takes a
        // CFArray of CFNumbers, so AVF picks the closest match to the source — we
        // do YUV→RGB + chroma upsample + transfer-function decode ourselves in the
        // intake shader, instead of letting AVF pre-mix RGBA half-float for us.
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: [
                Int(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),
                Int(kCVPixelFormatType_420YpCbCr10BiPlanarFullRange),
                Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
            ],
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]

        let newVideoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: pixelBufferAttributes)
        videoOutput = newVideoOutput
        playerItem?.add(newVideoOutput)

        let newLegibleOutput = AVPlayerItemLegibleOutput()
        newLegibleOutput.setDelegate(self, queue: .main)
        newLegibleOutput.suppressesPlayerRendering = true
        legibleOutput = newLegibleOutput
        playerItem?.add(newLegibleOutput)

        player = AVPlayer(playerItem: playerItem)

        selectedSubtitleIndex = -1
        subtitleText = ""
        subtitleOptions = []
        subtitleGroup = nil
        currentTime = 0
        pendingSeekTime = nil
        measuredFPS = 0
        fpsFrameCount = 0
        fpsWindowStart = 0
        droppedFrames = 0
        lastPulledItemTime = -1

        Task { [weak self] in
            guard let self else { return }
            if let dur = try? await asset.load(.duration) {
                await MainActor.run { self.duration = CMTimeGetSeconds(dur) }
            }
            // Pull display orientation + frame rate + PAR off the first video track.
            // preferredTransform rotates the encoded frame for display (portrait phone
            // clips are typically encoded landscape with a 90° transform). PAR comes
            // from the format description and stretches non-square encoded pixels
            // (DVD, some broadcast).
            if let track = try? await asset.loadTracks(withMediaType: .video).first {
                let naturalSize = (try? await track.load(.naturalSize)) ?? .zero
                let preferredTransform = (try? await track.load(.preferredTransform)) ?? .identity
                let fps = (try? await track.load(.nominalFrameRate)) ?? 0
                let descriptions: [CMFormatDescription] = (try? await track.load(.formatDescriptions)) ?? []

                // Decompose preferredTransform to a 90°-quantized rotation. atan2(b, a)
                // is the rotation angle in CG's row-vector convention. Round to nearest
                // 90° (the actual content of preferredTransform is almost always exact).
                let angleDeg = atan2(preferredTransform.b, preferredTransform.a) * 180.0 / .pi
                let normalizedDeg = (angleDeg + 360.0).truncatingRemainder(dividingBy: 360.0)
                let quadrant = Int((normalizedDeg / 90.0).rounded()) % 4
                let rotMatrix: simd_float2x2
                switch quadrant {
                case 1: rotMatrix = simd_float2x2(columns: (SIMD2<Float>(0, -1), SIMD2<Float>(1, 0)))
                case 2: rotMatrix = simd_float2x2(columns: (SIMD2<Float>(-1, 0), SIMD2<Float>(0, -1)))
                case 3: rotMatrix = simd_float2x2(columns: (SIMD2<Float>(0, 1), SIMD2<Float>(-1, 0)))
                default: rotMatrix = matrix_identity_float2x2
                }

                // Pixel aspect ratio (PAR) — typically 1:1 for digital files. When
                // present, multiplies encoded width to get display width.
                var par: (CGFloat, CGFloat) = (1, 1)
                if let desc = descriptions.first,
                   let parDict = CMFormatDescriptionGetExtension(
                        desc,
                        extensionKey: kCMFormatDescriptionExtension_PixelAspectRatio
                   ) as? [String: Any],
                   let h = parDict[kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing as String] as? Double,
                   let v = parDict[kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing as String] as? Double,
                   v > 0 {
                    par = (CGFloat(h), CGFloat(v))
                }

                let preRotAspect = (naturalSize.height > 0)
                    ? (naturalSize.width * par.0 / par.1) / naturalSize.height
                    : 1.0
                let aspect = (quadrant % 2 == 0) ? preRotAspect : 1.0 / preRotAspect

                let rounded = max(1, Int(fps.rounded()))
                await MainActor.run {
                    self.rotationQuadrant = quadrant
                    self.rotation = rotMatrix
                    self.displayAspect = aspect
                    if fps > 0 {
                        self.contentFPS = rounded
                        if let v = self.view { self.ensureDisplayLink(view: v, preferredFPS: rounded) }
                    }
                    // Force re-derivation of intake uniforms (which now include rotation).
                    self.lastPixelFormat = 0
                    // Force linearTexture realloc if rotation changes its dimensions.
                    self.linearTexture = nil
                }
            }
            if let group = try? await asset.loadMediaSelectionGroup(for: .legible) {
                await MainActor.run {
                    self.subtitleGroup = group
                    self.subtitleOptions = group.options
                    self.playerItem?.select(nil, in: group)
                }
            }
        }
    }

    // Kicks off playback once the render pipelines exist — whichever producer
    // the current file uses.
    @MainActor
    func startProducers() {
        if let engine {
            engine.start(playing: true)
            setPlaybackActivity(true)
        } else if let player {
            player.play()
            setPlaybackActivity(true)
        }
    }

    // Producer-agnostic Metal setup: device objects, texture cache, kernel
    // LUT, argument table, uniforms, and the async shader compile. Shared by
    // the engine (MKV) and AVPlayer (MP4) paths.
    @MainActor
    func setupMetalCore(view: MTKView) {
        device = view.device
        queue = device.makeMTL4CommandQueue()

        do {
            compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
        } catch {
            errorMessage = "Metal compiler init failed: \(error.localizedDescription)"
            return
        }

        if let oldCache = textureCache { CVMetalTextureCacheFlush(oldCache, 0) }
        textureCache = nil
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        guard textureCache != nil else {
            errorMessage = "Couldn't create texture cache."
            return
        }

        scaler = nil
        didSetColorSpace = false
        lastPixelFormat = 0
        rotationQuadrant = 0
        rotation = matrix_identity_float2x2
        displayAspect = 0
        yTexture = nil
        cbcrTexture = nil
        linearTexture = nil
        ySource = nil
        cbcrSource = nil

        // Spin up the display link now (before the async track-fps fetch completes)
        // so we start ticking and can render the first frames as soon as the player
        // is ready. Frame-rate range gets refined once we know the source fps.
        ensureDisplayLink(view: view, preferredFPS: nil)

        do {
            let tableDesc = MTL4ArgumentTableDescriptor()
            // Texture bindings: 0 Y / linear source, 1 CbCr / kernelLUT.
            // Buffer bindings: 0 uniforms (intake or scaling).
            tableDesc.maxTextureBindCount = 2
            tableDesc.maxBufferBindCount = 1
            argumentTable = try device.makeArgumentTable(descriptor: tableDesc)
            residencySet = try device.makeResidencySet(descriptor: MTLResidencySetDescriptor())
        } catch {
            errorMessage = "Metal table/residency-set init failed: \(error.localizedDescription)"
            return
        }

        // ewa_lanczossharp kernel LUT (libplacebo). Standard jinc * jinc-window
        // with a mild 0.98125 blur factor and the 3rd jinc zero as support.
        // Precomputed into a 1D LUT indexed by r / maxR ∈ [0, 1].
        let lutSize = 512
        let kernelRadius = 3.2383154841662362
        let blur = 0.98125058372237073
        let maxR = kernelRadius * blur
        func jinc(_ x: Double) -> Double {
            if abs(x) < 1e-8 { return 1.0 }
            return 2.0 * j1(.pi * x) / (.pi * x)
        }
        var lutData = [Float](repeating: 0, count: lutSize)
        for i in 0..<lutSize {
            let r = (Double(i) / Double(lutSize - 1)) * maxR
            let rPrime = r / blur
            if rPrime >= kernelRadius {
                lutData[i] = 0
            } else {
                lutData[i] = Float(jinc(rPrime) * jinc(rPrime / kernelRadius))
            }
        }
        let lutDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: lutSize, height: 1, mipmapped: false)
        lutDesc.usage = .shaderRead
        lutDesc.storageMode = .shared
        guard let lutTex = device.makeTexture(descriptor: lutDesc) else {
            errorMessage = "Failed to allocate kernel LUT."
            return
        }
        lutData.withUnsafeBytes { bytes in
            lutTex.replace(region: MTLRegionMake2D(0, 0, lutSize, 1), mipmapLevel: 0, withBytes: bytes.baseAddress!, bytesPerRow: lutSize * MemoryLayout<Float>.size)
        }
        kernelLUT = lutTex
        argumentTable.setTexture(kernelLUT.gpuResourceID, index: 1)

        // Intake uniforms: float3x3 (48) + 3× float2 (24) + float2x2 (16) + 2× float (8) = 96,
        // allocated at 112 for headroom. See IntakeUniforms in shader.
        guard let uBuf = device.makeBuffer(length: 16, options: .storageModeShared),
              let iBuf = device.makeBuffer(length: 112, options: .storageModeShared),
              let alloc = device.makeCommandAllocator(),
              let intakeF = device.makeFence(),
              let cmd = device.makeCommandBuffer(),
              let event = device.makeSharedEvent() else {
            errorMessage = "Failed to allocate Metal resources."
            return
        }
        uniformsBuffer = uBuf
        intakeUniformsBuffer = iBuf
        allocator = alloc
        intakeFence = intakeF
        commandBuffer = cmd
        frameEvent = event
        pendingFrameValue = 0

        // Pipeline:
        //
        //   YUV planes ──[Intake]──▶ linear-light extended RGB (source res, rgba16Float)
        //                             ├──[EWA-in-linear]──▶ scaled linear target
        //                             ├──[MetalFX .hdr]──▶ scaled linear target
        //                             └──[no scale]
        //                                          │
        //                              [Final blit + TF encode]
        //                                          ▼
        //                                  drawable (PQ/HLG/sRGB-tagged layer)
        //
        // Intake performs YUV→RGB matrix, Mitchell-Netravali 4×4 chroma upsample
        // with chroma-siting offset, range expansion (video/full × 8/10-bit), and
        // PQ/HLG/sRGB EOTF decode. Everything downstream operates in linear light.
        // The final blit re-applies the source TF on the way to the drawable.
        let shaderSource = """
            #include <metal_stdlib>
            using namespace metal;
            struct VertexOut { float4 position [[position]]; float2 texCoord; };

            // Scaling/blit uniforms — vertex uses quadScale, EWA uses ratio,
            // bilinear blit uses tf to re-encode on output.
            struct Uniforms { float2 quadScale; float ratio; float tf; };

            // Intake uniforms — columns of float3x3 each padded to float4 stride
            // (48 bytes), then 8/8/8/16/4/4 = 96 bytes total.
            struct IntakeUniforms {
                float3x3 yuvToRgb;
                float2 yScaleBias;     // Y' = sample * yScaleBias.x + yScaleBias.y
                float2 cScaleBias;     // C' = sample * cScaleBias.x + cScaleBias.y, ∈[-0.5,0.5]
                float2 chromaOffset;   // siting offset, in chroma-pixel units
                float2x2 rotation;     // display texCoord → source texCoord, about (0.5, 0.5)
                float tf;
                float _pad;
            };

            vertex VertexOut vertexShader(uint vid [[vertex_id]], constant Uniforms &u [[buffer(0)]]) {
                float2 positions[6] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(-1,1), float2(1,-1), float2(1,1) };
                float2 texCoords[6] = { float2(0,1), float2(1,1), float2(0,0), float2(0,0), float2(1,1), float2(1,0) };
                return { float4(positions[vid] * u.quadScale, 0, 1), texCoords[vid] };
            }

            // Full-coverage triangle for intake — no quad scale, writes to the
            // entire linear intermediate texture at source resolution.
            vertex VertexOut vertexShaderFull(uint vid [[vertex_id]]) {
                float2 positions[6] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(-1,1), float2(1,-1), float2(1,1) };
                float2 texCoords[6] = { float2(0,1), float2(1,1), float2(0,0), float2(0,0), float2(1,1), float2(1,0) };
                return { float4(positions[vid], 0, 1), texCoords[vid] };
            }

            // sRGB piecewise EOTF / inverse (IEC 61966-2-1). Used for sRGB and as
            // a close approximation of BT.1886 for BT.709/BT.2020 SDR content.
            static inline float3 srgbToLinear(float3 c) {
                float3 lo = c / 12.92;
                float3 hi = pow(max((c + 0.055) / 1.055, 0.0), 2.4);
                return select(hi, lo, c <= 0.04045);
            }
            static inline float3 linearToSrgb(float3 c) {
                float3 lo = c * 12.92;
                float3 hi = 1.055 * pow(max(c, 0.0), 1.0 / 2.4) - 0.055;
                return select(hi, lo, c <= 0.0031308);
            }

            // SMPTE ST 2084 PQ EOTF / inverse (BT.2100). 1.0 ⇒ 10000 cd/m² peak.
            static inline float3 pqToLinear(float3 e) {
                constexpr float m1 = 2610.0 / 16384.0;
                constexpr float m2 = 2523.0 / 4096.0 * 128.0;
                constexpr float c1 = 3424.0 / 4096.0;
                constexpr float c2 = 2413.0 / 4096.0 * 32.0;
                constexpr float c3 = 2392.0 / 4096.0 * 32.0;
                float3 p = pow(max(e, 0.0), 1.0 / m2);
                float3 num = max(p - c1, 0.0);
                float3 den = c2 - c3 * p;
                return pow(num / max(den, 1e-10), 1.0 / m1);
            }
            static inline float3 linearToPq(float3 y) {
                constexpr float m1 = 2610.0 / 16384.0;
                constexpr float m2 = 2523.0 / 4096.0 * 128.0;
                constexpr float c1 = 3424.0 / 4096.0;
                constexpr float c2 = 2413.0 / 4096.0 * 32.0;
                constexpr float c3 = 2392.0 / 4096.0 * 32.0;
                float3 yp = pow(max(y, 0.0), m1);
                float3 num = c1 + c2 * yp;
                float3 den = 1.0 + c3 * yp;
                return pow(num / den, m2);
            }

            // BT.2100 HLG inverse OETF / OETF. Scene-linear [0,1]. We deliberately
            // do NOT apply the HLG OOTF — the system OOTF runs at display time per
            // CAEDRMetadata.h, but since we're not attaching EDRMetadata we leave
            // values as scene-linear and the panel shows what it can; the rest clips.
            static inline float3 hlgToLinear(float3 e) {
                constexpr float a = 0.17883277;
                constexpr float b = 0.28466892;
                constexpr float c = 0.55991073;
                float3 lo = (e * e) / 3.0;
                float3 hi = (exp((e - c) / a) + b) / 12.0;
                return select(hi, lo, e <= 0.5);
            }
            static inline float3 linearToHlg(float3 y) {
                constexpr float a = 0.17883277;
                constexpr float b = 0.28466892;
                constexpr float c = 0.55991073;
                float3 yc = max(y, 0.0);
                float3 lo = sqrt(3.0 * yc);
                float3 hi = a * log(12.0 * yc - b) + c;
                return select(hi, lo, yc <= 1.0 / 12.0);
            }

            static inline float3 encodedToLinear(float3 c, int tf) {
                if (tf == 1) return srgbToLinear(c);
                if (tf == 2) return pqToLinear(c);
                if (tf == 3) return hlgToLinear(c);
                return c;
            }
            static inline float3 linearToEncoded(float3 c, int tf) {
                if (tf == 1) return linearToSrgb(c);
                if (tf == 2) return linearToPq(c);
                if (tf == 3) return linearToHlg(c);
                return c;
            }

            // Mitchell-Netravali cubic with B = C = 1/3 — minimal ringing, slightly
            // softer than Catmull-Rom; recommended for image reconstruction. We use
            // it for chroma upsampling 4:2:0 → 4:4:4 inside the intake pass.
            static inline float mitchell(float x) {
                x = fabs(x);
                constexpr float B = 1.0 / 3.0;
                constexpr float C = 1.0 / 3.0;
                if (x < 1.0) {
                    float x2 = x * x;
                    return ((12.0 - 9.0 * B - 6.0 * C) * x * x2 +
                            (-18.0 + 12.0 * B + 6.0 * C) * x2 +
                            (6.0 - 2.0 * B)) / 6.0;
                } else if (x < 2.0) {
                    float x2 = x * x;
                    return ((-B - 6.0 * C) * x * x2 +
                            (6.0 * B + 30.0 * C) * x2 +
                            (-12.0 * B - 48.0 * C) * x +
                            (8.0 * B + 24.0 * C)) / 6.0;
                }
                return 0.0;
            }

            // Intake fragment — YUV planes → linear-light extended RGB. Runs at
            // the source luma resolution. Caches all per-format details (matrix,
            // range, bit depth, chroma siting, TF) in IntakeUniforms.
            fragment half4 fragmentShaderIntake(VertexOut in [[stage_in]],
                                                 texture2d<float> yTex [[texture(0)]],
                                                 texture2d<float> cbcrTex [[texture(1)]],
                                                 constant IntakeUniforms &u [[buffer(0)]]) {
                constexpr sampler ySampler(coord::pixel, address::clamp_to_edge, filter::nearest);
                constexpr sampler cSampler(coord::pixel, address::clamp_to_edge, filter::nearest);

                float lumaW = float(yTex.get_width());
                float lumaH = float(yTex.get_height());
                float chromaW = float(cbcrTex.get_width());
                float chromaH = float(cbcrTex.get_height());

                // The render target is display-oriented (dimensions swapped for 90°/
                // 270° sources); rotate the coord about the center to sample the
                // unrotated source planes.
                float2 tc = u.rotation * (in.texCoord - 0.5) + 0.5;

                // Luma: sampled at the corresponding integer luma pixel (1:1).
                float lx = tc.x * lumaW;
                float ly = tc.y * lumaH;
                float ySample = yTex.sample(ySampler, float2(lx, ly)).x;
                float Yn = ySample * u.yScaleBias.x + u.yScaleBias.y;

                // Chroma: fractional position in chroma-pixel units, with siting
                // offset subtracted so the kernel re-centers on the true chroma
                // sample grid. 4×4 Mitchell neighborhood — outside-radius taps
                // get weight 0 from `mitchell(|x|>=2)`.
                float2 cFrac = float2(lx, ly) * 0.5 - u.chromaOffset;
                int cx0 = int(floor(cFrac.x - 0.5));
                int cy0 = int(floor(cFrac.y - 0.5));
                float2 cSum = float2(0);
                float wSum = 0;
                for (int j = 0; j < 4; ++j) {
                    float sy = float(cy0 + j) + 0.5;
                    float wy = mitchell(sy - cFrac.y);
                    for (int i = 0; i < 4; ++i) {
                        float sx = float(cx0 + i) + 0.5;
                        float wx = mitchell(sx - cFrac.x);
                        float w = wx * wy;
                        float2 cSampleRaw = cbcrTex.sample(cSampler,
                            float2(clamp(sx, 0.5, chromaW - 0.5),
                                   clamp(sy, 0.5, chromaH - 0.5))).xy;
                        cSum += w * cSampleRaw;
                        wSum += w;
                    }
                }
                float2 cNorm = cSum / max(wSum, 1e-6);
                float Cb = cNorm.x * u.cScaleBias.x + u.cScaleBias.y;
                float Cr = cNorm.y * u.cScaleBias.x + u.cScaleBias.y;

                float3 ycbcr = float3(Yn, Cb, Cr);
                float3 rgb = u.yuvToRgb * ycbcr;
                int tf = int(u.tf + 0.5);
                rgb = encodedToLinear(rgb, tf);
                return half4(half3(rgb), half(1.0));
            }

            // Final blit — input is linear extended HDR (rgba16Float), output
            // re-applies the source TF and writes to the drawable. Used for
            // scaleMode == .off, the MetalFX path, and the EWA output.
            fragment half4 fragmentShaderBlitEncode(VertexOut in [[stage_in]],
                                                    texture2d<half> tex [[texture(0)]],
                                                    constant Uniforms &u [[buffer(0)]]) {
                constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
                float4 t = float4(tex.sample(s, in.texCoord));
                int tf = int(u.tf + 0.5);
                t.rgb = max(t.rgb, 0.0);
                t.rgb = linearToEncoded(t.rgb, tf);
                return half4(t);
            }

            // ewa_lanczossharp (libplacebo). Input is linear-light extended HDR
            // from the intake pass; output stays in linear light. Filtering MUST
            // happen in linear — PQ in particular is so non-linear that filtering
            // in PQ-code space crushes highlight detail.
            //   kernelRadius = 3.2383 (third zero of J1), blur = 0.98125,
            //   maxR = kernelRadius * blur ≈ 3.178
            fragment half4 fragmentShaderEWA(VertexOut in [[stage_in]],
                                              texture2d<half> tex [[texture(0)]],
                                              texture2d<float> kernelLUT [[texture(1)]],
                                              constant Uniforms &u [[buffer(0)]]) {
                constexpr sampler texSampler(coord::pixel, address::clamp_to_edge, filter::nearest);
                constexpr sampler lutSampler(coord::normalized, address::clamp_to_edge, filter::linear);
                constexpr float kernelRadius = 3.2383154841662362;
                constexpr float blur = 0.98125058372237073;
                constexpr float maxR = kernelRadius * blur;

                float ratio = max(u.ratio, 1.0);
                int taps = min(int(ceil(maxR * ratio)), 20);
                int tf = int(u.tf + 0.5);

                float texW = float(tex.get_width());
                float texH = float(tex.get_height());
                float cx = in.texCoord.x * texW;
                float cy = in.texCoord.y * texH;
                int baseX = int(floor(cx - 0.5));
                int baseY = int(floor(cy - 0.5));

                float4 sum = float4(0);
                float wSum = 0;
                for (int j = -taps + 1; j <= taps; ++j) {
                    float sy = float(baseY + j) + 0.5;
                    float dy = (sy - cy) / ratio;
                    for (int i = -taps + 1; i <= taps; ++i) {
                        float sx = float(baseX + i) + 0.5;
                        float dx = (sx - cx) / ratio;
                        float r = sqrt(dx * dx + dy * dy);
                        if (r >= maxR) continue;
                        float w = kernelLUT.sample(lutSampler, float2(r / maxR, 0.5)).x;
                        float4 t = float4(tex.sample(texSampler, float2(sx, sy)));
                        sum += w * t;
                        wSum += w;
                    }
                }
                float4 result = sum / max(wSum, 1e-6);
                result.rgb = max(result.rgb, 0.0);
                result.rgb = linearToEncoded(result.rgb, tf);
                return half4(result);
            }
            """

        let pixelFormat = view.colorPixelFormat
        Task { [weak self] in
            guard let self else { return }
            let libDesc = MTL4LibraryDescriptor()
            libDesc.source = shaderSource
            let library: MTLLibrary
            do {
                library = try await self.compiler.makeLibrary(descriptor: libDesc)
            } catch {
                await MainActor.run { self.errorMessage = "Shader compile failed: \(error.localizedDescription)" }
                return
            }

            func makePipeline(vertexName: String, fragmentName: String, colorFormat: MTLPixelFormat) async throws -> MTLRenderPipelineState {
                let desc = MTL4RenderPipelineDescriptor()
                desc.vertexFunctionDescriptor = {
                    let d = MTL4LibraryFunctionDescriptor()
                    d.name = vertexName
                    d.library = library
                    return d
                }()
                desc.fragmentFunctionDescriptor = {
                    let d = MTL4LibraryFunctionDescriptor()
                    d.name = fragmentName
                    d.library = library
                    return d
                }()
                desc.colorAttachments[0].pixelFormat = colorFormat
                return try await self.compiler.makeRenderPipelineState(descriptor: desc)
            }

            do {
                self.renderPipelineIntake  = try await makePipeline(vertexName: "vertexShaderFull",
                                                                     fragmentName: "fragmentShaderIntake",
                                                                     colorFormat: .rgba16Float)
                self.renderPipelineEWA     = try await makePipeline(vertexName: "vertexShader",
                                                                     fragmentName: "fragmentShaderEWA",
                                                                     colorFormat: .rgba16Float)
                self.renderPipelineBilinear = try await makePipeline(vertexName: "vertexShader",
                                                                      fragmentName: "fragmentShaderBlitEncode",
                                                                      colorFormat: pixelFormat)
                await MainActor.run { self.startProducers() }
            } catch {
                await MainActor.run { self.errorMessage = "Pipeline state build failed: \(error.localizedDescription)" }
            }
        }
    }

    func draw(in view: MTKView) {
        guard renderPipelineIntake != nil,
              renderPipelineBilinear != nil,
              renderPipelineEWA != nil,
              let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentMTL4RenderPassDescriptor,
              let frameEvent
        else { return }

        // Predict which media-time will be on screen at the NEXT vsync, so the
        // frame we pull lines up with the frame we'll actually present.
        // nextOutputHostTime is the targetTimestamp from the most recent display
        // link fire (the host time of the upcoming refresh). While a seek is in
        // flight, freeze on the last texture instead of pulling — otherwise
        // forward seeks visibly fast-forward through buffered frames.
        let hostTime = nextOutputHostTime > 0 ? nextOutputHostTime : CACurrentMediaTime()
        var pulledBuffer: CVPixelBuffer?
        var pulledPts: Double = .nan

        if let engine {
            let mediaNs = engine.mediaTimeNs(forHostSeconds: hostTime)
            let now = engine.currentTimeSeconds()
            if abs(now - currentTime) >= 0.1 { currentTime = now }
            if !isSeeking, let frame = engine.pullFrame(atMediaTimeNs: mediaNs) {
                pulledBuffer = frame.buffer
                pulledPts = Double(frame.ptsNs) / 1e9
            }
            // Subtitles come from the engine's cue store, keyed by media time.
            if selectedSubtitleIndex >= 0 {
                let text = engine.subtitleText(atMediaTimeNs: mediaNs, trackIndex: selectedSubtitleIndex)
                if text != subtitleText { subtitleText = text }
            }
        } else if let output = videoOutput, let item = playerItem {
            let time = output.itemTime(forHostTime: hostTime)
            let now = item.currentTime().seconds
            if abs(now - currentTime) >= 0.1 { currentTime = now }
            var displayTime = CMTime.invalid
            if !isSeeking,
               output.hasNewPixelBuffer(forItemTime: time),
               let pixelBuffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &displayTime) {
                pulledBuffer = pixelBuffer
                if displayTime.isNumeric { pulledPts = displayTime.seconds }
            }
        }

        if let pixelBuffer = pulledBuffer,
           let attachmentsCF = CVBufferCopyAttachments(pixelBuffer, .shouldPropagate) {

                // Drop detection: consecutive pulled frames should be ~1/fps apart.
                // A gap well beyond that means intermediate frames were never shown.
                // Negative deltas (loop-around, backwards steps) just re-arm the chain.
                let producing = engine?.isPlaying ?? ((player?.rate ?? 0) > 0)
                if pulledPts.isFinite, let fps = contentFPS, fps > 0, producing {
                    let t = pulledPts
                    let expected = 1.0 / Double(fps)
                    if lastPulledItemTime >= 0 {
                        let delta = t - lastPulledItemTime
                        if delta > expected * 1.75 {
                            droppedFrames += max(1, Int((delta / expected).rounded()) - 1)
                        }
                    }
                    lastPulledItemTime = t
                }

                let attachments = attachmentsCF as NSDictionary
                // Re-derive colorspace and intake uniforms whenever the pixel format
                // changes — most streams are stable but some sources splice between
                // SDR/HDR or 8/10-bit segments, and both the layer tagging and the
                // per-format constants (range scale/bias, chroma layout) go stale if
                // we latch them once per video.
                let curPixFmt = CVPixelBufferGetPixelFormatType(pixelBuffer)
                let formatChanged = curPixFmt != lastPixelFormat
                if !didSetColorSpace || formatChanged,
                   let cs = CVImageBufferCreateColorSpaceFromAttachments(attachmentsCF)?.takeRetainedValue(),
                   let metalLayer = view.layer as? CAMetalLayer {
                    metalLayer.colorspace = cs
                    let (label, hdr, tf) = Self.classify(colorspace: cs)
                    metalLayer.wantsExtendedDynamicRangeContent = hdr
                    colorspaceLabel = label
                    isHDR = hdr
                    // After the intake pass everything is linear-light, so the
                    // perceptual / sRGB-encoded scaler mode no longer applies.
                    // For HDR we stay in `.hdr` because PQ-decoded peaks reach
                    // [0, 1] = [0, 10000 nits] — the "reversible tone map" is
                    // identity in our case. For SDR we use `.linear` since the
                    // intake pass already removed the sRGB curve. MTLFXSpatialScaler.h:19-28.
                    scalerColorMode = hdr ? .hdr : .linear
                    transferFunction = tf
                    // For PQ and SDR we leave edrMetadata nil — per CAMetalLayer.h:131
                    // that means "render without tone mapping; clip above max EDR."
                    // For HLG we attach CAEDRMetadata.hlg so the OS applies the
                    // standard HLG EOTF (which includes the BT.2100 OOTF) to the
                    // HLG-encoded values we write to the drawable. Without this the
                    // OS still color-manages the HLG-tagged layer, but attaching
                    // the metadata makes the system gamma choice explicit.
                    metalLayer.edrMetadata = (tf == .hlg) ? CAEDRMetadata.hlg : nil
                    didSetColorSpace = true
                    // If the scaler was built under a stale colorProcessingMode, rebuild it.
                    scaler = nil
                }

                if formatChanged {
                    writeIntakeUniforms(pixelBuffer: pixelBuffer, attachments: attachments)
                    lastPixelFormat = curPixFmt
                }

                // Bi-planar YUV intake. Plane 0 = Y, plane 1 = CbCr interleaved at
                // half-resolution. Pixel format dictates Metal format per plane:
                // 8-bit → r8Unorm / rg8Unorm; 10-bit MSB-aligned → r16Unorm /
                // rg16Unorm (we compensate for the 6-bit shift in-shader via yScale).
                let is10bit = (curPixFmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
                               curPixFmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)
                let yFmt: MTLPixelFormat  = is10bit ? .r16Unorm : .r8Unorm
                let cFmt: MTLPixelFormat  = is10bit ? .rg16Unorm : .rg8Unorm
                let lumaW = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
                let lumaH = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
                let chromaW = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
                let chromaH = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)

                var yCV: CVMetalTexture?
                var cCV: CVMetalTexture?
                CVMetalTextureCacheCreateTextureFromImage(
                    kCFAllocatorDefault, textureCache, pixelBuffer, nil,
                    yFmt, lumaW, lumaH, 0, &yCV)
                CVMetalTextureCacheCreateTextureFromImage(
                    kCFAllocatorDefault, textureCache, pixelBuffer, nil,
                    cFmt, chromaW, chromaH, 1, &cCV)
                ySource = yCV
                cbcrSource = cCV
                yTexture = yCV.flatMap { CVMetalTextureGetTexture($0) }
                cbcrTexture = cCV.flatMap { CVMetalTextureGetTexture($0) }

                // Linear-light intermediate at source resolution, display-oriented:
                // dimensions swap for 90°/270° sources so everything downstream
                // (EWA, MetalFX, fit/fill) sees an upright image. Realloc when the
                // dimensions change (track metadata arriving, rare mid-stream shifts).
                let rotated = rotationQuadrant % 2 == 1
                let intakeW = rotated ? lumaH : lumaW
                let intakeH = rotated ? lumaW : lumaH
                if linearTexture?.width != intakeW || linearTexture?.height != intakeH {
                    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: intakeW, height: intakeH, mipmapped: false)
                    d.usage = [.renderTarget, .shaderRead]
                    linearTexture = device.makeTexture(descriptor: d)
                    scaler = nil
                }
        }

        guard let yTexture, let cbcrTexture, let linearTexture else { return }
        let inputTexture = linearTexture

        let viewportSize = CGSize(width: drawable.texture.width, height: drawable.texture.height)
        // PAR-corrected display aspect once track metadata is in (anamorphic DVD /
        // broadcast sources); the display-oriented texture's own aspect until then.
        let imageAspect = displayAspect > 0
            ? displayAspect
            : CGFloat(inputTexture.width) / CGFloat(inputTexture.height)
        let viewportAspect = viewportSize.width / viewportSize.height

        let targetSize: CGSize
        switch scaleMode {
        case .fit:
            targetSize = imageAspect > viewportAspect
                ? CGSize(width: viewportSize.width, height: viewportSize.width / imageAspect)
                : CGSize(width: viewportSize.height * imageAspect, height: viewportSize.height)
        case .fill:
            targetSize = imageAspect > viewportAspect
                ? CGSize(width: viewportSize.height * imageAspect, height: viewportSize.height)
                : CGSize(width: viewportSize.width, height: viewportSize.width / imageAspect)
        case .off:
            targetSize = CGSize(width: CGFloat(inputTexture.width), height: CGFloat(inputTexture.height))
        }

        if scaleMode != .off && scaler == nil {
            let (outputWidth, outputHeight) = (Int(targetSize.width), Int(targetSize.height))

            if outputWidth > inputTexture.width || outputHeight > inputTexture.height,
               MTLFXSpatialScalerDescriptor.supportsMetal4FX(device) {
                let desc = MTLFXSpatialScalerDescriptor()
                desc.inputWidth = inputTexture.width
                desc.inputHeight = inputTexture.height
                desc.outputWidth = outputWidth
                desc.outputHeight = outputHeight
                desc.colorTextureFormat = .rgba16Float
                desc.outputTextureFormat = .rgba16Float
                desc.colorProcessingMode = scalerColorMode

                if let s = desc.makeSpatialScaler(device: device, compiler: compiler) {
                    // The scaler waits on this fence before reading its input and
                    // signals it after writing its output (MTLFXSpatialScaler.h:169 —
                    // single fence for untracked resources). It MUST be the same fence
                    // the intake pass updates, otherwise the scaler races the intake
                    // write into linearTexture and samples not-yet-rendered tiles —
                    // black speckle in the not-yet-written region (e.g. bottom of the
                    // frame). Metal 4 command buffers don't auto-track this hazard.
                    s.fence = intakeFence
                    let outDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: outputWidth, height: outputHeight, mipmapped: false)
                    outDesc.usage = s.outputTextureUsage
                    if let outTex = device.makeTexture(descriptor: outDesc) {
                        scaler = (s, outTex)
                    }
                }
            }
        }

        // EWA filter runs whenever we're sampling the source ourselves (i.e. no
        // MetalFX). At ratio == 1 the kernel collapses to its natural support;
        // downscale ratios widen it to low-pass at the output Nyquist. Skip when
        // scaleMode is .off — that path is 1:1 in pixel space and bilinear suffices.
        let useEWA = scaler == nil && scaleMode != .off

        let scalingMode: String
        let outputSize: CGSize
        if scaleMode == .off {
            scalingMode = "No Scaling"
            outputSize = CGSize(width: inputTexture.width, height: inputTexture.height)
        } else if let (_, output) = scaler {
            let upRatio = Double(output.width) / Double(inputTexture.width)
            scalingMode = String(format: "Upscaling %.2fx: MetalFX (filter choice ignored)", upRatio)
            outputSize = CGSize(width: output.width, height: output.height)
        } else {
            let downRatio = max(Double(inputTexture.width) / Double(max(targetSize.width, 1)),
                                Double(inputTexture.height) / Double(max(targetSize.height, 1)))
            let mode = downRatio < 1.0 ? "Upscaling" : (downRatio > 1.0001 ? "Downscaling" : "1:1")
            scalingMode = String(format: "%@ %.2fx: ewa_lanczossharp", mode, downRatio)
            outputSize = targetSize
        }

        if showInfo {
            // EDR headroom is the multiplier above SDR diffuse white (100 nits per
            // CAEDRMetadata.h opticalOutputScale doc) that the OS is currently
            // letting us push — varies live with the brightness slider on XDR
            // displays. Only meaningful when the layer is in HDR mode.
            let edr = view.window?.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0
            let edrLine = isHDR ? String(format: "\nPanel peak: %.0f nits", edr * 100) : ""
            let statsLine = String(format: "\nFPS: %.1f · Dropped: %d", measuredFPS, droppedFrames)
            let engineLine = engine.map { "\nEngine: native MKV · \($0.usingHardwareDecode ? "hardware" : "software") decode" } ?? ""
            let newInfo = "Input: \(inputTexture.width)x\(inputTexture.height)\nOutput: \(Int(outputSize.width))x\(Int(outputSize.height))\n\(scalingMode)\nColorspace: \(colorspaceLabel)\(edrLine)\(statsLine)\(engineLine)"
            if newInfo != info { info = newInfo }
        }

        // Wait for the previous frame's GPU work before mutating shared per-frame state
        // (allocator memory, uniform buffer contents, argumentTable bindings, residencySet).
        if pendingFrameValue > 0 {
            _ = frameEvent.wait(untilSignaledValue: pendingFrameValue, timeoutMS: 1000)
        }

        // Uniforms: quad scale fits the target inside the drawable; ratio is the
        // radial downscale factor for EWA; linearize toggles sRGB↔linear in the kernel.
        let finalQuadScale = SIMD2<Float>(Float(targetSize.width / viewportSize.width),
                                          Float(targetSize.height / viewportSize.height))
        let ratioEWA: Float = useEWA
            ? Float(max(CGFloat(inputTexture.width) / max(targetSize.width, 1.0),
                        CGFloat(inputTexture.height) / max(targetSize.height, 1.0)))
            : 1.0
        // Both EWA and the bilinear blit need the output TF — the final pass to the
        // drawable is the one and only place we re-encode linear → source-TF.
        let tfFlag: Float = Float(transferFunction.rawValue)
        do {
            let p = uniformsBuffer.contents().assumingMemoryBound(to: Float.self)
            p[0] = finalQuadScale.x
            p[1] = finalQuadScale.y
            p[2] = ratioEWA
            p[3] = tfFlag
        }

        residencySet.removeAllAllocations()
        residencySet.addAllocation(yTexture)
        residencySet.addAllocation(cbcrTexture)
        residencySet.addAllocation(linearTexture)
        residencySet.addAllocation(uniformsBuffer)
        residencySet.addAllocation(intakeUniformsBuffer)
        residencySet.addAllocation(kernelLUT)
        if let (_, output) = scaler { residencySet.addAllocation(output) }
        residencySet.commit()

        allocator.reset()
        commandBuffer.beginCommandBuffer(allocator: allocator)
        commandBuffer.useResidencySet(residencySet)

        // Pass A — Intake: YUV planes → linear extended RGB at source resolution.
        // The shader does matrix conversion + Mitchell chroma upsample + TF decode
        // in one pass; everything downstream is in linear light.
        do {
            let intakeDesc = MTL4RenderPassDescriptor()
            intakeDesc.colorAttachments[0].texture = linearTexture
            intakeDesc.colorAttachments[0].loadAction = .dontCare
            intakeDesc.colorAttachments[0].storeAction = .store

            argumentTable.setTexture(yTexture.gpuResourceID, index: 0)
            argumentTable.setTexture(cbcrTexture.gpuResourceID, index: 1)
            argumentTable.setAddress(intakeUniformsBuffer.gpuAddress, index: 0)

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: intakeDesc, options: MTL4RenderEncoderOptions()) else { return }
            encoder.setRenderPipelineState(renderPipelineIntake!)
            encoder.setArgumentTable(argumentTable, stages: [.vertex, .fragment])
            encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 6)
            encoder.updateFence(intakeFence, afterEncoderStages: .fragment)
            encoder.endEncoding()
        }

        // Pass B — MetalFX. Now legitimate `.hdr` mode usage: input texture is
        // linear-extended (MTLFXSpatialScaler.h:19-28 says `.hdr` "indicates your
        // input and output textures use a high dynamic range color space, beyond
        // the [0,1] range").
        if let (s, output) = scaler {
            s.colorTexture = linearTexture
            s.outputTexture = output
            s.inputContentWidth = linearTexture.width
            s.inputContentHeight = linearTexture.height
        }
        scaler?.0.encode(commandBuffer: commandBuffer)

        // Pass C — Final pass to drawable. Either EWA-scale-and-encode in one
        // shader, or bilinear blit + TF encode of the linear/scaled source.
        if useEWA {
            argumentTable.setTexture(linearTexture.gpuResourceID, index: 0)
            argumentTable.setTexture(kernelLUT.gpuResourceID, index: 1)
            argumentTable.setAddress(uniformsBuffer.gpuAddress, index: 0)

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor, options: MTL4RenderEncoderOptions()) else { return }
            encoder.waitForFence(intakeFence, beforeEncoderStages: .fragment)
            encoder.setRenderPipelineState(renderPipelineEWA!)
            encoder.setArgumentTable(argumentTable, stages: [.vertex, .fragment])
            encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 6)
            encoder.endEncoding()
        } else {
            let finalTexture = scaler?.1 ?? linearTexture
            argumentTable.setTexture(finalTexture.gpuResourceID, index: 0)
            argumentTable.setAddress(uniformsBuffer.gpuAddress, index: 0)

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor, options: MTL4RenderEncoderOptions()) else { return }
            // Waiting on intakeFence covers both paths: the intake pass updates it,
            // and (when a scaler ran) the MetalFX scaler re-updates it after writing
            // its output — so this one wait orders the blit after whichever produced
            // the texture we sample below.
            encoder.waitForFence(intakeFence, beforeEncoderStages: .fragment)
            encoder.setRenderPipelineState(renderPipelineBilinear!)
            encoder.setArgumentTable(argumentTable, stages: [.vertex, .fragment])
            encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 6)
            encoder.endEncoding()
        }

        commandBuffer.endCommandBuffer()
        queue.waitForDrawable(drawable)
        queue.commit([commandBuffer], options: nil)
        pendingFrameValue += 1
        queue.signalEvent(frameEvent, value: pendingFrameValue)
        queue.signalDrawable(drawable)
        // Schedule presentation for the predicted vsync. Falls back to ASAP if we
        // haven't received a display-link tick yet (first frame).
        if nextOutputHostTime > 0 {
            drawable.present(at: nextOutputHostTime)
        } else {
            drawable.present()
        }

        // Presented-frame rate over a ~0.5s sliding window.
        let now = CACurrentMediaTime()
        if fpsWindowStart == 0 { fpsWindowStart = now }
        fpsFrameCount += 1
        if now - fpsWindowStart >= 0.5 {
            measuredFPS = Double(fpsFrameCount) / (now - fpsWindowStart)
            fpsFrameCount = 0
            fpsWindowStart = now
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        scaler = nil
    }

    func legibleOutput(_ output: AVPlayerItemLegibleOutput, didOutputAttributedStrings strings: [NSAttributedString], nativeSampleBuffers: [Any], forItemTime itemTime: CMTime) {
        subtitleText = strings.map { $0.string }.joined(separator: "\n")
    }
}
