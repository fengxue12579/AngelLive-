//
//  DeviceName.swift
//  AngelLiveCore
//
//  跨平台返回当前设备的可读名称,供凭证同步、收藏备份等场景标注来源使用。
//

import Foundation
#if os(iOS) || os(tvOS)
import UIKit
#endif

/// 跨平台当前设备名:iOS/tvOS=UIDevice.current.name,macOS=Host.current().localizedName。
public func currentDeviceName() -> String {
    #if os(iOS) || os(tvOS)
    return UIDevice.current.name
    #elseif os(macOS)
    return Host.current().localizedName ?? "Mac"
    #else
    return "Unknown"
    #endif
}
