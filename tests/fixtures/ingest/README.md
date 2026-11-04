# Recorded API responses for the olo-ingest connectors

`tests/connectors_test.ts` reads these files with `Deno.readTextFile`; no test touches the network.
Each file is shaped exactly like the response of the API call that `functions/olo-ingest/index.ts` makes.

## Recorded live on 26 October 2026, then trimmed

Trimming only removed things; nothing was rewritten except where noted.

| File | Request | Trimmed |
| --- | --- | --- |
| `wikipedia.summary.json` | `en.wikipedia.org/api/rest_v1/page/summary/Project_Gutenberg` | nothing |
| `wikipedia.disambiguation.json` | `en.wikipedia.org/api/rest_v1/page/summary/Mercury` | nothing |
| `wikipedia.search.json` | `en.wikipedia.org/w/api.php?action=query&list=search&srsearch=coral%20reef` | first three hits kept |
| `wikidata.entities.json` | `wbgetentities&ids=Q42\|Q1&props=info\|labels\|descriptions\|sitelinks&languages=en` | sitelinks cut to five per entity; the dash in "(1952-2001)" written as a hyphen (repo rule) |
| `archive_org.json` | `archive.org/advancedsearch.php?q=mediatype:texts AND description:*&rows=6&page=3` | one court judgment that names a private litigant removed |
| `arxiv.xml` | `export.arxiv.org/api/query?id_list=1706.03762,2005.14165,1207.7214` | the 2005.14165 entry removed; author lists cut to three |
| `arxiv.latex.xml` | `export.arxiv.org/api/query?search_query=cat:math.CO&sortBy=submittedDate&max_results=6` | three of six entries kept; author lists cut to three |
| `pubmed.efetch.xml` | `efetch.fcgi?db=pubmed&id=31452104,32015507,33301246&rettype=abstract&retmode=xml` | affiliations (one held an email address), investigator, MeSH, chemical and comments lists removed; authors cut to three plus the collective author; references cut to two (32015507) and to the one cited DOI (33301246); `&#x2013;` in two citations written as `-` |
| `pubmed.esearch.json` | `esearch.fcgi?db=pubmed&term=coral+AND+reef&retmax=3&retmode=json` | nothing |
| `wikinews.json` | `en.wikinews.org/w/api.php?action=query&generator=random&grnnamespace=0&prop=extracts\|info&exintro=1&explaintext=1&inprop=url` | two of three pages removed (they named private people or reported allegations) |
| `data_gov.json` | `api.gsa.gov/technology/datagov/v4/search?q=water&per_page=2` (DEMO_KEY) | contact points (names and emails), distributions, spatial and harvest fields removed; organization cut to id, name, slug |

`wikidata.entities.json` was recorded with the request index.ts made at the time (`languages=en`), which is why Q42 has no label in it; index.ts now asks for `languages=en|mul`.

## Reconstructed from the official documentation

These APIs could not be reached from the build container on 26 October 2026 (proxy 403 for es.wikipedia.org and gutendex.com, HTTP 429 from OpenAlex and, after a few calls, from the Wikimedia APIs). The edge-case files hold awkward cases on purpose and are reconstructed too.

| File | Shape taken from |
| --- | --- |
| `wikipedia_es.summary.json` | The live English summary above, and https://en.wikipedia.org/api/rest_v1/#/Page%20content/get_page_summary__title_ |
| `wikidata.search.json` | https://www.wikidata.org/w/api.php?action=help&modules=wbsearchentities |
| `wikidata.edge.json` | https://www.wikidata.org/w/api.php?action=help&modules=wbgetentities and https://www.wikidata.org/wiki/Help:Default_values_for_labels_and_aliases (the `mul` label) |
| `archive_org.edge.json` | The live `archive_org.json` above and https://archive.org/advancedsearch.php |
| `arxiv.edge.xml` | The live `arxiv.xml` above and https://info.arxiv.org/help/api/user-manual.html |
| `gutenberg.json` | https://github.com/garethbjohnson/gutendex (README, "API Objects") |
| `pubmed.edge.xml` | The live `pubmed.efetch.xml` above and https://www.ncbi.nlm.nih.gov/books/NBK25499/ (efetch), https://dtd.nlm.nih.gov/ncbi/pubmed/out/pubmed_250101.dtd |
| `wikinews.edge.json` | The live `wikinews.json` above and https://www.mediawiki.org/wiki/API:Query |
| `openalex.json` | https://developers.openalex.org/api-reference/works/get-a-single-work and https://help.openalex.org/data/works/attributes (Work object, `abstract_inverted_index`, `primary_location`) |

No fixture holds a key, token, email address or personal data beyond the public names of authors and the heads of state or public bodies named in published records.
