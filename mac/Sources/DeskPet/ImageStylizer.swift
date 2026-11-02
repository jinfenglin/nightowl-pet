import AppKit
import CoreImage
import Vision

enum StylizeError: LocalizedError {
    case badImage
    case noKey
    case api(String)

    var errorDescription: String? {
        switch self {
        case .badImage: return L("无法读取图片", "Couldn't read the image")
        case .noKey: return L("需要先在设置里配置 API Key", "Set an API key in Settings first")
        case .api(let msg): return msg
        }
    }
}

enum ImageStylizer {
    /// Cartoonize with the configured image model; falls back to a local Core Image
    /// cartoon filter when no API key is set or the request fails.
    /// Returns the result plus an optional warning to show the user.
    static func stylize(_ source: CGImage) async -> (CGImage?, String?) {
        var warning: String?
        if apiKey != nil {
            do {
                return (try await edit(source, prompt: Pref.prompt(for: .normal)), nil)
            } catch {
                warning = L("AI 生成失败（\(error.localizedDescription)），先用本地滤镜凑合一下",
                            "AI generation failed (\(error.localizedDescription)). Using the local filter for now")
            }
        } else {
            warning = L("没配置 API Key，用了本地卡通滤镜。去设置里填 Key 可以生成更好看的形象",
                        "No API key, so I used the local cartoon filter. Add a key in Settings for a much nicer character")
        }
        let local = await Task.detached { localCartoon(source) }.value
        return (local, warning)
    }

    static var provider: ImageProvider {
        ImageProvider(rawValue: UserDefaults.standard.string(forKey: Pref.provider) ?? "") ?? .openAI
    }

    static var apiKey: String? {
        let d = UserDefaults.standard
        let (pref, env) = provider == .gemini ? (Pref.geminiKey, "GEMINI_API_KEY") : (Pref.apiKey, "OPENAI_API_KEY")
        let saved = (d.string(forKey: pref) ?? "").trimmingCharacters(in: .whitespaces)
        let key = saved.isEmpty ? ProcessInfo.processInfo.environment[env] ?? "" : saved
        return key.isEmpty ? nil : key
    }

    /// Redraw the same character in another state, using the normal image as the reference.
    static func variant(of base: CGImage, pose: PetPose) async throws -> CGImage {
        guard pose != .normal else { return base }
        return try await edit(base, prompt: Pref.prompt(for: pose))
    }

    /// Image + prompt → image, or prompt alone → image when `source` is nil.
    static func edit(_ source: CGImage?, prompt: String, size: String = "1024x1024") async throws -> CGImage {
        guard let key = apiKey else { throw StylizeError.noKey }
        let d = UserDefaults.standard
        switch provider {
        case .openAI:
            return try await openAIEdit(source, key: key,
                                        base: d.string(forKey: Pref.apiBase) ?? "https://api.openai.com/v1",
                                        model: d.string(forKey: Pref.imageModel) ?? "gpt-image-1",
                                        prompt: prompt, size: size)
        case .gemini:
            // Gemini can't output transparency: ask for white and key it out locally.
            let whiteBackground = prompt.replacingOccurrences(of: "transparent background", with: "plain solid white background")
            let image = try await geminiEdit(source, key: key,
                                             model: d.string(forKey: Pref.geminiModel) ?? "gemini-2.5-flash-image",
                                             prompt: whiteBackground + " Use a plain, solid pure white background.")
            return removeWhiteBackground(image) ?? image
        }
    }

    /// Generate one effect asset (thrower poses use the idle thrower as their reference).
    static func effect(_ asset: EffectAsset, reference: CGImage?) async throws -> CGImage {
        try await edit(reference, prompt: asset.prompt, size: asset.size)
    }

    /// Honors the proxy from settings, else HTTPS_PROXY (set when launched from a shell).
    private static var session: URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 240
        let saved = (UserDefaults.standard.string(forKey: Pref.proxy) ?? "").trimmingCharacters(in: .whitespaces)
        let env = ProcessInfo.processInfo.environment
        let raw = saved.isEmpty ? (env["HTTPS_PROXY"] ?? env["https_proxy"] ?? "") : saved
        if let url = URL(string: raw.contains("://") ? raw : "http://" + raw), let host = url.host {
            let port = url.port ?? 80
            config.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable: true, kCFNetworkProxiesHTTPProxy: host, kCFNetworkProxiesHTTPPort: port,
                kCFNetworkProxiesHTTPSEnable: true, kCFNetworkProxiesHTTPSProxy: host, kCFNetworkProxiesHTTPSPort: port,
            ]
        }
        return URLSession(configuration: config)
    }

    private static func pngData(_ image: CGImage) throws -> Data {
        guard let png = NSBitmapImageRep(cgImage: downscale(image, maxSide: 1024))
            .representation(using: .png, properties: [:]) else { throw StylizeError.badImage }
        return png
    }

    private static func decodeImage(base64: String?) throws -> CGImage {
        guard let base64, let data = Data(base64Encoded: base64),
              let cg = NSBitmapImageRep(data: data)?.cgImage else {
            throw StylizeError.api(L("返回结果无法解析", "Couldn't parse the response"))
        }
        return cg
    }

    private static func send(_ req: URLRequest, body: Data) async throws -> [String: Any] {
        let (data, response) = try await session.upload(for: req, from: body)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let msg = (json["error"] as? [String: Any])?["message"] as? String
            throw StylizeError.api(msg ?? "HTTP \(status)")
        }
        return json
    }

    // MARK: - OpenAI-compatible /images/edits and /images/generations

    static func openAIEdit(_ source: CGImage?, key: String, base: String, model: String, prompt: String,
                           size: String = "1024x1024") async throws -> CGImage {
        let root = base.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let source else {
            return try await openAIGenerate(root: root, key: key, model: model, prompt: prompt, size: size)
        }
        let png = try pngData(source)
        guard let url = URL(string: root + "/images/edits") else {
            throw StylizeError.api(L("API Base URL 无效", "Invalid API base URL"))
        }

        let boundary = "DeskPet-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("model", model)
        field("prompt", prompt)
        field("size", model.hasPrefix("gpt-image") ? size : "1024x1024")
        if model.hasPrefix("gpt-image") {
            field("background", "transparent")
            field("quality", "medium")
        } else {
            field("response_format", "b64_json")
        }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"pet.png\"\r\nContent-Type: image/png\r\n\r\n".data(using: .utf8)!)
        body.append(png)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        let json = try await send(req, body: body)
        return try decodeImage(base64: (json["data"] as? [[String: Any]])?.first?["b64_json"] as? String)
    }

    private static func openAIGenerate(root: String, key: String, model: String, prompt: String, size: String) async throws -> CGImage {
        guard let url = URL(string: root + "/images/generations") else { throw StylizeError.api(L("API Base URL 无效", "Invalid API base URL")) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = ["model": model, "prompt": prompt, "n": 1]
        if model.hasPrefix("gpt-image") {
            payload["size"] = size
            payload["background"] = "transparent"
            payload["quality"] = "medium"
        } else {
            payload["size"] = "1024x1024"
            payload["response_format"] = "b64_json"
        }
        let json = try await send(req, body: try JSONSerialization.data(withJSONObject: payload))
        return try decodeImage(base64: (json["data"] as? [[String: Any]])?.first?["b64_json"] as? String)
    }

    // MARK: - Google Gemini generateContent (text or image in, image out)

    static func geminiEdit(_ source: CGImage?, key: String, model: String, prompt: String) async throws -> CGImage {
        var parts: [[String: Any]] = [["text": prompt]]
        if let source {
            parts.append(["inline_data": ["mime_type": "image/png", "data": try pngData(source).base64EncodedString()]])
        }
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent") else {
            throw StylizeError.api(L("模型名无效", "Invalid model name"))
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "contents": [["parts": parts]],
            "generationConfig": ["responseModalities": ["TEXT", "IMAGE"]],
        ]
        let json = try await send(req, body: try JSONSerialization.data(withJSONObject: payload))

        let reply = ((json["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        if let inline = reply.lazy.compactMap({ ($0["inlineData"] ?? $0["inline_data"]) as? [String: Any] }).first {
            return try decodeImage(base64: inline["data"] as? String)
        }
        let text = reply.compactMap { $0["text"] as? String }.joined()
        throw StylizeError.api(L("模型没有返回图片", "The model returned no image") + (text.isEmpty ? "" : L("：", ": ") + text.prefix(80)))
    }

    /// Make the near-white background transparent by flood-filling from the borders,
    /// so white areas inside the character are kept.
    static func removeWhiteBackground(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let buffer = ctx.data?.bindMemory(to: UInt8.self, capacity: w * h * 4) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        func isBackground(_ i: Int) -> Bool {
            buffer[i * 4] > 232 && buffer[i * 4 + 1] > 232 && buffer[i * 4 + 2] > 232
        }
        var visited = [Bool](repeating: false, count: w * h)
        var stack: [Int] = []
        for x in 0..<w { stack.append(x); stack.append((h - 1) * w + x) }
        for y in 0..<h { stack.append(y * w); stack.append(y * w + w - 1) }
        while let i = stack.popLast() {
            guard !visited[i], isBackground(i) else { continue }
            visited[i] = true
            buffer[i * 4] = 0; buffer[i * 4 + 1] = 0; buffer[i * 4 + 2] = 0; buffer[i * 4 + 3] = 0
            let x = i % w, y = i / w
            if x > 0 { stack.append(i - 1) }
            if x < w - 1 { stack.append(i + 1) }
            if y > 0 { stack.append(i - w) }
            if y < h - 1 { stack.append(i + w) }
        }
        return ctx.makeImage()
    }

    // MARK: - Local fallback: cut out subject, posterize, ink lines, sticker outline

    static func localCartoon(_ source: CGImage) -> CGImage? {
        let cg = downscale(source, maxSide: 768)
        let input = CIImage(cgImage: cg)
        let extent = input.extent

        let smooth = input.clampedToExtent()
            .applyingFilter("CIMedianFilter")
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.2])
            .cropped(to: extent)
        let flat = smooth
            .applyingFilter("CIColorPosterize", parameters: ["inputLevels": 7])
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.35, kCIInputBrightnessKey: 0.03, kCIInputContrastKey: 1.05,
            ])
        let ink = smooth.applyingFilter("CILineOverlay", parameters: [
            "inputNRNoiseLevel": 0.1, "inputNRSharpness": 0.5,
            "inputEdgeIntensity": 0.9, "inputThreshold": 0.35, "inputContrast": 25,
        ])
        let cartoon = ink.composited(over: flat).cropped(to: extent)

        // Subject cutout when Vision can find one, otherwise a round badge.
        let mask = subjectMask(cg) ?? circleMask(in: extent)
        let pad: CGFloat = 14
        let canvas = extent.insetBy(dx: -pad, dy: -pad)
        let clear = CIImage(color: .clear).cropped(to: canvas)
        let cutout = cartoon.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: mask,
        ])
        let outlineMask = mask.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: 8])
        let white = CIImage(color: .white).cropped(to: canvas)
            .applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: outlineMask,
            ])
        return CIContext().createCGImage(cutout.composited(over: white), from: canvas)
    }

    private static func circleMask(in extent: CGRect) -> CIImage {
        let r = min(extent.width, extent.height) / 2 - 2
        return CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: extent.midX, y: extent.midY),
            "inputRadius0": r - 1, "inputRadius1": r,
            "inputColor0": CIColor.white, "inputColor1": CIColor.black,
        ])!.outputImage!.cropped(to: extent.insetBy(dx: -20, dy: -20))
    }

    private static func subjectMask(_ cg: CGImage) -> CIImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cg)
        guard (try? handler.perform([request])) != nil,
              let result = request.results?.first,
              let buffer = try? result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
        else { return nil }
        return CIImage(cvPixelBuffer: buffer)
    }

    static func downscale(_ cg: CGImage, maxSide: CGFloat) -> CGImage {
        let scale = min(1, maxSide / CGFloat(max(cg.width, cg.height)))
        guard scale < 1 else { return cg }
        let w = Int(CGFloat(cg.width) * scale), h = Int(CGFloat(cg.height) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return cg }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? cg
    }
}
