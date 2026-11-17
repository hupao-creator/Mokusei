import WebKit

enum NativeReportCoverTiming {
    static let dwell = 8.0
    static let hold = 2.0
    static let maximumAnimation = dwell - hold
}

enum NativeReportCoverPlayback: String {
    case reset, playing, playingOnce, paused, reduced

    var isPlaying: Bool { self == .playing || self == .playingOnce }

    @MainActor static let world = WKContentWorld.world(name: "Mokusei.Report.Cover")

    // This controller belongs to the host's isolated world. Author JavaScript
    // stays disabled; only finite CSS effects cross into the playback timeline.
    static let script = """
    (() => {
      const maximum = \(NativeReportCoverTiming.maximumAnimation * 1000);
      const style = document.createElement('style');
      style.textContent = '*,*::before,*::after{animation-play-state:paused!important;transition:none!important}';
      document.head.append(style);
      const effects = document.getAnimations().flatMap(animation => {
        const effect = animation.effect;
        if (!effect) return [];
        const timing = effect.getTiming();
        // An out-of-contract infinite loop still gets one finite iteration.
        // Oversized timelines are accelerated together, preserving choreography.
        effect.updateTiming({iterations: Number.isFinite(timing.iterations) ? timing.iterations : 1, fill:'both'});
        const end = effect.getComputedTiming().endTime;
        if (!Number.isFinite(end)) { animation.cancel(); return []; }
        animation.pause();
        animation.currentTime = 0;
        return [{animation, end:Math.max(0, end)}];
      });
      const authoredEnd = Math.max(0, ...effects.map(item => item.end));
      const duration = Math.min(authoredEnd, maximum);
      const rate = duration > 0 ? authoredEnd / duration : 1;
      for (const {animation} of effects) animation.playbackRate = rate;
      function pose(final) {
        for (const {animation, end} of effects) {
          animation.pause();
          animation.currentTime = final ? end : 0;
        }
      }
      globalThis.mokuseiCover = {
        duration: duration / 1000,
        reset() { pose(false); },
        finish() { pose(true); },
        pause() { for (const {animation} of effects) animation.pause(); },
        play(elapsed) {
          for (const {animation, end} of effects) {
            const time = Math.min(elapsed * 1000, duration) * rate;
            animation.currentTime = Math.min(time, end);
            // play() rewinds a finished effect. Keep shorter siblings complete.
            if (time < end) animation.play();
          }
        }
      };
    })();
    """
}
