# Every example's suite is opt-in: it needs that example running in the kind
# cluster. `mix test` alone runs only the harness's own tests;
# `mix test --only single_node` runs one example's suite.
ExUnit.start(
  exclude: [
    :single_node,
    :split_compute,
    :federated_read_clusters,
    :hyperdx,
    :victoriametrics,
    :postgres_fdw
  ]
)
