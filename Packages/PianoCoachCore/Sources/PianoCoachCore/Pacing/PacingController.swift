import Foundation

/// Tuning for `PacingController`. Times are in seconds; "lead" is how far the video is ahead of the
/// child on the video timeline.
public struct PacingConfiguration: Sendable, Equatable {
    /// Playback rates the player supports (sorted ascending).
    public var rates: [Double] = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
    /// Slowest rate the coach will use.
    public var minRate: Double = 0.25
    /// Fastest rate the coach will use (1 = never faster than the video's normal speed).
    public var maxRate: Double = 1.0
    /// How far the video may run ahead of the child when all is well.
    public var targetLead: Double = 0.0
    /// Pause when the video gets this far ahead of the child.
    public var pauseLead: Double = 0.8
    /// After pausing for being ahead, resume once the child is this close (and has played again).
    public var resumeLead: Double = 0.3
    /// If the child is this far ahead of the video, jump the video to the child.
    public var seekLag: Double = 2.5
    /// After the follower detects a jump (e.g. starting the measure again), move the video if it is off by more than this.
    public var jumpSeekThreshold: Double = 1.5
    /// If the video is this far ahead of a child who is actively playing (they went back further than
    /// the follower flagged as a jump), move the video back to them.
    public var rewindLead: Double = 3.0
    /// Only seek when the follower is at least this confident.
    public var minConfidenceToSeek: Double = 0.5
    /// Land this far before the child's position when seeking.
    public var seekPreroll: Double = 0.3
    /// Pause after this long without hearing a note (plus the expected gap of a long note).
    public var silenceTimeout: Double = 2.5
    /// Rate correction per second of lead error (keeps the video converging on the child).
    public var correctionGain: Double = 0.4
    /// A new rate must be wanted this long before it is applied (avoids flapping).
    public var rateDwell: Double = 1.2
    /// Minimum time between play/pause commands.
    public var minCommandInterval: Double = 0.4
    /// Minimum time between seeks.
    public var minSeekInterval: Double = 1.5

    public init() {}
}

/// Decides how the video should move so it keeps pace with the child — the "coach".
///
/// Call `update(_:)` about ten times per second with the current player and follower state; apply
/// the returned commands to the player. The controller never resumes a video a person paused.
public final class PacingController {
    public var configuration: PacingConfiguration
    public private(set) var mode: CoachMode = .off
    public private(set) var status: PacingStatus = .idle

    private var activatedAt: Double = -.infinity
    private var lastActivity: Double = -.infinity       // user actions that count like a played note
    private var userPaused = false
    private var waitStarted = false                     // wait-for-me: child has started
    private var coachPausedAt: Double?
    private var lastPlayPause: (command: PlayerCommand, time: Double)?
    private var lastSeekTime: Double = -.infinity
    private var pendingRate: (rate: Double, since: Double)?

    public init(configuration: PacingConfiguration = PacingConfiguration()) {
        self.configuration = configuration
    }

    // MARK: - Control

    /// Switches mode. The coach starts in "waiting for the child to start".
    public func setMode(_ newMode: CoachMode, now: Double) {
        mode = newMode
        activatedAt = now
        userPaused = false
        waitStarted = false
        coachPausedAt = nil
        pendingRate = nil
        lastPlayPause = nil
        status = newMode == .off ? .idle : .waitingToStart
    }

    /// A person paused (button or voice). The coach will not resume until `userDidPlay`.
    public func userDidPause(now: Double) {
        userPaused = true
        coachPausedAt = nil
        pendingRate = nil
        if mode != .off { status = .pausedByUser }
    }

    /// A person pressed play (button or voice).
    public func userDidPlay(now: Double) {
        userPaused = false
        coachPausedAt = nil
        lastActivity = now
        if mode == .waitForMe { waitStarted = true }
        if mode != .off { status = mode == .followMe ? .waitingToStart : .playingAlong(rate: 1) }
    }

    /// The video was moved by a person or a loop; treat it as activity so the coach does not pause at once.
    public func noteUserActivity(now: Double) {
        lastActivity = now
    }

    // MARK: - Update

    public func update(_ input: PacingInput) -> [PlayerCommand] {
        switch mode {
        case .off:
            status = .idle
            return []
        case _ where userPaused:
            status = .pausedByUser
            return []
        case .waitForMe:
            return updateWaitForMe(input)
        case .followMe:
            return updateFollowMe(input)
        }
    }

    private func lastSound(_ input: PacingInput) -> Double {
        max(input.lastOnsetClockTime ?? -.infinity, lastActivity)
    }

    private func updateWaitForMe(_ input: PacingInput) -> [PlayerCommand] {
        let c = configuration
        let now = input.now
        let onsetSinceActivation = (input.lastOnsetClockTime ?? -.infinity) > activatedAt
        if !waitStarted {
            if onsetSinceActivation {
                waitStarted = true
            } else {
                status = .waitingToStart
                return input.videoIsPlaying ? playPause(.pause, now: now) : []
            }
        }
        let silentFor = now - lastSound(input)
        if input.videoIsPlaying {
            if silentFor > c.silenceTimeout {
                coachPausedAt = now
                status = .pausedForSilence
                return playPause(.pause, now: now)
            }
            coachPausedAt = nil
            status = .playingAlong(rate: input.currentRate)
            return []
        }
        // Paused (by the coach, or the player stopped on its own e.g. buffering / end).
        let pausedAt = coachPausedAt ?? (lastPlayPause?.time ?? activatedAt)
        if lastSound(input) > pausedAt && silentFor < c.silenceTimeout {
            coachPausedAt = nil
            status = .playingAlong(rate: input.currentRate)
            return playPause(.play, now: now)
        }
        status = .pausedForSilence
        return []
    }

    private func updateFollowMe(_ input: PacingInput) -> [PlayerCommand] {
        let c = configuration
        let now = input.now
        guard let follower = input.follower, follower.hasStarted, let child = input.childVideoTime else {
            status = .waitingToStart
            return input.videoIsPlaying ? playPause(.pause, now: now) : []
        }
        var commands: [PlayerCommand] = []
        var videoTime = input.videoTime
        var lead = videoTime - child

        // 1. Far off (the child skipped ahead, or started the passage again): move the video to the child.
        let playingNow = now - (input.lastOnsetClockTime ?? -.infinity) < c.silenceTimeout
        if follower.confidence >= c.minConfidenceToSeek, now - lastSeekTime >= c.minSeekInterval,
           lead < -c.seekLag || (follower.jumped && abs(lead) > c.jumpSeekThreshold) || (playingNow && lead > c.rewindLead) {
            let target = max(0, child - c.seekPreroll)
            commands.append(.seek(to: target))
            lastSeekTime = now
            videoTime = target
            lead = videoTime - child
            status = .jumpedToChild
        }

        // 2. Silence: the child stopped playing.
        let silenceLimit = c.silenceTimeout + min(6, input.expectedGapSeconds ?? 0)
        let silentFor = now - lastSound(input)
        let silent = silentFor > silenceLimit

        if input.videoIsPlaying {
            if silent {
                coachPausedAt = now
                status = .pausedForSilence
                return commands + playPause(.pause, now: now)
            }
            if lead > c.pauseLead {
                coachPausedAt = now
                status = .pausedAhead
                return commands + playPause(.pause, now: now)
            }
            commands += rateControl(input, lead: lead, tempoRatio: follower.tempoRatio)
            if case .jumpedToChild = status {} else { status = .playingAlong(rate: currentOrPending(input)) }
            return commands
        }

        // Paused: resume once the child has played since the pause and the video is not ahead.
        let pausedAt = coachPausedAt ?? (lastPlayPause?.time ?? activatedAt)
        let playedSincePause = lastSound(input) > pausedAt
        if !silent && playedSincePause && lead <= c.resumeLead {
            coachPausedAt = nil
            commands += rateControl(input, lead: lead, tempoRatio: follower.tempoRatio)
            status = .playingAlong(rate: currentOrPending(input))
            return commands + playPause(.play, now: now)
        }
        if coachPausedAt == nil { coachPausedAt = pausedAt }
        if case .jumpedToChild = status {} else { status = silent ? .pausedForSilence : .pausedAhead }
        return commands
    }

    // MARK: - Helpers

    private var lastRequestedRate: Double?

    private func currentOrPending(_ input: PacingInput) -> Double {
        lastRequestedRate ?? input.currentRate
    }

    private func rateControl(_ input: PacingInput, lead: Double, tempoRatio: Double?) -> [PlayerCommand] {
        let c = configuration
        guard let ratio = tempoRatio else { return [] }
        let desired = max(c.minRate, min(c.maxRate, ratio * (1 + c.correctionGain * (c.targetLead - lead))))
        let target = quantizedRate(atMost: desired)
        let current = lastRequestedRate ?? input.currentRate
        guard abs(target - current) > 1e-6 else {
            pendingRate = nil
            return []
        }
        let now = input.now
        let bigChange = abs(target - current) >= 0.5 - 1e-9
        if bigChange || (pendingRate.map { abs($0.rate - target) < 1e-6 && now - $0.since >= c.rateDwell } ?? false) {
            pendingRate = nil
            lastRequestedRate = target
            return [.setRate(target)]
        }
        if pendingRate.map({ abs($0.rate - target) > 1e-6 }) ?? true {
            pendingRate = (target, now)
        }
        return []
    }

    /// Largest allowed rate not above `rate` (+ a small tolerance), within min/max.
    func quantizedRate(atMost rate: Double) -> Double {
        let c = configuration
        let allowed = c.rates.filter { $0 >= c.minRate - 1e-9 && $0 <= c.maxRate + 1e-9 }.sorted()
        guard let lowest = allowed.first else { return max(c.minRate, min(c.maxRate, rate)) }
        return allowed.last { $0 <= rate + 0.05 } ?? lowest
    }

    private func playPause(_ command: PlayerCommand, now: Double) -> [PlayerCommand] {
        if let last = lastPlayPause, last.command == command, now - last.time < configuration.minCommandInterval * 3 {
            return []
        }
        if let last = lastPlayPause, now - last.time < configuration.minCommandInterval {
            return []
        }
        lastPlayPause = (command, now)
        return [command]
    }

    /// Tells the controller which rate the player actually applied (the player may round).
    public func playerDidApplyRate(_ rate: Double) {
        lastRequestedRate = rate
    }
}
