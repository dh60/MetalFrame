import SwiftUI
import Metal
import MetalKit
import MetalFX
import AVFoundation
import CoreVideo

@main
struct MetalFrame: App {
    var body: some Scene {
        Window("MetalFrame", id: "main") {
            MetalView()
        }
    }
}

struct MetalView: View {
    @StateObject private var renderer = Renderer()
    @State private var mouseHideTimer: Timer?
    @State private var showProgressBar = false
    @State private var isImporting = true

    var body: some View {
        ZStack(alignment: .topLeading) {
            MetalViewRepresentable(renderer: renderer)
                .onContinuousHover { phase in
                    switch phase {
                    case .active:
                        NSCursor.unhide()
                        mouseHideTimer?.invalidate()
                        mouseHideTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in
                            NSCursor.hide()
                        }
                    case .ended:
                        mouseHideTimer?.invalidate()
                        NSCursor.unhide()
                    }
                }
            if renderer.duration > 0 {
                GeometryReader { geo in
                    VStack {
                        Spacer()
                        ZStack(alignment: .bottom) {
                            Color.clear
                            ProgressBar(currentTime: $renderer.currentTime, duration: renderer.duration, onSeek: { time in
                                renderer.seek(to: time)
                            }, isVisible: $showProgressBar)
                            .frame(height: 20)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 10)
                        }
                        .frame(height: geo.size.height * 0.05)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active: showProgressBar = true
                            case .ended: showProgressBar = false
                            }
                        }
                    }
                }
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
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.mpeg4Movie],
            allowsMultipleSelection: false
        ) { result in
            let url = try! result.get()[0]
            renderer.setupVideo(url: url, view: renderer.view!)
        }
        .onOpenURL { url in
            isImporting = false
            renderer.setupVideo(url: url, view: renderer.view!)
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
        .onKeyPress("f") { NSApplication.shared.keyWindow?.toggleFullScreen(nil); return .handled }
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

class Renderer: NSObject, MTKViewDelegate, ObservableObject {
    var device: MTLDevice!
    var queue: MTL4CommandQueue!
    var renderPipeline: MTLRenderPipelineState?
    var allocator: MTL4CommandAllocator!
    var argumentTable: MTL4ArgumentTable!
    var residencySet: MTLResidencySet!
    var scaleBuffer: MTLBuffer!
    var compiler: MTL4Compiler!
    var scaler: (MTL4FXSpatialScaler, MTLTexture)?
    var scalerFence: MTLFence!
    var commandBuffer: MTL4CommandBuffer!
    var player: AVPlayer?
    var playerItem: AVPlayerItem?
    var videoOutput: AVPlayerItemVideoOutput?
    var textureCache: CVMetalTextureCache!
    var texture: MTLTexture?
    weak var view: MTKView?
    var activity: NSObjectProtocol? = ProcessInfo.processInfo.beginActivity(options: .idleDisplaySleepDisabled, reason: "Video playback")
    @Published var info = ""
    @Published var showInfo = false
    @Published var scaleMode: ScaleMode = .fit {
        didSet {
            scaler = nil
        }
    }
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var colorspaceLabel = "sRGB"

    func seek(to time: Double) { player?.seek(to: CMTime(seconds: time, preferredTimescale: 600)) }
    func seek(by seconds: Double) { seek(to: (player?.currentTime().seconds ?? 0) + seconds) }
    func togglePlayback() { player?.rate == 0 ? player?.play() : player?.pause() }

    func setupVideo(url: URL, view: MTKView) {
        device = view.device
        queue = device.makeMTL4CommandQueue()
        compiler = try! device.makeCompiler(descriptor: MTL4CompilerDescriptor())

        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)

        scaler = nil
        view.isPaused = false

        if let metalLayer = view.layer as? CAMetalLayer {
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        }

        let asset = AVURLAsset(url: url)
        playerItem = AVPlayerItem(asset: asset)

        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]

        videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: pixelBufferAttributes)
        playerItem!.add(videoOutput!)

        player = AVPlayer(playerItem: playerItem!)

        Task {
            if let dur = try? await asset.load(.duration) {
                await MainActor.run {
                    self.duration = CMTimeGetSeconds(dur)
                }
            }
            if let tracks = try? await asset.load(.tracks),
               let videoTrack = tracks.first(where: { $0.mediaType == .video }),
               let descs = try? await videoTrack.load(.formatDescriptions) {
                let isHDR = descs.contains { desc in
                    let exts = CMFormatDescriptionGetExtensions(desc) as? [String: Any]
                    let tf = exts?[kCVImageBufferTransferFunctionKey as String] as? String
                    return tf == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
                }
                if isHDR {
                    await MainActor.run {
                        if let metalLayer = view.layer as? CAMetalLayer {
                            metalLayer.wantsExtendedDynamicRangeContent = true
                            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)
                        }
                        self.colorspaceLabel = "BT.2100 PQ"
                    }
                }
            }
        }

        let tableDesc = MTL4ArgumentTableDescriptor()
        tableDesc.maxTextureBindCount = 1
        tableDesc.maxBufferBindCount = 1
        argumentTable = try! device.makeArgumentTable(descriptor: tableDesc)

        scaleBuffer = device.makeBuffer(length: 8, options: .storageModeShared)
        residencySet = try! device.makeResidencySet(descriptor: MTLResidencySetDescriptor())
        allocator = device.makeCommandAllocator()
        scalerFence = device.makeFence()
        commandBuffer = device.makeCommandBuffer()

        let shaderSource = """
            #include <metal_stdlib>
            using namespace metal;
            struct VertexOut { float4 position [[position]]; float2 texCoord; };
            vertex VertexOut vertexShader(uint vid [[vertex_id]], constant float2 &scale [[buffer(0)]]) {
                float2 positions[6] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(-1,1), float2(1,-1), float2(1,1) };
                float2 texCoords[6] = { float2(0,1), float2(1,1), float2(0,0), float2(0,0), float2(1,1), float2(1,0) };
                return { float4(positions[vid] * scale, 0, 1), texCoords[vid] };
            }

            fragment half4 fragmentShader(VertexOut in [[stage_in]], texture2d<half> tex [[texture(0)]]) {
                constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
                return tex.sample(s, in.texCoord);
            }
            """

        let pixelFormat = view.colorPixelFormat
        Task {
            let libDesc = MTL4LibraryDescriptor()
            libDesc.source = shaderSource
            let library = try! await self.compiler.makeLibrary(descriptor: libDesc)

            let pipelineDesc = MTL4RenderPipelineDescriptor()
            pipelineDesc.vertexFunctionDescriptor = {
                let d = MTL4LibraryFunctionDescriptor()
                d.name = "vertexShader"
                d.library = library
                return d
            }()
            pipelineDesc.fragmentFunctionDescriptor = {
                let d = MTL4LibraryFunctionDescriptor()
                d.name = "fragmentShader"
                d.library = library
                return d
            }()
            pipelineDesc.colorAttachments[0].pixelFormat = pixelFormat

            self.renderPipeline = try? await self.compiler.makeRenderPipelineState(descriptor: pipelineDesc)
            self.player?.play()
        }
    }

    func draw(in view: MTKView) {
        guard renderPipeline != nil, let drawable = view.currentDrawable else { return }

        if let output = videoOutput, let item = playerItem {
            currentTime = item.currentTime().seconds
            let time = item.currentTime()
            if output.hasNewPixelBuffer(forItemTime: time),
               let pixelBuffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                var cvMetalTexture: CVMetalTexture?
                CVMetalTextureCacheCreateTextureFromImage(
                    kCFAllocatorDefault, textureCache, pixelBuffer, nil, .rgba16Float,
                    CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer), 0, &cvMetalTexture)
                if let cvTex = cvMetalTexture {
                    texture = CVMetalTextureGetTexture(cvTex)
                }
            }
        }

        guard let inputTexture = texture else { return }

        let viewportSize = CGSize(width: drawable.texture.width, height: drawable.texture.height)
        let imageAspect = CGFloat(inputTexture.width) / CGFloat(inputTexture.height)
        let viewportAspect = viewportSize.width / viewportSize.height

        let targetSize: CGSize
        switch scaleMode {
        case .fit:
            targetSize = imageAspect > viewportAspect
                ? CGSize(width: viewportSize.width, height: viewportSize.width / imageAspect)
                : CGSize(width: viewportSize.height * imageAspect, height: viewportSize.height)
        case .fill:
            targetSize = CGSize(width: viewportSize.height * imageAspect, height: viewportSize.height)
        case .off:
            targetSize = CGSize(width: CGFloat(inputTexture.width), height: CGFloat(inputTexture.height))
        }

        if scaleMode != .off && scaler == nil {
            let (outputWidth, outputHeight) = (Int(targetSize.width), Int(targetSize.height))

            if outputWidth > inputTexture.width || outputHeight > inputTexture.height,
               MTLFXSpatialScalerDescriptor.supportsDevice(device) {
                let desc = MTLFXSpatialScalerDescriptor()
                desc.inputWidth = inputTexture.width
                desc.inputHeight = inputTexture.height
                desc.outputWidth = outputWidth
                desc.outputHeight = outputHeight
                desc.colorTextureFormat = .rgba16Float
                desc.outputTextureFormat = .rgba16Float
                desc.colorProcessingMode = .perceptual

                if let s = desc.makeSpatialScaler(device: device, compiler: compiler) {
                    s.fence = scalerFence
                    let outDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: outputWidth, height: outputHeight, mipmapped: false)
                    outDesc.usage = s.outputTextureUsage
                    if let outTex = device.makeTexture(descriptor: outDesc) {
                        scaler = (s, outTex)
                    }
                }
            }
        }

        if let (s, output) = scaler {
            s.colorTexture = inputTexture
            s.outputTexture = output
            s.inputContentWidth = inputTexture.width
            s.inputContentHeight = inputTexture.height
        }

        let scalingMode: String
        let outputSize: CGSize
        if scaleMode == .off {
            scalingMode = "No Scaling"
            outputSize = CGSize(width: inputTexture.width, height: inputTexture.height)
        } else if let (_, output) = scaler {
            scalingMode = "Upscaling: MetalFX"
            outputSize = CGSize(width: output.width, height: output.height)
        } else {
            scalingMode = "Downscaling: Linear"
            outputSize = targetSize
        }

        info = "Input: \(inputTexture.width)x\(inputTexture.height)\nOutput: \(Int(outputSize.width))x\(Int(outputSize.height))\n\(scalingMode)\nColorspace: \(colorspaceLabel)"

        scaleBuffer.contents()
            .assumingMemoryBound(to: SIMD2<Float>.self)
            .pointee = SIMD2(Float(targetSize.width / viewportSize.width),
                            Float(targetSize.height / viewportSize.height))

        residencySet.removeAllAllocations()
        residencySet.addAllocation(inputTexture)
        residencySet.addAllocation(scaleBuffer)
        if let (_, output) = scaler { residencySet.addAllocation(output) }
        residencySet.commit()

        let finalTexture = scaler?.1 ?? inputTexture

        argumentTable.setTexture(finalTexture.gpuResourceID, index: 0)
        argumentTable.setAddress(scaleBuffer.gpuAddress, index: 0)

        commandBuffer.beginCommandBuffer(allocator: allocator)
        commandBuffer.useResidencySet(residencySet)
        scaler?.0.encode(commandBuffer: commandBuffer)

        let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: view.currentMTL4RenderPassDescriptor!, options: MTL4RenderEncoderOptions())!
        if scaleMode != .off && scaler != nil { encoder.waitForFence(scalerFence, beforeEncoderStages: .fragment) }
        encoder.setRenderPipelineState(renderPipeline!)
        encoder.setArgumentTable(argumentTable, stages: [.vertex, .fragment])
        encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
        commandBuffer.endCommandBuffer()
        queue.waitForDrawable(drawable)
        queue.commit([commandBuffer], options: nil)
        queue.signalDrawable(drawable)
        drawable.present()
        allocator.reset()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        scaler = nil
    }
}