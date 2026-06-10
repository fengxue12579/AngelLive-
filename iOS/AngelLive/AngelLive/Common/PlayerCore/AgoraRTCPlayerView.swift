//
//  AgoraRTCPlayerView.swift
//  AngelLive
//
//  用于播放插件返回的 Agora RTC 房间。
//  插件通过 headers 传入 X-Agora-* 参数；普通 m3u8/flv/ts 仍走原播放器。
//

import SwiftUI
import AngelLiveCore

#if canImport(AgoraRtcKit)
import AgoraRtcKit
#endif

struct AgoraRTCPlayerView: View {
    let quality: LiveQualityDetail

    var body: some View {
        #if canImport(AgoraRtcKit)
        AgoraRTCUIKitPlayerView(quality: quality)
            .background(Color.black)
        #else
        ZStack {
            Color.black
            VStack(spacing: 10) {
                ProgressView()
                    .tint(.white)
                Text("需要集成 AgoraRtcEngine_iOS SDK")
                    .foregroundStyle(.white)
                    .font(.footnote)
                Text("请在 Xcode 添加 Swift Package：AgoraIO/AgoraRtcEngine_iOS，并选择 RtcBasic")
                    .foregroundStyle(.white.opacity(0.75))
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        #endif
    }
}

#if canImport(AgoraRtcKit)
private struct AgoraRTCUIKitPlayerView: UIViewRepresentable {
    let quality: LiveQualityDetail

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        context.coordinator.start(quality: quality, renderView: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.update(quality: quality, renderView: uiView)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, AgoraRtcEngineDelegate {
        private var engine: AgoraRtcEngineKit?
        private var currentKey: String?
        private weak var renderView: UIView?

        func update(quality: LiveQualityDetail, renderView: UIView) {
            let key = Self.key(for: quality)
            guard key != currentKey else { return }
            stop()
            start(quality: quality, renderView: renderView)
        }

        func start(quality: LiveQualityDetail, renderView: UIView) {
            guard
                let headers = quality.headers,
                let appId = headers["X-Agora-AppId"],
                let channel = headers["X-Agora-Channel"],
                let token = headers["X-Agora-Token"],
                let uidString = headers["X-Agora-Uid"],
                let uid = UInt(uidString)
            else {
                Logger.debug("[AgoraRTC] 参数缺失，无法加入频道", category: .player)
                return
            }

            self.renderView = renderView
            self.currentKey = Self.key(for: quality)

            let engine = AgoraRtcEngineKit.sharedEngine(withAppId: appId, delegate: self)
            self.engine = engine

            engine.setChannelProfile(.liveBroadcasting)
            engine.setClientRole(.audience)
            engine.enableVideo()
            engine.enableAudio()

            Logger.debug("[AgoraRTC] join channel=\(channel), uid=\(uid)", category: .player)
            engine.joinChannel(byToken: token, channelId: channel, info: nil, uid: uid) { channel, uid, elapsed in
                Logger.debug("[AgoraRTC] joined channel=\(channel), uid=\(uid), elapsed=\(elapsed)", category: .player)
            }
        }

        func stop() {
            guard let engine else { return }
            Logger.debug("[AgoraRTC] leave channel", category: .player)
            engine.leaveChannel(nil)
            AgoraRtcEngineKit.destroy()
            self.engine = nil
            self.currentKey = nil
        }

        func rtcEngine(_ engine: AgoraRtcEngineKit, didJoinedOfUid uid: UInt, elapsed: Int) {
            Logger.debug("[AgoraRTC] remote joined uid=\(uid)", category: .player)
            guard let renderView else { return }

            let canvas = AgoraRtcVideoCanvas()
            canvas.uid = uid
            canvas.view = renderView
            canvas.renderMode = .fit
            engine.setupRemoteVideo(canvas)
        }

        func rtcEngine(_ engine: AgoraRtcEngineKit, didOfflineOfUid uid: UInt, reason: AgoraUserOfflineReason) {
            Logger.debug("[AgoraRTC] remote offline uid=\(uid), reason=\(reason.rawValue)", category: .player)
        }

        private static func key(for quality: LiveQualityDetail) -> String {
            let headers = quality.headers ?? [:]
            return [
                headers["X-Agora-AppId"] ?? "",
                headers["X-Agora-Channel"] ?? "",
                headers["X-Agora-Token"] ?? "",
                headers["X-Agora-Uid"] ?? ""
            ].joined(separator: "|")
        }
    }
}
#endif
