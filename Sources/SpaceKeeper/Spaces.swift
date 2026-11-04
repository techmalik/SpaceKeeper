import Cocoa

struct SpaceInfo {
    let id: Int
    let type: Int            // 0 = regular desktop, 4 = full-screen app
    var isUser: Bool { type == 0 }
}

struct DisplaySpaces {
    let uuid: String
    let current: Int
    let spaces: [SpaceInfo]

    var userSpaces: [SpaceInfo] { spaces.filter(\.isUser) }
    var currentIndex: Int? { spaces.firstIndex { $0.id == current } }
    /// 1-based "Desktop N" number of the current space, if it is a regular desktop.
    var currentDesktopNumber: Int? { userSpaces.firstIndex { $0.id == current }.map { $0 + 1 } }
}

enum Spaces {
    static let cid = CGSMainConnectionID()

    static func displays() -> [DisplaySpaces] {
        guard let arr = CGSCopyManagedDisplaySpaces(cid) as? [[String: Any]] else { return [] }
        return arr.compactMap { d in
            guard let uuid = d["Display Identifier"] as? String,
                  let cur = (d["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int,
                  let list = d["Spaces"] as? [[String: Any]] else { return nil }
            let spaces = list.compactMap { s -> SpaceInfo? in
                guard let id = s["ManagedSpaceID"] as? Int else { return nil }
                return SpaceInfo(id: id, type: s["type"] as? Int ?? 0)
            }
            return DisplaySpaces(uuid: uuid, current: cur, spaces: spaces)
        }
    }

    static func currentIDs() -> Set<Int> { Set(displays().map(\.current)) }

    static func spaces(of wid: CGWindowID) -> [Int] {
        (CGSCopySpacesForWindows(cid, 7, [Int(wid)] as CFArray) as? [Int]) ?? []
    }
}
