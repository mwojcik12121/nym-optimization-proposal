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

## Scenario description

### Scenario 1 behavior (example):

Each run starts from local genesis and uses the imported original `nyxd` binary:

1. The validators commit blocks 1 through 200.
2. `halt-height = 201` rejects `FinalizeBlock(201)`.
3. The harness waits for committed RPC height 200 and the expected height-201
   halt line.
4. The harness explicitly sends `SIGTERM`; it no longer waits for Nyxd to exit
   by itself, because the API and P2P services can remain alive after consensus
   halts.
5. After clean database closure, `nyxd rollback --hard` removes the pending
   block-201 store entry.
6. The halt is cleared, the consensus WAL is removed, validator signing
   state is reset to height 200, and normal empty-block production resumes.
7. All validators restart. Node01 waits until all three validators share the
   same recent block at a common height of at least 200 and their observed
   height spread is within the configured synchronization tolerance.
8. The chain remains live, and only then is the scenario released.

## Notes

* Node logs are exported as `logs/nodeXX_scenarioN_YYYYMMDD_HHMMSS.log`.
* Log timestamps use the current Docker host's local time zone. The host's `/etc/localtime` is mounted read-only into each node so native and test-harness messages use the same clock.
