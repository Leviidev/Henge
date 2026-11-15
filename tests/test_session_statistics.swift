import Foundation

@main struct Check {
    static func main() {
        let sample = SessionStatistics()
        sample.reset(blocks: 100, time: 10)
        sample.sample(blocks: 1100, time: 11)
        precondition(sample.blocksPerSecond == 1000)
        // A delayed observation reports actual elapsed work, not an assumed 1s.
        sample.sample(blocks: 3100, time: 15)
        precondition(sample.blocksPerSecond == 500)
        sample.reset(blocks: UInt64.max - 5, time: 20)
        sample.sample(blocks: 4, time: 21)
        precondition(sample.blocksPerSecond == 0) // a reset, never a 2^64 wrap
        sample.sample(blocks: 14, time: 22)
        precondition(sample.blocksPerSecond == 10)
        sample.reset(blocks: 50, time: 0)
        precondition(sample.blocksPerSecond == 0)
        sample.sample(blocks: 60, time: 0)
        precondition(sample.blocksPerSecond == 0)
        sample.sample(blocks: 70, time: -1)
        precondition(sample.blocksPerSecond == 0)
        sample.sample(blocks: 80, time: .nan)
        precondition(sample.blocksPerSecond == 0)
        sample.sample(blocks: 90, time: .infinity)
        precondition(sample.blocksPerSecond == 0)
        sample.sample(blocks: 100, time: 1)
        precondition(sample.blocksPerSecond == 0)
        sample.sample(blocks: 200, time: 2, epoch: 1)
        precondition(sample.blocksPerSecond == 0)
        sample.sample(blocks: 300, time: 3, epoch: 1)
        precondition(sample.blocksPerSecond == 100)

        var frames = SessionCounter()
        precondition(frames.sample(count: 3871, time: 1, epoch: 1) == nil)
        precondition(frames.sample(count: 0, time: 11, epoch: 2) == nil)
        precondition(frames.sample(count: 4000, time: 12, epoch: 3) == nil)
        let resumed = frames.sample(count: 4200, time: 22, epoch: 3)!
        precondition(resumed.count == 200 && resumed.seconds == 10 && resumed.perSecond == 20)
        // Pause and Continue can both occur while the app task is suspended.
        precondition(frames.sample(count: 4500, time: 287, epoch: 5) == nil)
        let delayed = frames.sample(count: 4700, time: 307, epoch: 5)!
        precondition(delayed.seconds == 20 && delayed.perSecond == 10)
        frames.reset()
        precondition(frames.sample(count: 0, time: 308, epoch: 6) == nil)
        print("PASS session sampling: resets, lifecycle epochs, delayed observations, invalid timestamps and resumed frame deltas")
    }
}
