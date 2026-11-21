import CoreGraphics
import SpiceKit

/// App presentation policy: at most four heads per channel, backed by one texture.
/// Wire metadata has a separate, larger bound and is never used as an allocation size.
struct MonitorLayout: Equatable {
    struct Head: Equatable {
        let id: UInt32
        let inputID: UInt8
        let crop: CGRect?
        let size: CGSize
    }
    let heads: [Head]
    let usesFallback: Bool
    let acceptsInput: Bool

    init(channel: UInt8, surface: UInt32, width: Int, height: Int, advertised: [MonitorHead]?) {
        let full = Head(id: 0, inputID: channel, crop: nil, size: CGSize(width: width, height: height))
        func fallback() -> Self { Self(heads: [full], usesFallback: true, acceptsInput: advertised == nil) }
        guard width > 0, height > 0 else { self.init(heads: [], usesFallback: false); return }
        guard let advertised else { self = fallback(); return }
        let active = advertised.filter { $0.width != 0 && $0.height != 0 }
        guard active.count <= 4, channel == 0 || active.count <= 1,
              Set(advertised.map(\.monitorID)).count == advertised.count else { self = fallback(); return }
        var result: [Head] = []
        for head in active.sorted(by: { $0.monitorID < $1.monitorID }) {
            // spice-gtk 0.42 get_display_id: monitor ID on channel zero;
            // additional display channels carry only monitor zero.
            guard head.surfaceID == surface, head.width <= 16_384, head.height <= 16_384,
                  head.monitorID <= 255, channel == 0 || head.monitorID == 0 else { self = fallback(); return }
            // A single head's x/y can describe desktop placement, not a crop.
            let x = active.count == 1 ? 0 : UInt64(head.x)
            let y = active.count == 1 ? 0 : UInt64(head.y)
            guard x + UInt64(head.width) <= UInt64(width),
                  y + UInt64(head.height) <= UInt64(height) else { self = fallback(); return }
            let crop = CGRect(x: Int(x), y: Int(y), width: Int(head.width), height: Int(head.height))
            result.append(Head(id: head.monitorID, inputID: channel == 0 ? UInt8(head.monitorID) : channel,
                               crop: crop, size: crop.size))
        }
        self.init(heads: result, usesFallback: false)
    }

    private init(heads: [Head], usesFallback: Bool, acceptsInput: Bool = true) {
        self.heads = heads; self.usesFallback = usesFallback
        self.acceptsInput = acceptsInput && !heads.isEmpty
    }
}
