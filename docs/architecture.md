# Shared architecture

## Record identity

`id` is a stable `urn:uuid:` record identifier. `local_id` preserves a publisher's familiar identifier. Never recycle either within its issuing scope. `publisher.id` identifies the organization maintaining the record; `source.organization` identifies its underlying source, which may be different. FSS `service.provider` describes the actual assistance provider.

Provider names are not enough to establish identity. The private pilot uses unresolved provider-candidate URNs pending reconciliation; these are not authoritative organization identities. Independent publishers should reconcile providers to stable identifiers before exchanging production data.

## Geography and time

A place link has a relation (`covers`, `depicts`, `serves`, or `observed_at`) and precision. An office address does not establish service coverage. A null geometry stays unknown; do not invent a point from a neighborhood label. Draft 0.1 supports WGS84 GeoJSON Points only; polygons, boundary provenance, and broader service-area geometry require a later profile. The initial hosted implementation only publishes named-area records.

Exact dates are ISO dates; exact metadata timestamps include a timezone. Preserve qualified or uncertain historical dates in the accompanying text field. A repository upload date is not automatically a capture date.

## Evidence and verification

`source.evidence_status` describes how the source was accessed. `verification.status` describes review. Structural schema validation proves neither factual accuracy nor ownership of an image. Publication is a separate hosting decision, not a property required by the exchange standards.

FMS accepts an `observation` with `media.type=observation` and no asset URL. A resident-reported depth is not an instrument measurement. Damage categories in 0.1 are broad reported classes, not an engineering damage assessment or a calibrated severity scale.

## Availability

FSS uses specific availability labels. Closed, historical, temporarily unavailable and expired-deadline services are excluded from current-help views. “Listed; contact provider” does not imply present capacity. Provider confirmation has its own date. Never renew it merely because a webpage still responds.

## Relationships and reuse

Every relationship has a target record URI and a typed relation. References may point to independently hosted records. A shared event association is not causal evidence. A catalog may omit private relationships from its public projection; the reference database emits links only when both records are public.

`rights` describes source material, not the repository's software license. Unknown rights remain unknown. The first hosted implementation publishes links only; it does not host or embed media assets.

## Validation boundaries

Each collection schema contains a self-contained copy of the shared core so partners and the database can validate without network resolution. `core.schema.json` documents that common shape. A change to shared fields must update all three generated collection schemas and their tests. The human-readable dictionary is generated from those schemas.

JSON Schema checks structure, types, enumerations and date/URI formats. It does not resolve external references, verify an organization, authorize publication, validate license ownership, or prove availability. The hosted importer adds foreign keys, term checks, scope permissions, and editorial gates. This draft does not claim full DCAT or HSDS compatibility.
