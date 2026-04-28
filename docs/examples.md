# Examples

Practical examples demonstrating lock-free queue patterns.

## Running Examples

```sh
nimble examples
```

Or run individual examples:

```sh
nim c --threads:on -r examples/audio_buffer.nim
nim c --threads:on -r examples/task_fanout.nim
nim c --threads:on -r examples/event_collector.nim
nim c --threads:on -r examples/job_scheduler.nim
```

---

## Audio Buffer (Bounded SPSC)

Real-time audio processing with fixed latency. The producer captures audio samples, the consumer plays them.

**Key properties:**

- Fixed latency determined by buffer size
- No allocation during operation
- Wait-free operations for predictable timing

**Use cases:** Audio engines, DSP pipelines, real-time signal processing

```nim
--8<-- "examples/audio_buffer.nim"
```

---

## Task Fan-Out (Bounded SPMC)

Work distribution from a single dispatcher to multiple workers.

**Key properties:**

- Work-stealing via CAS coordination
- Natural load balancing (faster workers get more tasks)
- Bounded memory provides backpressure

**Use cases:** HTTP request routing, image processing, game engine jobs

```nim
--8<-- "examples/task_fanout.nim"
```

---

## Event Collector (Unbounded MPSC)

Collecting events from multiple sources into a single processing pipeline.

**Key properties:**

- Handles traffic bursts (queue grows during spikes)
- Never drops events
- Lock-free producers don't block each other

**Use cases:** Log aggregation, metrics collection, network packet capture

```nim
--8<-- "examples/event_collector.nim"
```

---

## Job Scheduler (Unbounded MPMC)

Dynamic job scheduling with multiple submitters and workers.

**Key properties:**

- Elastic capacity grows with pending work
- Lock-free operations for high concurrency
- Dynamic scaling of producers and consumers

**Use cases:** Background job processing, build systems, database query scheduling

```nim
--8<-- "examples/job_scheduler.nim"
```

---

## Pattern Guide

| Pattern | Queue Type | Example |
|---------|------------|---------|
| Real-time audio/video | Bounded Sipsic | Audio buffer |
| Work distribution | Bounded Sipmuc | Task fan-out |
| Event aggregation | Unbounded Mupsic | Event collector |
| Job scheduling | Unbounded Mupmuc | Job scheduler |
| Sensor data | Bounded Sipsic/Mupsic | - |
| Request routing | Bounded Sipmuc | Task fan-out |
| Log collection | Unbounded Mupsic | Event collector |
| Thread pool | Unbounded Mupmuc | Job scheduler |
