import Cocoa
import ApplicationServices

// Private CoreGraphics / Accessibility symbols. These are read-only queries
// (which Space a window lives on); moving windows is done by WindowMover.
@_silgen_name("CGSMainConnectionID") func CGSMainConnectionID() -> Int32
@_silgen_name("CGSCopyManagedDisplaySpaces") func CGSCopyManagedDisplaySpaces(_ cid: Int32) -> CFArray
@_silgen_name("CGSCopySpacesForWindows") func CGSCopySpacesForWindows(_ cid: Int32, _ mask: Int32, _ wids: CFArray) -> CFArray
@_silgen_name("_AXUIElementGetWindow") func _AXUIElementGetWindow(_ el: AXUIElement, _ out: UnsafeMutablePointer<CGWindowID>) -> AXError
