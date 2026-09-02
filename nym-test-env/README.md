# Nym test environment

This environment is used to test optimization proposed for Nym.

## Required resources

The setup presented below was based on physical capabilities of the machine used by the author of the optimization proposal.

| CPU | RAM | Free disk |
|:---:|:---:|:---:|
| 8 threads | 24 GB | 750 GB |

## Run test scenario

Copy product of nym-build-env into `bin/` folder and extract its contents, then run a scenario:

```bash
./run.sh 1
```

If `nym-test/runtime-base:v2` is not already available in the active Docker
daemon, `run.sh` loads it automatically from `bin/runtime-base-image.tar`.

## Scenario description

### Scenario 1: repeated odd-node faults with a live control group

Each run starts from local genesis and uses the imported `nyxd` and `nym-node`
binaries:

1. The three validators commit blocks through height 200, perform the configured
   height-201 halt and rollback, restart, and synchronize on the same live chain.
2. All five Nym services start and a strict baseline request must cross the local
   mixnet from node07 through node08 to the receiver on node03.
3. Odd-numbered Nym services node05 and node07 each run three fault cycles by
   default. Every cycle applies delay and jitter, fully isolates the service,
   stops its `nym-node` process temporarily, then restarts it and verifies
   recovery.
4. While either fault loop is active, node01, node02, and node03 continuously
   submit distinct bank transactions and verify that they commit. Nyxd also
   keeps producing empty blocks independently.
5. During the same period, node04, node06, and node08 continuously check their
   process, HTTP health, and advancing chain height. Node01 continuously sends
   observational mixnet requests; a request may succeed or fail during an
   injected fault, and each outcome is recorded rather than ending the run.
6. Healthy workloads stop only after both odd nodes publish completion. A final
   strict mixnet request and chain validation must then succeed.

The workload is bounded by `SCENARIO_FAULT_MAX_SECONDS` (600 seconds by
default). Its cycle count and phase durations can be overridden with the
`SCENARIO_FAULT_*` variables declared in `docker/compose.yaml`.

The bundled `local-nym-api` is a topology shim for the isolated mixnet. It does
not calculate rewarded-set weights. Run the modified Rust `nym-api` and its
monitoring inputs when using this workload to collect real selection scores;
the scenario itself supplies the repeated healthy and faulty behavior those
scorers need to observe. Detailed weight records use the
`nym_api::selection_scoring` tracing target at `INFO` level.

## Notes

* Node logs are exported as `logs/nodeXX_scenarioN_YYYYMMDD_HHMMSS.log`.
  Older generated `.log` files are removed at the start of each run.
* Log timestamps use the current Docker host's local time zone. The host's `/etc/localtime` is mounted read-only into each node so native and test-harness messages use the same clock.
