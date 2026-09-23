# Flood Commons

Open-source data infrastructure for flood resilience, founded and stewarded by **Floodline**.

Flood Commons defines practical ways to organize, publish, and exchange flood information. **Blue Dots** is a community-facing Floodline product that can consume this data. Governments, researchers, community groups, organizations, and developers can implement the specifications independently.

## Three draft standards

| Specification | What it describes | Schema |
|---|---|---|
| **FRS 0.1** — Flood Resource Standard | Guidance, reports, research, regulations, documents, and information about assistance programs | [FRS schema](standards/frs.schema.json) |
| **FMS 0.1** — Flood Media Standard | Photographs, videos, maps, animations, and flood observations with no required media attachment | [FMS schema](standards/fms.schema.json) |
| **FSS 0.1** — Flood Services Standard | A provider's specific service offering, including coverage, eligibility, contact routes, and availability | [FSS schema](standards/fss.schema.json) |

These are **draft 0.1.0 schemas**, not stable 1.0 standards, accredited specifications, or claims of compatibility with MDS, CDS, DCAT, or HSDS. The OMF model inspires the separation between stewardship, open specifications, and products built on them; there is no affiliation.

## Start here

- [Plain-language data dictionary](docs/data-dictionary.md)
- [Three synthetic examples](standards/examples.json)
- [Shared architecture and interpretation](docs/architecture.md)
- [Contribution process](CONTRIBUTING.md)
- [Governance and versioning](GOVERNANCE.md)
- [Database implementation](database/README.md)
- [Project status and limitations](docs/status.md)

## Validate and run

Node.js 22+ and Python 3 are sufficient for the schema tests and static reference interface.

```sh
npm ci
npm test
npm run preview
```

Open `http://localhost:8080`. The repository's example catalog contains **three explicitly synthetic records**, not real assistance listings. Search, collection/place/topic filters, record details, JSON download, standards downloads, and the published catalog adapter are included.

To connect your own published catalog, configure `site/config.json` with a Supabase project URL and **publishable** key. Never put a secret/service-role key there. Read the database setup instructions first. This repository does not contain the steward's unreviewed 60-record research corpus, personal administrator enrollment, or credentials.

## Open specifications, managed contributions

Anyone may use the specifications, validators, or code under their licenses. To contribute standards changes, open an issue or pull request. To contribute data to Floodline's hosted catalog, contact Floodline and arrange membership; records are reviewed before publication. Other publishers can manage their own catalogs and editorial rules.

A document about a program belongs in FRS; a concrete service/intake offering belongs in FSS. A photograph or a resident's observation belongs in FMS. Link records explicitly rather than treating these different things as interchangeable.

## Licensing

Original code, JSON schemas, and synthetic examples are available under [MIT](LICENSE). Original prose documentation is [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) (attribute “Flood Commons contributors”). Third-party records and media retain their own rights. No software or specification license here grants rights to reuse third-party photographs, videos, source documents, or logos.
