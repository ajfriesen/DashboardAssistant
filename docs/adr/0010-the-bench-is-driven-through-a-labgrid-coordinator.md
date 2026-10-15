---
status: accepted
---

# The bench is driven through a labgrid coordinator on the bench host

The bench no longer hangs off a workstation. The USB-SD-Mux, the Debug Probe and the plug are attached to a dedicated bench host, which exports them through a labgrid coordinator and exporter; `labgrid/bench.yaml` names the resulting place and the tests acquire it from whatever machine they run on.

This reverses the reasoning this repo used to carry. Declaring the resources directly was right while they were plugged into the machine running the tests: labgrid's remote path routes every command through ssh and rsyncs the image to the exporter host, which on one machine meant ssh-to-self and a 4 GiB copy from a disk to itself. Both objections disappear once the hardware is somewhere else — the `dd` has to run on the bench host either way, and the image has to cross the network either way.

## Consequences

- Hardware identities (mux serial, probe serial, plug address and model) live in the bench host's NixOS module, which is their single source of truth. This repo deliberately keeps no copy; a second copy is a drift waiting to happen, and the one we had had already drifted — it did not know about the plug.
- The plug is a `NetworkPowerPort`, so labgrid's own `shelly_gen1`/`shelly_gen2` backends switch it and there is no power script to maintain. What those backends cannot do is measure, so `test_board_draws_power` reads the plug's meter directly, at the address the exporter published.
- Every test run needs the place acquired, and labgrid's `acquire` is not idempotent. The `hw-*` recipes acquire only when nobody holds the place and release only what they acquired, so holding it by hand across several runs keeps working.
- The machine running the tests needs non-interactive ssh to the bench host. A key that cannot sign unattended is worse than no key: the failed attempt can trip OpenSSH's per-source penalties and lock the client out of the bench host entirely.
- The exporter is where a second board, a second bench or a CI runner now plugs in, which is what this buys and what the old layout could not have.
