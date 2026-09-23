# Status — draft 0.1.0

This is an initial implementation, not a mature or certified interoperability standard.

## Implemented and checked

- FRS, FMS and FSS schemas, shared conventions, controlled vocabulary, human-readable dictionary, and three synthetic examples.
- Twelve automated positive/negative schema checks, including unexpected fields, identity, dates, geometry, service availability and observation-only records.
- Searchable static catalog with filters, grid/list views, connected-record details, provenance, rights information, and JSON/schema downloads.
- Supabase private drafts, invited membership, immutable revisions, review/publication procedures, and public allowlisted documents.
- Hosted role checks: anonymous users cannot read drafts; uninvited accounts see no drafts; contributors cannot publish; a reviewed synthetic record conforms to its schema. Publication tests roll back.
- The founding steward's separate pilot has 60 unreviewed records, 80 revisions and zero published records. All 60 mapped documents validate. No research corpus or private credentials are included here. Supabase's security advisor reported no findings at the release check.

## Still to complete

- End-to-end administrator email delivery and verification. An address reservation is not an activated account. The code-sign-in UI requires the email template described in the database instructions.
- Editorial create/edit/review screens and a canonical-only ingestion endpoint. The current interface browses authorized drafts; it is not a complete editorial application.
- Source review, rights clearance, media visual checks, and provider confirmation before public catalog publication.
- Provider identity reconciliation: pilot provider URNs are explicitly unresolved candidates, not an authoritative organization registry.
- Richer geographic profiles, polygons/service areas, privacy-reviewed precise locations, localization, and larger-scale search/pagination.
- Partner validation and governance beyond the founding steward. Independent implementations should test draft compatibility and pin schema versions.

Media cards link to source pages. They do not imply that a thumbnail, image, video or service listing is licensed for reuse. Example.org records in this repository are illustrative only.
