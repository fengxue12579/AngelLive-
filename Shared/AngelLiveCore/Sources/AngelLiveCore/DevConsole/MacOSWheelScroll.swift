//
//  MacOSWheelScroll.swift
//  AngelLiveCore
//
//  macOS 上 SwiftUI 的 ScrollView(.horizontal) 默认只响应 Shift+滚轮 或 触控板水平手势,
//  普通鼠标滚轮(只有垂直 delta)不会被横向 ScrollView 接收。
//  这里挂一个透明 NSView 在 ScrollView 内部,拦截 scrollWheel,
//  把鼠标垂直滚轮的 delta 翻译成 NSScrollView 内容横向偏移。
//

import SwiftUI

public extension View {
    /// 让横向 SwiftUI ScrollView 在 macOS 上能用鼠标垂直滚轮滚动。其它端 no-op。
    @ViewBuilder
    func enableMacHorizontalWheelScroll() -> some View {
        #if os(macOS)
        self.background(MacHorizontalWheelScrollCatcher())
        #else
        self
        #endif
    }
}

#if os(macOS)
import AppKit

private struct MacHorizontalWheelScrollCatcher: NSViewRepresentable {
    func makeNSView(context: Context) -> WheelCatcherView { WheelCatcherView() }
    func updateNSView(_ nsView: WheelCatcherView, context: Context) {}
}

private final class WheelCatcherView: NSView {
    override func scrollWheel(with event: NSEvent) {
        guard let scrollView = enclosingScrollView else {
            super.scrollWheel(with: event)
            return
        }

        // 触控板(hasPreciseScrollingDeltas) 或者已经带横向 delta 的事件,原样让系统处理。
        // 只拦截普通鼠标滚轮(精确 delta = false,且 X 方向无信号)。
        if event.hasPreciseScrollingDeltas || event.scrollingDeltaX != 0 {
            super.scrollWheel(with: event)
            return
        }
        guard event.scrollingDeltaY != 0 else {
            super.scrollWheel(with: event)
            return
        }

        // 把垂直 delta 翻译成 contentView 的水平位移。
        // 鼠标滚轮 Y 滚动一次 deltaY ≈ 1,这里乘 24 让单次滚动有可察觉的位移。
        let clipView = scrollView.contentView
        let documentBounds = scrollView.documentView?.bounds ?? clipView.bounds
        var origin = clipView.bounds.origin
        let step = event.scrollingDeltaY * 24
        origin.x = max(0, min(documentBounds.width - clipView.bounds.width, origin.x - step))
        clipView.scroll(to: origin)
        scrollView.reflectScrolledClipView(clipView)
    }
}
#endif
