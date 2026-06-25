import SwiftUI

struct CustomBlurView: NSViewRepresentable {
    var radius: CGFloat
    var opacity: CGFloat
    var color: NSColor = .black
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = color.withAlphaComponent(opacity).cgColor
        
        if radius > 0 {
            if let blurFilter = CIFilter(name: "CIGaussianBlur") {
                blurFilter.setDefaults()
                blurFilter.setValue(radius, forKey: kCIInputRadiusKey)
                view.layer?.backgroundFilters = [blurFilter]
            }
        }
        
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.layer?.backgroundColor = color.withAlphaComponent(opacity).cgColor
        
        if radius > 0 {
            if let blurFilter = CIFilter(name: "CIGaussianBlur") {
                blurFilter.setDefaults()
                blurFilter.setValue(radius, forKey: kCIInputRadiusKey)
                nsView.layer?.backgroundFilters = [blurFilter]
            }
        } else {
            nsView.layer?.backgroundFilters = []
        }
    }
}
