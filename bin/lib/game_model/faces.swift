import Vision
import AppKit
// bin/game-model faces: Apple Vision face boxes for each image (macOS only; built by `bin/game-model setup`).
// Usage: faces <image>... ; prints JSON lines: file, w, h, faces[{x,y,w,h (pixels, top-left origin), q, yaw, roll}]
for path in CommandLine.arguments.dropFirst() {
    guard let img = NSImage(contentsOfFile: path),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
    let W = Double(cg.width), H = Double(cg.height)
    let rect = VNDetectFaceRectanglesRequest()
    let qual = VNDetectFaceCaptureQualityRequest()
    let h = VNImageRequestHandler(cgImage: cg)
    try? h.perform([rect])
    let found = rect.results ?? []
    qual.inputFaceObservations = found
    try? h.perform([qual])
    let q = qual.results ?? found
    var arr: [[String: Any]] = []
    for f in q {
        let b = f.boundingBox
        arr.append(["x": Int(b.minX * W), "y": Int((1 - b.maxY) * H), "w": Int(b.width * W), "h": Int(b.height * H),
                    "q": f.faceCaptureQuality ?? -1, "yaw": f.yaw?.doubleValue ?? 0, "roll": f.roll?.doubleValue ?? 0])
    }
    let obj: [String: Any] = ["file": path, "w": Int(W), "h": Int(H), "faces": arr]
    let d = try! JSONSerialization.data(withJSONObject: obj)
    print(String(data: d, encoding: .utf8)!)
}
