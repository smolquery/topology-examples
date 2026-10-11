#!/usr/bin/env bash
# Runs one example's ExUnit suite. Suites are tagged by the example's name
# with dashes as underscores (examples/single-node -> --only single_node).
set -euo pipefail

cd "$(dirname "$0")/.."

EXAMPLE="${1:?usage: $0 <example>}"
exec mix test --only "${EXAMPLE//-/_}"
