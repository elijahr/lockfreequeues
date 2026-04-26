## Audio Buffer Example
##
## Demonstrates using a bounded Sipsic (SPSC) queue for real-time audio processing.
## The producer thread captures audio samples, the consumer thread plays them.
##
## Key properties:
## - Fixed latency: buffer size determines latency (64 samples @ 44.1kHz = 1.45ms)
## - No allocation: ring buffer operations never allocate
## - Wait-free: both push and pop complete in bounded time
##
## This pattern is essential for audio applications where:
## - Latency must be predictable and minimal
## - Glitches from GC pauses or allocation are unacceptable
## - Sample rate is fixed and known

import lockfreequeues/atomic_dsl
import math
import os
import options

import lockfreequeues

const
  SampleRate = 44100
  BufferSize = 64  # ~1.45ms latency at 44.1kHz
  DurationMs = 100  # Simulate 100ms of audio

type
  AudioSample = object
    left: float32
    right: float32
    timestamp: int64

var
  queue = initSipsic[BufferSize, AudioSample]()
  running: Atomic[bool]
  samplesProduced: Atomic[int]
  samplesConsumed: Atomic[int]
  underruns: Atomic[int]  # Consumer needed data but queue was empty
  overruns: Atomic[int]   # Producer couldn't push because queue was full


proc captureThread() {.thread.} =
  ## Simulates audio capture hardware filling the buffer.
  ## In a real application, this would be driven by hardware interrupts.
  var sampleIndex = 0
  let totalSamples = (SampleRate * DurationMs) div 1000

  while sampleIndex < totalSamples:
    # Generate a simple sine wave (440Hz tone)
    let t = float32(sampleIndex) / float32(SampleRate)
    let value = sin(t * 440.0 * 2.0 * PI).float32 * 0.5

    let sample = AudioSample(
      left: value,
      right: value,
      timestamp: sampleIndex
    )

    if queue.push(sample):
      discard samplesProduced.fetchAdd(1, moRelaxed)
      inc sampleIndex
    else:
      # Buffer full - would cause overrun in real audio
      discard overruns.fetchAdd(1, moRelaxed)
      # In real audio, we'd drop the sample or wait for hardware timing
      sleep(0)  # Yield to let consumer catch up

  running.store(false, moRelease)


proc playbackThread() {.thread.} =
  ## Simulates audio playback hardware draining the buffer.
  ## In a real application, this would be driven by hardware interrupts.

  while running.load(moAcquire) or queue.pop().isSome:
    let sample = queue.pop()

    if sample.isSome:
      # In a real application, send to DAC
      discard samplesConsumed.fetchAdd(1, moRelaxed)
    else:
      # Buffer empty - would cause underrun (glitch) in real audio
      discard underruns.fetchAdd(1, moRelaxed)

    # Simulate playback timing (~22.7us per sample at 44.1kHz)
    # In reality, hardware timing drives this
    sleep(0)


when isMainModule:
  echo "Audio Buffer Example"
  echo "===================="
  echo "Buffer size: ", BufferSize, " samples"
  echo "Latency: ", (BufferSize * 1000) div SampleRate, "ms"
  echo "Duration: ", DurationMs, "ms"
  echo ""

  running.store(true, moRelease)
  samplesProduced.store(0, moRelaxed)
  samplesConsumed.store(0, moRelaxed)
  underruns.store(0, moRelaxed)
  overruns.store(0, moRelaxed)

  var threads: array[2, Thread[void]]
  threads[0].createThread(captureThread)
  threads[1].createThread(playbackThread)

  joinThreads(threads)

  echo "Results:"
  echo "  Samples produced: ", samplesProduced.load(moRelaxed)
  echo "  Samples consumed: ", samplesConsumed.load(moRelaxed)
  echo "  Underruns: ", underruns.load(moRelaxed)
  echo "  Overruns: ", overruns.load(moRelaxed)

  let produced = samplesProduced.load(moRelaxed)
  let consumed = samplesConsumed.load(moRelaxed)
  if produced == consumed and underruns.load(moRelaxed) == 0:
    echo ""
    echo "Clean audio stream - no glitches!"
  else:
    echo ""
    echo "Note: Some underruns/overruns expected in simulation"
    echo "(Real audio uses hardware timing, not sleep())"
