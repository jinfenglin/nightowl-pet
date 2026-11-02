import AppKit

extension PetStore {
    /// Turn a photo into the normal pose; with an API key, chain the other poses too.
    func createCharacter(from photo: CGImage) async {
        isBusy = true
        say(L("正在把照片变成卡通形象，稍等一下…", "Turning your photo into a cartoon, hang on…"), seconds: 600)
        let (result, warning) = await ImageStylizer.stylize(photo)
        isBusy = false
        guard let result else {
            say(L("生成失败了… 换张图试试？", "Generation failed… try another photo?"), seconds: 6)
            return
        }
        // The old poses belong to the previous character.
        PetPose.variants.forEach(removeImage)
        setImage(NSImage(cgImage: result, size: NSSize(width: result.width, height: result.height)))
        if let warning {
            say(warning, seconds: 10)
        } else {
            await generatePoses(only: PetPose.variants)
        }
    }

    /// Generate pose variants from the current normal image, in parallel.
    func generatePoses(only poses: [PetPose] = PetPose.variants) async {
        guard let base = petImage?.cgImage else {
            say(L("先选一张形象图片吧", "Pick a character image first"), seconds: 5)
            return
        }
        guard ImageStylizer.apiKey != nil else {
            say(L("生成状态图需要先在设置里配置 API Key（也可以在设置里手动导入）",
                  "Generating poses needs an API key in Settings (or import images there yourself)"), seconds: 8)
            return
        }

        isBusy = true
        let names = poses.map(\.title).joined(separator: " / ")
        say(L("正在生成 \(names) 状态图…", "Generating \(names)…"), seconds: 600)
        var failures: [String] = []
        await withTaskGroup(of: (PetPose, CGImage?, String?).self) { group in
            for pose in poses {
                group.addTask {
                    do {
                        return (pose, try await ImageStylizer.variant(of: base, pose: pose), nil)
                    } catch {
                        return (pose, nil, error.localizedDescription)
                    }
                }
            }
            for await (pose, image, error) in group {
                if let image {
                    setImage(NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)), for: pose)
                } else {
                    failures.append("\(pose.title)\(L("：", ": "))\(error ?? L("未知错误", "unknown error"))")
                }
            }
        }
        isBusy = false
        say(failures.isEmpty ? L("状态图生成好了！试试攻击看看效果 😈", "Poses ready! Try an attack to see them 😈")
                : L("部分状态图生成失败 — ", "Some poses failed — ") + failures.joined(separator: L("；", "; ")),
            seconds: failures.isEmpty ? 6 : 12)
    }
}

extension PetStore {
    /// Generate effect art. Independent assets go in parallel; the thrower's toss / throw poses
    /// wait for the idle pose (generated first if missing) so all three are the same character.
    func generateEffects(only assets: [EffectAsset] = EffectAsset.allCases) async {
        guard ImageStylizer.apiKey != nil else {
            say(L("生成特效素材需要先在设置里配置 API Key（也可以复制提示词去网页版生成后导入）",
                  "Generating effect art needs an API key in Settings (or copy the prompt to a web app and import the result)"), seconds: 8)
            return
        }
        isBusy = true
        say(L("正在生成特效素材：", "Generating effect art: ") + assets.map(\.title).joined(separator: " / ") + "…", seconds: 900)

        let needsIdle = assets.contains { $0.reference == .throwerIdle } && effects[.throwerIdle] == nil
        let firstWave = assets.filter { $0.reference == nil } + (needsIdle && !assets.contains(.throwerIdle) ? [.throwerIdle] : [])
        var failures = await generateWave(firstWave, reference: nil)

        let posed = assets.filter { $0.reference != nil }
        if !posed.isEmpty {
            if let idle = effects[.throwerIdle]?.cgImage {
                failures += await generateWave(posed, reference: idle)
            } else {
                failures += posed.map { "\($0.title)\(L("：需要先有「", ": needs \u{201C}"))\(EffectAsset.throwerIdle.title)\(L("」", "\u{201D} first"))" }
            }
        }
        isBusy = false
        say(failures.isEmpty ? L("特效素材生成好了！试一下攻击看看 ✨", "Effect art ready! Try an attack ✨")
                : L("部分素材生成失败 — ", "Some art failed — ") + failures.joined(separator: L("；", "; ")),
            seconds: failures.isEmpty ? 6 : 12)
    }

    private func generateWave(_ assets: [EffectAsset], reference: CGImage?) async -> [String] {
        var failures: [String] = []
        await withTaskGroup(of: (EffectAsset, CGImage?, String?).self) { group in
            for asset in assets {
                group.addTask {
                    do {
                        return (asset, try await ImageStylizer.effect(asset, reference: reference), nil)
                    } catch {
                        return (asset, nil, error.localizedDescription)
                    }
                }
            }
            for await (asset, image, error) in group {
                if let image {
                    setEffect(NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)), for: asset)
                } else {
                    failures.append("\(asset.title)\(L("：", ": "))\(error ?? L("未知错误", "unknown error"))")
                }
            }
        }
        return failures
    }
}
