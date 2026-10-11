# components

The dependencies an example stands up beside smolquery, each a
kustomization an example lists as a resource (`../../components/rustfs`).
They carry no namespace: the example's `namespace:` places them.

- **`rustfs`**: the sealed tier's S3-compatible object store
  ([RustFS](https://github.com/rustfs/rustfs)), one pod, one volume, and a
  Job that creates the `smolquery-sealed` bucket, since segment PUTs do not
  create their bucket and RustFS creates none at boot.
- **`postgres`**: the DuckLake catalog and node discovery database, one
  pod, one volume. Upstream's `deploy/overlays/kind/deps/postgres.yaml`, as
  is.

Upstream's kind overlay bundles Postgres with MinIO in one `deps`
kustomization; this repo carries its own so the object store can be RustFS.
