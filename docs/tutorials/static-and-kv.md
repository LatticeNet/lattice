# KV and Static Buckets

KV is useful for small configuration and Worker-backed responses.

In the dashboard:

1. Open KV.
2. Use bucket `default`.
3. Save key `message`.
4. Deploy a Worker with source `hello {{kv:default/message}}`.

Static buckets accept path, content, and content type through the API. Paths are
normalized and traversal is rejected. Production static hosting should add:

- Object size limits per bucket.
- Immutable object versions.
- Optional domain/path routing through nginx or Cloudflare.
- Audit events for publish/unpublish.

