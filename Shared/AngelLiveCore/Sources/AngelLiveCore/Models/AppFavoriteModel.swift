//
//  AppFavoriteModel.swift
//  AngelLiveCore
//
//  Created by pangchong on 10/17/25.
//

import Foundation
import SwiftUI
import CloudKit
import Observation

/// iCloud同步状态
public enum CloudSyncStatus {
    case syncing      // 正在同步
    case success      // 同步成功
    case error        // 同步错误
    case notLoggedIn  // 未登录iCloud
}

@Observable
public final class AppFavoriteModel {
    public let actor = FavoriteStateModel()
    public var groupedRoomList: [FavoriteLiveSectionModel] = []
    public var roomList: [LiveModel] = []
    public var isLoading: Bool = false
    public var cloudKitReady: Bool = false
    public var cloudKitStateString: String = "正在检查iCloud状态"
    public var syncProgressInfo: (String, String, String, Int, Int) = ("", "", "", 0, 0)
    public var cloudReturnError = false
    public var syncStatus: CloudSyncStatus = .syncing
    public var lastSyncTime: Date?
    public var listVersion: Int = 0
    private var isSyncing: Bool = false  // 添加同步状态标记

    public init() {}

    /// 判断是否需要同步数据
    /// - Returns: 如果列表为空或距离上次同步超过1分钟则返回true
    public func shouldSync() -> Bool {
        // 如果列表为空，需要同步
        if roomList.isEmpty {
            return true
        }

        // 如果从未同步过，需要同步
        guard let lastSync = lastSyncTime else {
            return true
        }

        // 如果距离上次同步超过1分钟，需要同步
        let timeInterval = Date().timeIntervalSince(lastSync)
        return timeInterval > 60 // 60秒 = 1分钟
    }

    @MainActor
    public func syncWithActor() async {
        // 防止并发刷新：如果正在同步中，直接返回
        guard !isSyncing else {
            print("正在同步中，忽略此次刷新请求")
            return
        }

        isSyncing = true
        defer { isSyncing = false }  // 确保无论成功或失败都重置状态

        let hasExistingData = !roomList.isEmpty
        // 有旧数据时保留列表，避免整页重建导致滚动卡顿
        if !hasExistingData {
            roomList.removeAll()
            groupedRoomList.removeAll()
        }
        cloudReturnError = false
        syncProgressInfo = ("", "", "", 0, 0)
        // 有旧数据时不显示 loading 骨架屏，保持列表可滚动
        self.isLoading = !hasExistingData
        self.syncStatus = .syncing

        let state = await actor.getState()
        self.cloudKitReady = state.0
        self.cloudKitStateString = state.1

        if self.cloudKitReady {
            do {
                let resp = try await actor.syncStreamerLiveStates()
                self.roomList = resp.0
                self.groupedRoomList = resp.1
                syncProgressInfo = ("", "", "", 0, 0)
                isLoading = false
                syncStatus = .success
                lastSyncTime = Date() // 记录同步时间
                listVersion &+= 1
            } catch {
                self.cloudKitStateString = "获取收藏列表失败：" + FavoriteService.formatErrorCode(error: error)
                syncProgressInfo = ("", "", "", 0, 0)
                isLoading = false
                cloudReturnError = true
                syncStatus = .error
            }
        } else {
            let state = await FavoriteService.getCloudState()
            if state == "无法确定状态" {
                self.cloudKitStateString = "iCloud状态可能存在假登录，当前状态：" + state + "请尝试重新在设置中登录iCloud"
            } else {
                self.cloudKitStateString = state
            }
            syncProgressInfo = ("", "", "", 0, 0)
            isLoading = false
            cloudReturnError = true
            syncStatus = .notLoggedIn
        }
    }

    /// 下拉刷新专用方法 - 不清空数据，保持 List 结构稳定
    @MainActor
    public func pullToRefresh() async {
        // 防止并发刷新
        guard !isSyncing else {
            print("正在同步中，忽略此次刷新请求")
            return
        }

        isSyncing = true
        defer { isSyncing = false }

        // 不清空数据，不改变 isLoading 状态
        self.syncStatus = .syncing

        let state = await actor.getState()
        self.cloudKitReady = state.0
        self.cloudKitStateString = state.1

        if self.cloudKitReady {
            do {
                let resp = try await actor.syncStreamerLiveStates()
                // 直接更新数据，不清空
                self.roomList = resp.0
                self.groupedRoomList = resp.1
                syncStatus = .success
                lastSyncTime = Date()
                listVersion &+= 1
            } catch {
                self.cloudKitStateString = "获取收藏列表失败：" + FavoriteService.formatErrorCode(error: error)
                cloudReturnError = true
                syncStatus = .error
            }
        } else {
            let state = await FavoriteService.getCloudState()
            if state == "无法确定状态" {
                self.cloudKitStateString = "iCloud状态可能存在假登录，当前状态：" + state + "请尝试重新在设置中登录iCloud"
            } else {
                self.cloudKitStateString = state
            }
            cloudReturnError = true
            syncStatus = .notLoggedIn
        }
    }

    @MainActor
    public func addFavorite(room: LiveModel) async throws {
        if roomList.contains(where: { AppFavoriteModel.favoriteUniqueKey(for: $0) == AppFavoriteModel.favoriteUniqueKey(for: room) }) {
            return
        }

        let consoleEntryId = PluginConsoleService.shared.log(tag: "Favorite", method: "addFavorite", status: .loading)
        PluginConsoleService.shared.updateRequest(id: consoleEntryId, body: AppFavoriteModel.consoleRequestBody(for: room))
        let consoleStart = Date()

        do {
            try await FavoriteService.saveRecord(liveModel: room)
        } catch {
            PluginConsoleService.shared.updateStatus(
                id: consoleEntryId,
                status: .error,
                duration: Date().timeIntervalSince(consoleStart),
                errorMessage: AppFavoriteModel.consoleErrorMessage(for: error)
            )
            throw error
        }
        // 查找第一个非直播状态的房间位置
        var favIndex = -1
        for (index, favoriteRoom) in roomList.enumerated() {
            if LiveState(rawValue: favoriteRoom.liveState ?? "3") != .live {
                favIndex = index
                break
            }
        }

        // 插入到合适的位置
        if favIndex != -1 {
            roomList.insert(room, at: favIndex)
        } else {
            // 如果所有房间都在直播，则添加到末尾
            roomList.append(room)
        }

        // 更新分组列表
        if AngelLiveFavoriteStyle(rawValue: GeneralSettingModel().globalGeneralSettingFavoriteStyle) == .section {
            // 按平台分组
            var found = false
            for (index, model) in groupedRoomList.enumerated() {
                if model.type == room.liveType {
                    groupedRoomList[index].roomList.append(room)
                    found = true
                    break
                }
            }
            // 如果没有找到对应平台的分组，创建新分组
            if !found {
                var newSection = FavoriteLiveSectionModel()
                newSection.roomList = [room]
                newSection.title = LiveParseTools.getLivePlatformName(room.liveType)
                newSection.type = room.liveType
                groupedRoomList.append(newSection)
            }
        } else {
            // 按直播状态分组
            var found = false
            for (index, model) in groupedRoomList.enumerated() {
                if model.title == room.liveStateFormat() {
                    groupedRoomList[index].roomList.append(room)
                    found = true
                    break
                }
            }
            // 如果没有找到对应状态的分组，创建新分组
            if !found {
                var newSection = FavoriteLiveSectionModel()
                newSection.roomList = [room]
                newSection.title = room.liveStateFormat()
                newSection.type = room.liveType
                groupedRoomList.append(newSection)
            }
        }
        listVersion &+= 1
        PluginConsoleService.shared.updateStatus(
            id: consoleEntryId,
            status: .success,
            duration: Date().timeIntervalSince(consoleStart),
            responseBody: AppFavoriteModel.consoleSuccessSummary(verb: "已收藏", room: room, totalCount: roomList.count)
        )
    }

    @MainActor
    public func removeFavoriteRoom(room: LiveModel) async throws {
        let consoleEntryId = PluginConsoleService.shared.log(tag: "Favorite", method: "removeFavoriteRoom", status: .loading)
        PluginConsoleService.shared.updateRequest(id: consoleEntryId, body: AppFavoriteModel.consoleRequestBody(for: room))
        let consoleStart = Date()

        do {
            try await FavoriteService.deleteRecord(liveModel: room)
        } catch {
            PluginConsoleService.shared.updateStatus(
                id: consoleEntryId,
                status: .error,
                duration: Date().timeIntervalSince(consoleStart),
                errorMessage: AppFavoriteModel.consoleErrorMessage(for: error)
            )
            throw error
        }

        let targetKey = AppFavoriteModel.favoriteUniqueKey(for: room)
        // 从 roomList 中删除
        roomList.removeAll(where: { AppFavoriteModel.favoriteUniqueKey(for: $0) == targetKey })

        // 从 groupedRoomList 中删除
        for index in groupedRoomList.indices {
            groupedRoomList[index].roomList.removeAll(where: { AppFavoriteModel.favoriteUniqueKey(for: $0) == targetKey })
        }
        groupedRoomList.removeAll(where: { $0.roomList.isEmpty })
        listVersion &+= 1
        PluginConsoleService.shared.updateStatus(
            id: consoleEntryId,
            status: .success,
            duration: Date().timeIntervalSince(consoleStart),
            responseBody: AppFavoriteModel.consoleSuccessSummary(verb: "已取消收藏", room: room, totalCount: roomList.count)
        )
    }

    /// 构造统一的控制台请求摘要,用于开发者面板查看本次收藏操作针对哪个房间。
    private static func consoleRequestBody(for room: LiveModel) -> String {
        let platform = room.liveType.rawValue
        let userId = room.userId.isEmpty ? "-" : room.userId
        let roomId = room.roomId.isEmpty ? "-" : room.roomId
        let userName = room.userName.isEmpty ? "-" : room.userName
        let roomTitle = room.roomTitle.isEmpty ? "-" : room.roomTitle
        return """
        platform: \(platform)
        userId: \(userId)
        roomId: \(roomId)
        userName: \(userName)
        roomTitle: \(roomTitle)
        """
    }

    /// 控制台成功面板:把操作结果(收藏/取消)+ 房间识别信息 + 当前收藏总数都打出来。
    private static func consoleSuccessSummary(verb: String, room: LiveModel, totalCount: Int) -> String {
        let platformName = LiveParseTools.getLivePlatformName(room.liveType)
        let userName = room.userName.isEmpty ? "-" : room.userName
        let identity: String
        if !room.userId.isEmpty {
            identity = "userId=\(room.userId)"
        } else if !room.roomId.isEmpty {
            identity = "roomId=\(room.roomId)"
        } else {
            identity = "name=\(userName)"
        }
        return """
        result: \(verb)
        platform: \(platformName)
        target: \(userName) (\(identity))
        currentFavoriteCount: \(totalCount)
        """
    }

    /// 控制台错误面板:既给出格式化的错误码,也保留原始 error 描述,方便排查。
    private static func consoleErrorMessage(for error: Error) -> String {
        let formatted = FavoriteService.formatErrorCode(error: error)
        let raw = error.localizedDescription
        if formatted == raw {
            return formatted
        }
        return """
        \(formatted)
        ── raw ──
        \(raw)
        """
    }

    public func refreshView() {
        // 触发 Observation 更新
        let theRoomList = roomList
        roomList.removeAll()
        roomList = theRoomList
        
        // 使用抽取的分组方法，消除重复代码
        let style = AngelLiveFavoriteStyle(rawValue: GeneralSettingModel().globalGeneralSettingFavoriteStyle) ?? .liveState
        self.groupedRoomList = roomList.groupedBySections(style: style)
        listVersion &+= 1
    }
}

extension AppFavoriteModel {
    static func favoriteUniqueKey(for room: LiveModel) -> String {
        let liveType = room.liveType.rawValue
        let userId = room.userId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !userId.isEmpty {
            return "\(liveType)_u_\(userId)"
        }
        let roomId = room.roomId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !roomId.isEmpty {
            return "\(liveType)_r_\(roomId)"
        }
        return "\(liveType)_n_\(room.userName.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}
