import Foundation

/// Tap enhancements Android-específicos: `$N`, `label[N]`, Compose clickable parent.
public enum AndroidTapEnhancement {

    public static func execute(args: [String], bridge: any DeviceBridge, start: CFAbsoluteTime) throws {
        let target = args.dropFirst().joined(separator: " ")

        // $N index reference
        if let idx = TargetResolverShared.parseIndex(target) {
            let tree = try bridge.tree()
            let index = ElementIndexShared()
            index.build(from: tree)
            guard let entry = index.get(idx) else {
                print("Index $\(idx) not found (max $\(index.count - 1))")
                return
            }
            let tapTarget = entry.label.isEmpty ? entry.id : entry.label
            try bridge.tap(target: tapTarget)
            print("Tapped $\(idx) '\(tapTarget)' (\(elapsedMs(start))ms)")
            return
        }

        // Label[N] occurrence syntax
        let (label, occurrence) = TargetResolverShared.parse(target)
        if let occ = occurrence {
            let tree = try bridge.tree()
            let matches = TargetResolverShared.findAll(in: tree, matching: label)
            guard let match = matches.first(where: { $0.occurrence == occ }) else {
                print("'\(label)[\(occ)]' not found (\(matches.count) occurrence(s) total)")
                return
            }
            if let frame = match.element["frame"] as? [String: Any],
               let fx = frame["x"] as? Int, let fy = frame["y"] as? Int,
               let fw = frame["width"] as? Int, let fh = frame["height"] as? Int {
                let cx = Double(fx + fw / 2)
                let cy = Double(fy + fh / 2)
                try bridge.tapAtCoordinate(x: cx, y: cy)
            } else {
                let tapLabel = (match.element["title"] as? String) ?? (match.element["label"] as? String) ?? label
                try bridge.tap(target: tapLabel)
            }
            print("Tapped '\(label)[\(occ)]' (\(elapsedMs(start))ms)")
            return
        }

        // Plain label — Compose clickable resolution
        let tree = try bridge.tree()
        let matches = TargetResolverShared.findAll(in: tree, matching: target)
        if let match = matches.first {
            let clickable = AndroidComposeResolver.findClickableFrame(for: match.element, in: tree)
            if clickable != nil {
                fputs("[tap] found Button frame for '\(target)'\n", stderr)
            }
            let tapFrame = clickable ?? match.element["frame"] as? [String: Any]
            if let frame = tapFrame,
               let fx = frame["x"] as? Int, let fy = frame["y"] as? Int,
               let fw = frame["width"] as? Int, let fh = frame["height"] as? Int {
                let cx = Double(fx + fw / 2)
                let cy = Double(fy + fh / 2)
                try bridge.tapAtCoordinate(x: cx, y: cy)
                print("Tapped '\(target)' (\(elapsedMs(start))ms)")
                return
            }
        }
        try bridge.tap(target: target)
        print("Tapped '\(target)' (\(elapsedMs(start))ms)")
    }
}
