//
//  TermView.swift
//  rTerm
//
//  Created by Ronny Falk on 7/9/24.
//

import MetalKit
import SwiftUI

class RenderCoordinator: NSObject, MTKViewDelegate {
    
    var device: (any MTLDevice)?
    var commandQueue: (any MTLCommandQueue)?
    
    init(device: (any MTLDevice)? = nil) {
        self.device = device ?? MTLCreateSystemDefaultDevice()
        self.commandQueue = device?.makeCommandQueue()
    }
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        
    }
    
    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable, let descriptor = view.currentRenderPassDescriptor, let commandQueue else {
            return
        }
        
        let commandBuffer = commandQueue.makeCommandBuffer()
        let renderEncoder = commandBuffer?.makeRenderCommandEncoder(descriptor: descriptor)
        
        // Calculate content scale factor so CI can render at Retina resolution.
#if os(macOS)
        var contentScale = view.convertToBacking(CGSize(width: 1.0, height: 1.0)).width
#else
        var contentScale = view.contentScaleFactor
#endif
    }
    
    
}

struct TermView: NSViewRepresentable {
        
    func makeCoordinator() -> RenderCoordinator {
        RenderCoordinator()
    }
    
    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.delegate = context.coordinator
        return view
    }
    func updateNSView(_ nsView: MTKView, context: Context) {
        
    }
}

class TermViewController: NSViewController {
    
    var mtkView: MTKView? {
        self.view as? MTKView
    }
    
    let device: (any MTLDevice)?
    var commandQueue: (any MTLCommandQueue)?
    var library: (any MTLLibrary)?
    
    var pipelineState: (any MTLRenderPipelineState)?
    
    init?(device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()) {
        self.device = device
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func loadView() {
        self.view = MTKView(frame: .zero, device: device)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
    }
    
    func configureView() {
        self.commandQueue = device?.makeCommandQueue()
        
        if let library = device?.makeDefaultLibrary(), let pixelFormat = mtkView?.colorPixelFormat {
            
            let vertexFunction = library.makeFunction(name: "vertex_main")
            let fragmentFunction = library.makeFunction(name: "fragment_main")
            
            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.vertexFunction = vertexFunction
            pipelineDescriptor.fragmentFunction = fragmentFunction
            pipelineDescriptor.colorAttachments[0].pixelFormat = pixelFormat
            
            do {
                self.pipelineState = try device?.makeRenderPipelineState(descriptor: pipelineDescriptor, options: [], reflection: nil)
                self.library = library
            } catch {
                print("ERROR:\(error)")
            }
        }
        
        //TODO: else
    }
}

extension TermViewController: MTKViewDelegate {
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
    }
    
    func draw(in view: MTKView) {
    }
}
