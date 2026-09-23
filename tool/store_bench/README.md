# store_bench

The spike harness behind pro-companion **ADR 002** (the local store), built for issue #13. It is a
separate Flutter app on purpose: the candidate databases stay out of the companion's own
dependencies, and only the chosen one enters the app, in the local core (#24).

| what | where |
|---|---|
| Race-day volume, each parameter justified from the pilot scope | `fixtures/pilot_day.json` |
| ADR 001 envelope, hash chain, ULID | `lib/envelope.dart` |
| Deterministic day generator and percentiles | `lib/day_generator.dart` |
| The three candidate stores behind one interface | `lib/stores.dart` |
| Latency and mutation benchmark (profile build, on a device) | `integration_test/benchmark_test.dart` |
| Force-kill durability harness for the chosen engine | `lib/main.dart` and `crash_test.sh` |
| Measured results | `results/` |

Commands are in ADR 002's *Rerun* section. #21 reruns the benchmark on the club phone. Its p95 is
ADR 002's kill condition.
