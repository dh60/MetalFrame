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

    var body: some View {
        ZStack(alignment: .topLeading) {
            MetalViewRepresentable(renderer: renderer)
            if renderer.showInfo {
                VStack(alignment: .leading) {
                    Text(renderer.info)
                    Toggle("Scaling", isOn: $renderer.scalingEnabled)
                }
                .padding()
                .glassEffect(in: .rect(cornerRadius: 30))
                .padding()
            }
        }
    }
}

struct MetalViewRepresentable: NSViewRepresentable {
    let renderer: Renderer

    func makeCoordinator() -> Renderer { renderer }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.delegate = context.coordinator
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            context.coordinator.handleKey($0)
            return nil
        }
        context.coordinator.view = view

        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.begin { response in
                guard response == .OK, let url = panel.url else {
                    NSApp.terminate(nil)
                    return
                }
                context.coordinator.setupVideo(url: url, view: view)
            }
        }

        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}
}

class Renderer: NSObject, MTKViewDelegate, ObservableObject {
    var device: MTLDevice!
    var queue: MTL4CommandQueue!
    var upscalePipeline: MTLRenderPipelineState?
    var downscalePipeline: MTLRenderPipelineState?
    var allocator: MTL4CommandAllocator!
    var argumentTable: MTL4ArgumentTable!
    var residencySet: MTLResidencySet!
    weak var view: MTKView?
    var scaleBuffer: MTLBuffer!
    var compiler: MTL4Compiler!
    var spatialScaler: MTL4FXSpatialScaler?
    var scalerOutput: MTLTexture?
    var lastViewportSize = CGSize.zero
    var scalerFence: MTLFence!
    var commandBuffer: MTL4CommandBuffer!
    @Published var info = ""
    @Published var showInfo = false
    @Published var scalingEnabled = true

    var player: AVPlayer!
    var playerItem: AVPlayerItem!
    var videoOutput: AVPlayerItemVideoOutput!
    var textureCache: CVMetalTextureCache!
    var videoTexture: MTLTexture?

    func setupVideo(url: URL, view: MTKView) {
        device = view.device
        queue = device.makeMTL4CommandQueue()
        compiler = try! device.makeCompiler(descriptor: MTL4CompilerDescriptor())

        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)

        let asset = AVURLAsset(url: url)
        playerItem = AVPlayerItem(asset: asset)

        Task {
            if let tracks = try? await asset.load(.tracks),
               let videoTrack = tracks.first(where: { $0.mediaType == .video }),
               let formatDescs = try? await videoTrack.load(.formatDescriptions),
               let formatDesc = formatDescs.first as CFTypeRef?,
               let extensions = CMFormatDescriptionGetExtensions(formatDesc as! CMFormatDescription) as? [String: Any],
               let transferFunction = extensions[kCVImageBufferTransferFunctionKey as String] as? String,
               (transferFunction == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String ||
                transferFunction == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String) {
                await MainActor.run {
                    if let metalLayer = view.layer as? CAMetalLayer {
                        metalLayer.wantsExtendedDynamicRangeContent = true
                        if let colorspace = CGColorSpace(name: CGColorSpace.itur_2100_PQ) {
                            metalLayer.colorspace = colorspace
                        }
                    }
                }
            }
        }

        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]

        videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: pixelBufferAttributes)
        playerItem.add(videoOutput)

        player = AVPlayer(playerItem: playerItem)

        let tableDesc = MTL4ArgumentTableDescriptor()
        tableDesc.maxTextureBindCount = 1
        tableDesc.maxBufferBindCount = 1
        argumentTable = try! device.makeArgumentTable(descriptor: tableDesc)

        scaleBuffer = device.makeBuffer(length: 8)
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

            fragment half4 passthroughFragment(VertexOut in [[stage_in]], texture2d<half> tex [[texture(0)]]) {
                constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
                return tex.sample(s, in.texCoord);
            }

            float lanczos(float x, float a) {
                if (x == 0.0) return 1.0;
                if (abs(x) >= a) return 0.0;
                float pi_x = M_PI_F * x;
                return (a * sin(pi_x) * sin(pi_x / a)) / (pi_x * pi_x);
            }

            fragment half4 lanczosFragment(VertexOut in [[stage_in]], texture2d<half> tex [[texture(0)]]) {
                float2 texSize = float2(tex.get_width(), tex.get_height());
                float2 texelPos = in.texCoord * texSize;

                half4 color = half4(0.0);
                float totalWeight = 0.0;

                const int radius = 3;
                for (int y = -radius; y <= radius; y++) {
                    for (int x = -radius; x <= radius; x++) {
                        float2 offset = float2(x, y);
                        float2 centerPos = floor(texelPos) + offset + 0.5;
                        float2 samplePos = centerPos / texSize;
                        float2 delta = texelPos - centerPos;
                        float weight = lanczos(delta.x, 3.0) * lanczos(delta.y, 3.0);

                        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::nearest);
                        color += tex.sample(s, samplePos) * weight;
                        totalWeight += weight;
                    }
                }

                return color / totalWeight;
            }
            """

        device.makeLibrary(source: shaderSource, options: nil) { library, _ in
            guard let library else { return }

            let vertDesc = MTL4LibraryFunctionDescriptor()
            vertDesc.name = "vertexShader"
            vertDesc.library = library

            let passthroughFragDesc = MTL4LibraryFunctionDescriptor()
            passthroughFragDesc.name = "passthroughFragment"
            passthroughFragDesc.library = library

            let lanczosFragDesc = MTL4LibraryFunctionDescriptor()
            lanczosFragDesc.name = "lanczosFragment"
            lanczosFragDesc.library = library

            let upscalePipelineDesc = MTL4RenderPipelineDescriptor()
            upscalePipelineDesc.vertexFunctionDescriptor = vertDesc
            upscalePipelineDesc.fragmentFunctionDescriptor = passthroughFragDesc
            upscalePipelineDesc.colorAttachments[0].pixelFormat = view.colorPixelFormat

            let downscalePipelineDesc = MTL4RenderPipelineDescriptor()
            downscalePipelineDesc.vertexFunctionDescriptor = vertDesc
            downscalePipelineDesc.fragmentFunctionDescriptor = lanczosFragDesc
            downscalePipelineDesc.colorAttachments[0].pixelFormat = view.colorPixelFormat

            Task {
                async let upscale = try self.compiler.makeRenderPipelineState(descriptor: upscalePipelineDesc)
                async let downscale = try self.compiler.makeRenderPipelineState(descriptor: downscalePipelineDesc)

                self.upscalePipeline = try? await upscale
                self.downscalePipeline = try? await downscale
                self.player.play()
            }
        }
    }

    func draw(in view: MTKView) {
        guard upscalePipeline != nil, downscalePipeline != nil, let drawable = view.currentDrawable else { return }

        let time = playerItem.currentTime()
        if videoOutput.hasNewPixelBuffer(forItemTime: time),
           let pixelBuffer = videoOutput.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
            var cvMetalTexture: CVMetalTexture?
            CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, pixelBuffer, nil, .bgra8Unorm,
                CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer), 0, &cvMetalTexture)
            if let cvTex = cvMetalTexture {
                videoTexture = CVMetalTextureGetTexture(cvTex)
            }
        }

        guard let inputTexture = videoTexture else { return }

        let viewportSize = CGSize(width: drawable.texture.width, height: drawable.texture.height)
        let imageAspect = CGFloat(inputTexture.width) / CGFloat(inputTexture.height)
        let viewportAspect = viewportSize.width / viewportSize.height
        let fitSize = imageAspect > viewportAspect
            ? CGSize(width: viewportSize.width, height: viewportSize.width / imageAspect)
            : CGSize(width: viewportSize.height * imageAspect, height: viewportSize.height)

        if scalingEnabled && (spatialScaler == nil || lastViewportSize != viewportSize) {
            lastViewportSize = viewportSize
            let (outputWidth, outputHeight) = (Int(fitSize.width), Int(fitSize.height))

            if outputWidth > inputTexture.width || outputHeight > inputTexture.height,
               MTLFXSpatialScalerDescriptor.supportsDevice(device) {
                let desc = MTLFXSpatialScalerDescriptor()
                desc.inputWidth = inputTexture.width
                desc.inputHeight = inputTexture.height
                desc.outputWidth = outputWidth
                desc.outputHeight = outputHeight
                desc.colorTextureFormat = .bgra8Unorm
                desc.outputTextureFormat = .bgra8Unorm
                desc.colorProcessingMode = .perceptual

                if let scaler = desc.makeSpatialScaler(device: device, compiler: compiler) {
                    scaler.fence = scalerFence
                    spatialScaler = scaler
                    let outDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: outputWidth, height: outputHeight, mipmapped: false)
                    outDesc.usage = scaler.outputTextureUsage
                    scalerOutput = device.makeTexture(descriptor: outDesc)
                }
            } else {
                spatialScaler = nil
                scalerOutput = nil
            }
        } else if !scalingEnabled {
            spatialScaler = nil
            scalerOutput = nil
        }

        if let scaler = spatialScaler, let output = scalerOutput {
            scaler.colorTexture = inputTexture
            scaler.outputTexture = output
            scaler.inputContentWidth = inputTexture.width
            scaler.inputContentHeight = inputTexture.height
        }

        let renderTexture = (scalingEnabled && spatialScaler != nil) ? scalerOutput! : inputTexture
        let pipeline: MTLRenderPipelineState
        let scalingMode: String
        let outputSize: CGSize
        if !scalingEnabled {
            scalingMode = "No Scaling"
            outputSize = CGSize(width: inputTexture.width, height: inputTexture.height)
            pipeline = upscalePipeline!
        } else if spatialScaler != nil {
            scalingMode = "Upscaling: MetalFX"
            outputSize = fitSize
            pipeline = upscalePipeline!
        } else {
            scalingMode = "Downscaling: Lanczos"
            outputSize = fitSize
            pipeline = downscalePipeline!
        }

        info = "Input: \(inputTexture.width)x\(inputTexture.height)\nOutput: \(Int(outputSize.width))x\(Int(outputSize.height))\n\(scalingMode)"

        let scale = scaleBuffer.contents().assumingMemoryBound(to: Float.self)
        if scalingEnabled {
            (scale[0], scale[1]) = (Float(fitSize.width / viewportSize.width), Float(fitSize.height / viewportSize.height))
        } else {
            (scale[0], scale[1]) = (Float(inputTexture.width) / Float(viewportSize.width), Float(inputTexture.height) / Float(viewportSize.height))
        }

        residencySet.removeAllAllocations()
        residencySet.addAllocation(inputTexture)
        residencySet.addAllocation(scaleBuffer)
        if renderTexture !== inputTexture { residencySet.addAllocation(renderTexture) }
        residencySet.commit()

        argumentTable.setTexture(renderTexture.gpuResourceID, index: 0)
        argumentTable.setAddress(scaleBuffer.gpuAddress, index: 0)

        commandBuffer.beginCommandBuffer(allocator: allocator)
        commandBuffer.useResidencySet(residencySet)

        if scalingEnabled { spatialScaler?.encode(commandBuffer: commandBuffer) }

        let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: view.currentMTL4RenderPassDescriptor!, options: MTL4RenderEncoderOptions())!
        if scalingEnabled && spatialScaler != nil { encoder.waitForFence(scalerFence, beforeEncoderStages: .fragment) }
        encoder.setRenderPipelineState(pipeline)
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

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func handleKey(_ event: NSEvent) {
        switch event.keyCode {
        case 53: NSApp.terminate(nil)
        case 34: showInfo.toggle()
        case 49:
            if player.rate == 0 {
                player.play()
            } else {
                player.pause()
            }
        case 123:
            player.seek(to: CMTime(seconds: max(0, player.currentTime().seconds - 10), preferredTimescale: 600))
        case 124:
            player.seek(to: CMTime(seconds: player.currentTime().seconds + 10, preferredTimescale: 600))
        default: ()
        }
    }
}
