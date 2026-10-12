//
//  SpatialAudioOutput.swift
//  TomoTV
//
//  APAC alone leaves Apple TV's HDMI output in multichannel PCM; SpatialAudioBridge's
//  AtmosOutputActivator loops a silent Dolby Atmos stream beside it so the receiver switches.
//

import AVFoundation
import Foundation
import SpatialAudioPlayback

/// Follows the players of engine sessions: on Apple TV it keeps the output in Dolby Atmos while the
/// selected audio is spatial, on iPhone and iPad it sends spatial tracks back to FLAC over AirPlay.
public enum SpatialAudioOutput {
    private struct Session {
        var names: Set<String>
        weak var session: RemuxSession?
    }

    private static let lock = NSLock()
    /// Spatial rendition names per session token, as each master named them.
    private static var sessions: [String: Session] = [:]
    /// Players whose AirPlay receiver could not reach the loopback, by follow id.
    private static var external: Set<String> = []
    @MainActor private static var followers: [String: AnyObject] = [:]

    /// A player plays over AirPlay: no session converts until it stops.
    static var externalPlayback: Bool { lock.withLock { !external.isEmpty } }

    /// Follows `player` until `release(id:)`; call from any thread.
    public static func follow(_ player: AVPlayer, id: String) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard #available(macOS 26, iOS 26, tvOS 26, *) else { return }
                #if os(tvOS)
                let activator = AtmosOutputActivator()
                activator.attach(to: player) { playsSpatialAudio($0) }
                (followers.updateValue(activator, forKey: id) as? AtmosOutputActivator)?.detach()
                #else
                followers[id] = player.observe(\.isExternalPlaybackActive, options: [.initial, .new]) { player, _ in
                    externalPlayback(player.isExternalPlaybackActive, id: id, item: player.currentItem)
                }
                #endif
            }
        }
    }

    public static func release(id: String) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard #available(macOS 26, iOS 26, tvOS 26, *) else { return }
                #if os(tvOS)
                (followers.removeValue(forKey: id) as? AtmosOutputActivator)?.detach()
                #else
                (followers.removeValue(forKey: id) as? NSKeyValueObservation)?.invalidate()
                externalPlayback(false, id: id, item: nil)
                #endif
            }
        }
    }

    /// An AirPlay receiver cannot reach the phone's loopback: a session playing spatial audio reopens as FLAC.
    static func externalPlayback(_ active: Bool, id: String, item: AVPlayerItem?) {
        let session: RemuxSession? = lock.withLock {
            if active { external.insert(id) } else { external.remove(id) }
            guard active, let url = (item?.asset as? AVURLAsset)?.url, url.pathComponents.count > 1 else { return nil }
            return sessions[url.pathComponents[1]]?.session
        }
        session?.withdrawSpatialAudio("AirPlay plays this item")
    }

    static func name(_ renditions: Set<String>, session: RemuxSession) {
        lock.withLock { sessions[session.token] = renditions.isEmpty ? nil : Session(names: renditions, session: session) }
    }

    static func forget(token: String) {
        _ = lock.withLock { sessions.removeValue(forKey: token) }
    }

    /// The item is an engine session whose selected audio option, named by its NAME, is spatial.
    /// The selection rather than the playing track, which lags a switch the activator re-checks on.
    static func playsSpatialAudio(_ item: AVPlayerItem) -> Bool {
        guard let url = (item.asset as? AVURLAsset)?.url, url.pathComponents.count > 1,
              let spatial = lock.withLock({ sessions[url.pathComponents[1]]?.names }),
              let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .audible),
              let option = item.currentMediaSelection.selectedMediaOption(in: group) else { return false }
        let title = AVMetadataItem.metadataItems(from: option.commonMetadata, filteredByIdentifier: .commonIdentifierTitle).first?.stringValue
        return title.map(spatial.contains) ?? false
    }
}
