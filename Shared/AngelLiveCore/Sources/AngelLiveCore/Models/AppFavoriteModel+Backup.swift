//
//  AppFavoriteModel+Backup.swift
//  AngelLiveCore
//
//  收藏备份导入入口。把 FavoriteBackupService.decode 的结果合并进当前收藏列表:
//  按 favoriteUniqueKey 去重(已存在跳过,不覆盖、不删除),新条目逐个 addFavorite。
//

import Foundation

@MainActor
public extension AppFavoriteModel {

    /// 从备份文件原始字节导入收藏。返回详细的 added/skipped/failed 列表给 UI 展示。
    /// 抛错仅限"文件格式完全无法识别"等致命情况,单条加入失败会落到 report.failed,不抛出。
    func importBackup(_ data: Data) async throws -> FavoriteImportReport {
        let decoded = try FavoriteBackupService.decode(data)
        return await merge(rooms: decoded.rooms, decodeFailures: decoded.itemFailures)
    }

    /// 把一批已解析的 LiveModel 合并进当前收藏。重复的 (按 favoriteUniqueKey) 进 skipped,
    /// addFavorite 抛错的进 failed。同一备份内部的重复也会被去重。
    internal func merge(
        rooms: [LiveModel],
        decodeFailures: [FavoriteImportReport.Failure]
    ) async -> FavoriteImportReport {
        var added: [LiveModel] = []
        var skipped: [LiveModel] = []
        var failed: [FavoriteImportReport.Failure] = decodeFailures

        // 用现有收藏的 unique key 集合做基底,同时累加新导入的 key,
        // 这样同一备份里如果有重复条目,只第一条会被加入,其余进 skipped。
        var existingKeys = Set(roomList.map(AppFavoriteModel.favoriteUniqueKey(for:)))

        for room in rooms {
            let key = AppFavoriteModel.favoriteUniqueKey(for: room)
            if existingKeys.contains(key) {
                skipped.append(room)
                continue
            }

            do {
                try await addFavorite(room: room)
                existingKeys.insert(key)
                added.append(room)
            } catch {
                failed.append(FavoriteImportReport.Failure(
                    userName: room.userName.isEmpty ? "(未知主播)" : room.userName,
                    siteId: room.liveType.rawValue,
                    reason: "添加失败:\(error.localizedDescription)"
                ))
            }
        }

        return FavoriteImportReport(added: added, skipped: skipped, failed: failed)
    }
}
