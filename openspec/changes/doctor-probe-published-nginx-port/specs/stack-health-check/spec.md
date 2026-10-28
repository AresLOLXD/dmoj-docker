# Spec Delta

## Purpose
Defines what `./scripts/doctor` verifies about the running stack and how it reports each result, so an operator can trust a passing check to mean the thing it names.

## ADDED Requirements

### Requirement: The nginx check probes the address compose publishes
The health check SHALL verify the `nginx` service by requesting `/` at the host address and port that compose publishes for nginx's container port 80, and SHALL include that address in the check's output line. It SHALL NOT probe any fixed port. A wildcard bind (`0.0.0.0` or `[::]`) SHALL be probed through `127.0.0.1`. The pass criterion is unchanged: an HTTP status below 400.

#### Scenario: The published address is probed and shown
- **WHEN** nginx is running and compose publishes it at `127.0.0.1:8080`, and `./scripts/doctor` runs
- **THEN** the output contains `✓ nginx responds on 127.0.0.1:8080`
- **CHECK** with the stack up, `cd dmoj && ./scripts/doctor | grep -F '✓ nginx responds on 127.0.0.1:8080'` exits 0

#### Scenario: A wildcard bind is probed through the loopback address
- **WHEN** compose publishes nginx at `0.0.0.0:8080`, and `./scripts/doctor` runs
- **THEN** the output contains `✓ nginx responds on 127.0.0.1:8080`
- **CHECK** with a temporary compose override that publishes `0.0.0.0:8080:80`, `./scripts/doctor | grep -F '✓ nginx responds on 127.0.0.1:8080'` exits 0

#### Scenario: A stopped nginx fails the check instead of falling back to port 80
- **WHEN** the `nginx` service is not running, and `./scripts/doctor` runs
- **THEN** the output contains a `✗ nginx responds` line with a message saying nginx publishes no port, and `doctor` exits non-zero
- **CHECK** after `docker compose stop nginx`, `./scripts/doctor | grep -F '✗ nginx responds'` exits 0 and `./scripts/doctor >/dev/null; echo $?` prints `1`

#### Scenario: Remaining checks still run when the nginx check fails
- **WHEN** the nginx check fails, and `./scripts/doctor` runs
- **THEN** the sections after it (`== wsevent ==`, `== Rendering services ==`) are still printed
- **CHECK** with `nginx` stopped, `./scripts/doctor | grep -c -E '^== (wsevent|Rendering services) =='` prints `2`
