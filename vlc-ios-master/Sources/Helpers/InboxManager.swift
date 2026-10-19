/*****************************************************************************
 * InboxManager.swift
 * VLC for iOS
 *****************************************************************************
 * Copyright (c) 2026 VideoLAN. All rights reserved.
 * $Id$
 *
 * Authors: Felix Paul Kühne <fkuehne # videolan.org>
 *
 * Refer to the COPYING file of the official project for license.
 *****************************************************************************/

import Foundation
#if os(iOS)
import UIKit
#endif

class InboxManager {
    private static let moveLock = NSRecursiveLock()
    private static var movedFiles: [URL: URL] = [:]
    private static var documentsURL: URL? {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    private static var inboxURL: URL? {
        return documentsURL?.appendingPathComponent("Inbox", isDirectory: true)
    }

    private static var sharedInboxURL: URL? {
        guard let groupIdentifier = Bundle.main.object(forInfoDictionaryKey: "MLKitGroupIdentifier") as? String,
              let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier) else {
            return nil
        }

        return containerURL.appendingPathComponent("Inbox", isDirectory: true)
    }

    static func isInInbox(_ url: URL) -> Bool {
        guard url.isFileURL, let inboxPath = inboxURL?.resolvingSymlinksInPath().path else {
            return false
        }

        return url.resolvingSymlinksInPath().path.hasPrefix(inboxPath + "/")
    }

    @discardableResult
    static func moveToDocuments(_ url: URL) -> URL? {
        moveLock.lock()
        defer { moveLock.unlock() }
        let source = url.resolvingSymlinksInPath().standardizedFileURL
        if !FileManager.default.fileExists(atPath: source.path),
           let moved = movedFiles[source], FileManager.default.fileExists(atPath: moved.path) {
            return moved
        }
        guard let documentsURL = documentsURL else {
            return nil
        }

        let destination = availableURL(forFileNamed: url.lastPathComponent, in: documentsURL)

        do {
            try FileManager.default.moveItem(at: url, to: destination)
        } catch let error {
            APLog("InboxManager: failed to move \(url.lastPathComponent) to the Documents folder: \(error.localizedDescription)")
            return nil
        }

        movedFiles[source] = destination
        return destination
    }

    static func drainInbox() {
        guard let inboxURL = inboxURL else {
            return
        }

        drain(inboxURL)
    }

    static func drainSharedInbox() {
        guard let sharedInboxURL = sharedInboxURL else {
            return
        }

        drain(sharedInboxURL)
    }

    static func drain(_ folderURL: URL) {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(at: folderURL,
                                                                  includingPropertiesForKeys: nil) else {
            return
        }

        /* the share extension writes to a hidden name while a file is still incomplete */
        for item in contents where !item.lastPathComponent.hasPrefix(".") {
            moveToDocuments(item)
        }

        if let remainder = try? fileManager.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil),
           remainder.isEmpty {
            try? fileManager.removeItem(at: folderURL)
        }
    }

    private static func availableURL(forFileNamed fileName: String, in folderURL: URL) -> URL {
        let fileManager = FileManager.default
        var destination = folderURL.appendingPathComponent(fileName)

        guard fileManager.fileExists(atPath: destination.path) else {
            return destination
        }

        let baseName = (fileName as NSString).deletingPathExtension
        let fileExtension = (fileName as NSString).pathExtension
        var index = 1

        repeat {
            var candidate = "\(baseName)_\(index)"
            if !fileExtension.isEmpty {
                candidate = (candidate as NSString).appendingPathExtension(fileExtension) ?? candidate
            }
            destination = folderURL.appendingPathComponent(candidate)
            index += 1
        } while fileManager.fileExists(atPath: destination.path)

        return destination
    }
}

#if os(iOS)
// A grant belongs to a playback request, not to a view or a picker. Keep it
// alive until LibVLC confirms that the request has stopped using the file.
@objc(RoxyMediaFileAccess)
final class RoxyMediaFileAccess: NSObject {
    @objc private(set) var url: URL
    private var scopedURL: URL?
    private var parentAccess: RoxyMediaFileAccess?
    private let lock = NSLock()
    private static let preparationQueue = DispatchQueue(label: "player.roxy.open-files", qos: .userInitiated)

    private init(url: URL, scopedURL: URL? = nil, parent: RoxyMediaFileAccess? = nil) {
        self.url = url
        self.scopedURL = scopedURL
        parentAccess = parent
        super.init()
    }

    deinit { close() }

    @objc func close() {
        lock.lock()
        let scoped = scopedURL
        scopedURL = nil
        parentAccess = nil
        lock.unlock()
        scoped?.stopAccessingSecurityScopedResource()
    }

    @objc(prepareURLs:completion:)
    static func prepare(urls: [URL], completion: @escaping ([RoxyMediaFileAccess]?, NSError?) -> Void) {
        // false means no grant was acquired; app-owned/Inbox files can still
        // be readable. It must never be used as a reason to reject a file.
        let accesses = urls.map { url in
            RoxyMediaFileAccess(url: url, scopedURL: url.startAccessingSecurityScopedResource() ? url : nil)
        }
        preparationQueue.async {
            do {
                var files: [RoxyMediaFileAccess] = []
                for access in accesses {
                    if InboxManager.isInInbox(access.url) {
                        guard let moved = InboxManager.moveToDocuments(access.url) else {
                            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: access.url.path])
                        }
                        access.url = moved
                    }
                    var coordinationError: NSError?
                    var readError: Error?
                    NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: access.url, options: [], error: &coordinationError) { availableURL in
                        do {
                            let values = try availableURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                            if values.isDirectory == true {
                                let children = try FileManager.default.contentsOfDirectory(at: availableURL,
                                    includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
                                for child in children.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                                    guard (try child.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true,
                                          child.lastPathComponent.isSupportedMediaFormat() || child.lastPathComponent.isSupportedPlaylistFormat() else { continue }
                                    files.append(RoxyMediaFileAccess(url: child, parent: access))
                                }
                            } else {
                                guard values.isRegularFile == true, FileManager.default.isReadableFile(atPath: availableURL.path) else {
                                    throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: availableURL.path])
                                }
                                access.url = availableURL
                                files.append(access)
                            }
                        } catch { readError = error }
                    }
                    if let error = coordinationError ?? (readError as NSError?) { throw error }
                }
                guard !files.isEmpty else {
                    throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "No playable media files were found."])
                }
                DispatchQueue.main.async { completion(files, nil) }
            } catch {
                accesses.forEach { $0.close() }
                DispatchQueue.main.async { completion(nil, error as NSError) }
            }
        }
    }

    @objc(showOpenError:)
    static func showOpenError(_ error: NSError) {
        let alert = UIAlertController(title: NSLocalizedString("PLAYBACK_FAILED", comment: ""),
                                      message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("BUTTON_DISMISS", comment: ""), style: .cancel))
        UIApplication.shared.dismissPresentedScreensAbovePlayer()?.present(alert, animated: true)
    }
}
#endif
