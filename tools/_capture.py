"""Захват окна приложения (только своё окно, без Screen Recording у чужих)."""
import Quartz
from AppKit import NSBitmapImageRep, NSBitmapImageFileTypePNG

def capture_window(pid, path):
    wins = Quartz.CGWindowListCopyWindowInfo(
        Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements,
        Quartz.kCGNullWindowID)
    target, best = None, 0
    for w in wins:
        if w.get('kCGWindowOwnerPID') == pid:
            b = w['kCGWindowBounds']
            area = b['Width'] * b['Height']
            if area > best:
                best, target = area, w
    if not target:
        return False
    wid = target['kCGWindowNumber']
    img = Quartz.CGWindowListCreateImage(
        Quartz.CGRectNull, Quartz.kCGWindowListOptionIncludingWindow, wid,
        Quartz.kCGWindowImageBoundsIgnoreFraming | Quartz.kCGWindowImageNominalResolution)
    if img is None:
        return False
    rep = NSBitmapImageRep.alloc().initWithCGImage_(img)
    data = rep.representationUsingType_properties_(NSBitmapImageFileTypePNG, None)
    return bool(data.writeToFile_atomically_(path, True))
