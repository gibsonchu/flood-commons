# Supabase reference implementation

This is a pilot editorial catalog, not a canonical-document ingestion API yet. Apply `001` through `007` in order to a **new Supabase project** using migrations. Do not run the baseline on an existing Flood Commons installation. Supabase Auth and the `pg_jsonschema` extension are required. The SQL installs its bundled draft schemas; the JSON files in `standards/` describe interchange documents.

Keep `fc_private` out of the Data API's exposed schemas. Only `public` is exposed. Public reads use `fc_records` and return reviewed standard documents. `fc_current_catalog` also excludes closed, historical, temporarily unavailable, and expired help listings. Raw catalog writes are denied. Drafts are scoped to authenticated members, and publication requires an editor or administrator.

Provision an initial scope and pending administrator membership through the database owner. `pending_memberships` takes an email, scope ID, role and expiration; inspect its definition in 001 before inserting. The Auth trigger enrolls the reserved address only after email confirmation. Never derive roles from user-editable metadata. No bootstrap operator, administrator address, or research seed is shipped in this repository.

`fc_propose` currently accepts the legacy editorial envelope plus a validated `standard_record`, not a standalone FRS/FMS/FSS document. The envelope includes review blockers, private research notes, taxonomy links and workflow fields. See its SQL signature and validation function before building an importer. `fc_review` supports publish, revise, exclude and archive with optimistic concurrency. Revisions are immutable. A future canonical-only ingestion adapter and editorial forms remain on the roadmap.

The static UI uses `site/config.json` for the URL and publishable key. Email-code sign-in requires a Supabase email template containing `{{ .Token }}`; configure delivery and test it in your own project. The UI never receives a service-role key. Sign-in establishes identity; only an invitation or reserved membership grants draft access.

Hosted media and coordinate publication are disabled in this pilot. Public relationships include only published targets. Database checks complement JSON Schema; schema validity does not establish factual accuracy, permission to reuse media, or current service availability.

## 006: status, audience, and the standard loader

- **Status** (`draft`, `published`, `hidden`, `excluded`) is kept on each record and follows review decisions. Editors relabel an unpublished record with `fc_private.set_unpublished_status`.
- **Audience** (`public` or `internal`) decides who may read a *published* record. Anonymous readers of `fc_catalog`, `fc_records`, and `fc_current_catalog` see only public records. Active members also see internal ones. Change it with `fc_private.set_audience`.
- **Verification is not overwritten on publication.** Each record keeps its own `verification` block, so an unreviewed record is never presented as reviewed.
- **`fc_private.propose_standard(doc, scope, audience, review_owner)`** accepts a standard FRS/FSS/FMS document and builds the editorial envelope that `propose` and the consistency triggers expect. Publication still goes through `fc_review`.
- The pilot's temporary research drafts were excluded, not deleted.

## 007: resident flood clips

- **Submitting:** anyone may submit a link to flood footage posted elsewhere (`public.fc_submit_clip`). Submissions wait in a private inbox (`fc_clip_inbox`, readable by members only) until an editor approves (`fc_approve_clip`) or rejects (`fc_reject_clip`) them. Approval builds and publishes a public FMS record marked `source_checked`.
- **Link-only media:** clips link to and embed the original post, credited to its creator. Nothing is copied or hosted.
- **Locations:** map points are published only for clips of streets, highways, and subways, rounded to a 0.0005° grid (about 50 m). The location guard now enforces this for every published record; exact points are never published. Clips of anywhere else get a neighborhood name only.
- **Removal:** anyone may ask for a published record to be taken down (`fc_request_removal`). Editors resolve requests with `fc_resolve_removal` (`remove` archives the record).
