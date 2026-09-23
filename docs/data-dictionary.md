# Draft 0.1 data dictionary

Null means unknown or not applicable as described; an empty array means no values recorded. Required fields can still be null where explicitly allowed. Dates, permissions, locations and availability must not be invented.

Each collection has the shared fields below plus its own detail object.

## Shared fields

| Field | Type | Meaning |
|---|---|---|
| `id` | string | Globally portable record identity. Preserve across publishers and revisions. |
| `local_id` | string | Publisher-local identifier, retained when migrating the pilot. |
| `standard` | enum | Which specification defines this record: FRS, FMS or FSS. |
| `schema_version` | enum | Exact exchange schema version; this draft uses 0.1.0. |
| `publisher` | object | Organization maintaining this record, distinct from its source or service provider. |
| `publisher.id` | string | Stable URI identifying the publishing organization. |
| `publisher.name` | string | Human-readable publishing organization name. |
| `title` | string | Short, descriptive record title. |
| `summary` | string | Plain-language account of what the record contains or offers. |
| `categories` | array | Controlled topic identifiers; document the vocabulary used by the publisher. |
| `tags` | array | Optional descriptive search terms; do not substitute these for controlled categories. |
| `action_stages` | array | Relevant stage: understand, prepare, mitigate, respond or recover. |
| `audiences` | array | Groups the information or offering is intended for. |
| `languages` | array | Languages of the record or source; service delivery languages are separate. |
| `places` | array | Qualified place associations. A named area may have no geometry. |
| `places[].id` | string | Publisher or external place identifier. |
| `places[].name` | string | Human-readable place name. |
| `places[].relation` | enum | Whether the record covers, depicts, serves or was observed at this place. |
| `places[].precision` | enum | How precisely the place is known; do not imply exactness from a neighborhood name. |
| `places[].geometry` | object or null | WGS84 GeoJSON Point or null. Coordinates are longitude then latitude. |
| `places[].geometry.type` | enum | See the collection interpretation in architecture.md. |
| `places[].geometry.coordinates` | array | See the collection interpretation in architecture.md. |
| `event` | object or null | Named event association, or null when not established. |
| `event.id` | string | Stable identifier. |
| `event.name` | string | Human-readable name. |
| `event.date_text` | string | Qualified date text, not an invented exact timestamp. |
| `source` | object | Original evidence and access status. |
| `source.url` | string | HTTP(S) address of the original supporting source. |
| `source.organization` | string | Source publisher/creator display name; not necessarily the catalog maintainer. |
| `source.checked_at` | string / null | Date the recorded source evidence was checked. Not proof of service capacity. |
| `source.evidence_status` | enum | Website-documented, indexed-only, provider-confirmed, or unknown evidence. |
| `rights` | object | Reuse information about the source material. |
| `rights.status` | enum | Unassessed, reported license, needs review, or cleared for an identified use. |
| `rights.license` | string / null | License name as reported; null if unknown. |
| `rights.license_url` | string / null | HTTP(S) license or terms reference; null if unknown. |
| `rights.attribution` | string / null | Creator/source credit to preserve when the material is reused. |
| `verification` | object | Review status independent of structural schema validation. |
| `verification.status` | enum | Unreviewed, source checked, reviewed, or disputed. |
| `verification.method` | string / null | What was checked and how; null if review has not occurred. |
| `verification.verified_at` | string / null | Date of that review, not an automatic last-page-access timestamp. |
| `relationships` | array | Explicit connections to other portable record IDs. |
| `relationships[].target_id` | string | URI identifying the related record; may be maintained by another publisher. |
| `relationships[].relation` | string | Typed association; shared event does not establish causation. |
| `metadata` | object | Administrative history of the exchanged record. |
| `metadata.created_at` | string | Timestamp when this catalog record was created, including timezone. |
| `metadata.updated_at` | string | Timestamp of the latest revision, including timezone. |
| `metadata.record_version` | integer | Monotonically increasing record revision number, starting at 1. |

## FRS fields

| Field | Type | Meaning |
|---|---|---|
| `resource` | object | See the collection interpretation in architecture.md. |
| `resource.type` | string | Kind of information: guide, report, dataset, regulation, etc. |
| `resource.publication_date` | string / null | Exact source publication date, if established. |
| `resource.publication_date_text` | string / null | Original qualified publication date when exact precision is unavailable. |
| `resource.evidence_kind` | enum | Distinguish modeled scenarios, instrument observations, impact analysis and instruction. |
| `resource.document_url` | string | HTTP(S) link to the resource itself. |

## FMS fields

| Field | Type | Meaning |
|---|---|---|
| `media` | object | See the collection interpretation in architecture.md. |
| `media.type` | enum | Photograph, map image, video, animation or an observation with no asset. |
| `media.creator` | string / null | Reported original creator; null when unknown. |
| `media.capture_date` | string / null | Exact capture date, if verified; do not use repository upload time automatically. |
| `media.capture_date_text` | string / null | Original qualified capture date as reported. |
| `media.asset_url` | string / null | HTTP(S) media file URL or null. Rights review remains necessary. |
| `media.alt_text` | string / null | Description of the actual viewed asset, never invented from its title. |
| `media.duration_seconds` | number / null | Positive duration in seconds, or null for unknown/not applicable. |
| `media.evidence_kind` | string / null | How the item represents evidence, such as photograph, modeled output or resident report. |
| `media.observation` | object or null | Observation data. Required as an object when type is observation; otherwise may be null. |
| `media.observation.observed_at` | string / null | Exact observation timestamp with timezone, or null. |
| `media.observation.description` | string | What the observer reported. |
| `media.observation.flood_depth_cm` | number / null | Reported water depth in centimeters, or null; keep the measurement method in evidence. |
| `media.observation.damage_classification` | enum | Broad reported impact class, not an engineering assessment. |

## FSS fields

| Field | Type | Meaning |
|---|---|---|
| `service` | object | See the collection interpretation in architecture.md. |
| `service.provider` | object | Actual organization providing this offering; each service is a separate record. |
| `service.provider.id` | string | Stable provider URI. Reconcile provisional candidate identifiers before production exchange. |
| `service.provider.name` | string | Human-readable provider name. |
| `service.type` | string | Type of assistance or service offered. |
| `service.service_area` | string / null | Plain-language geographic coverage; not the location of a headquarters. |
| `service.eligibility` | string / null | Who can access the service and the requirements stated by the provider. |
| `service.availability` | enum | Qualified availability label; never collapse to an active checkbox. |
| `service.contact_url` | string / null | Official HTTP(S) intake/contact route, if known. |
| `service.phone` | string / null | Public service contact telephone, if verified. |
| `service.email` | string / null | Public service contact email, if verified. |
| `service.cost` | string / null | Stated cost or cost conditions; null does not imply free. |
| `service.hours` | string / null | Verified service hours; null does not imply always open. |
| `service.deadline` | string / null | Exact application deadline, if stated; expired records leave current-help views. |
| `service.languages` | array | Confirmed service delivery languages, distinct from webpage language. |
| `service.accessibility` | string / null | Documented access accommodations; null means not established. |
| `service.provider_confirmed_at` | string / null | Date of direct provider confirmation; a webpage check does not establish this. |
| `service.review_due` | string / null | Date by which the service listing should be reviewed again. |
