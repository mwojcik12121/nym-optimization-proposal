# Nym binary build environment

This environment compiles Nym executables and exports them as a portable archive for the test environment.

The default toolchains are:

```text
nym-node: Rust 1.89.0
wasmvm:   Rust 1.88.0
nyxd:     Go 1.23.11
```

## Recommended resources

| CPU | RAM | Swap | Free disk |
|:---:|:---:|:---:|:---:|
| 4 threads | 8 GB | 4-8 GB optional | 40 GB |

Practical verification:
Build was done on a machine with 32 GB RAM, 12 CPU cores and around 800 GB of free disk space - it was done with 4 parallel jobs and took around 6 minutes.

## Build

1. Place repositories in `src/` folder

2. Run

```bash
./build.sh --nym NAME --nyx NAME --wasmvm NAME --build-jobs N
```

3. After a successful build, the `bin/` directory will contain:

```text
bin/nym-binaries.tar.gz
```

which contains:

```text
bin/nyxd
bin/nym-node
bin/nym-base58
lib/libwasmvm.x86_64.so
metadata/build.env
runtime-base-image.tar
```
