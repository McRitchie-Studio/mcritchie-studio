# MyChart connection — design

**Status: proposed, awaiting Alex McRitchie's decisions (section 9). Nothing is
built.** Written with `mychart-connection-design` (2026-11-12). The Drive write
path it files into is a separate task, `drive-filing`.

The idea in one paragraph: Alex McRitchie is the parent and MyChart proxy of a
child who is a patient at Children's Hospital Colorado ("Children's Colorado"),
an Epic organization. The hub registers its own patient-facing app with Epic and
connects to his MyChart through **SMART on FHIR standalone patient launch**, the
same "sign in once, the hub keeps an encrypted refresh token" shape as
`GoogleConnection` and `QuickbooksConnection`. When he asks ("file the
immunization record for the preschool"), an agent reads the child's record
through Epic's read-only FHIR R4 API and files the document into the family's
own Google Drive. The hub keeps the token and a fetch log, never the records. Only
his own signed-in user can connect or fetch, and no agent chat context ever
carries the data.

**Who "the family" is, in hub terms.** The hub has no Family or Household
model, and none is added. "The family" means three things here: Alex
McRitchie's own signed-in `User`; the Google account that user connected
(a `GoogleConnection` he owns, whose Drive is "the family's Drive"); and the
child, who is **not a hub record at all**, only the patient a MyChart proxy
grant names (a FHIR patient id held on the connection row, section 4).

Sources are cited inline. **[EpicDoc]** means Epic's developer documentation
at <https://fhir.epic.com/Documentation?docId=oauth2>, which serves the whole
documentation set as one page; the quote was found in that text. Where a fact
could not be confirmed, the doc says so.

## 1. The motivating case

A preschool asks for the child's immunization record to meet Colorado's
childcare immunization requirement. Today that means Alex McRitchie signs in to
MyChart on his phone, finds the record, downloads a PDF and emails or uploads
it. The goal is one request to an agent: the record lands in the family's Drive
folder (say `Family/Child/Medical/Immunizations`), named and dated, ready to
share with the school. The same path later serves other documents: a visit
summary, a lab result, an allergy list for a camp form.

## 2. How the connection works

### 2.1 Register the app with Epic

Epic's developer site, fhir.epic.com, registers an app once and assigns it a
**non-production and a production client ID** [EpicDoc]. The Create an App
form asks for the app name, who uses it, the APIs, the FHIR version, the
redirect URIs, and "whether you'll use the confidential client profile
(required for refresh tokens)" [EpicDoc].

The hub's registration:

| Field | Value | Why |
|-------|-------|-----|
| Audience | **Patients** ("users must use their MyChart login credentials to authenticate" [EpicDoc]) | A parent signs in as himself |
| Client profile | **Confidential, asymmetric** (a JWK Set URL the hub serves; the private key stays in the hub's credentials) | Refresh tokens need a confidential client [EpicDoc]; Epic recommends a JWK Set URL over a secret [EpicDoc] |
| APIs | The read-only USCDI set in 2.3, nothing that writes | Auto-distribution requires read-only, patient-facing apps (2.5) |
| FHIR version | R4 | Children's Colorado publishes an R4 endpoint (2.6) |
| Redirect URI | `https://mcritchie.studio/admin/mychart/callback` and its local twin | Behind AdminWall, as the Egnyte callback is (section 5) |

Once an app is marked "Ready for Production", "neither you nor Epic can make
updates" except adding redirect URIs and changing the JWK Set URL; any other
technical change needs a new app [EpicDoc]. So the API list must be right the
first time: register in sandbox, prove every resource there, then promote.

Fees: Epic says its APIs "are licensed directly to healthcare organizations
(not to app developers)" [EpicDoc]. Whether Epic charges a patient-facing
developer anything, or reviews the app, **could not be confirmed**.

### 2.2 The standalone patient launch

1. **Discover.** The hub reads
   `<FHIR base>/.well-known/smart-configuration`. Children's Colorado's answers
   live (fetched 2026-11-12) with the authorize and token endpoints under
   `https://fhir.childrenscolorado.org/fhirprd/oauth2/`, PKCE `S256` only, and
   capabilities including `launch-standalone`, `client-confidential-asymmetric`,
   `context-standalone-patient`, `permission-offline`, `permission-v1`,
   `permission-v2` and `sso-openid-connect`.
2. **Authorize.** The browser goes to the authorize endpoint with
   `response_type=code`, the client ID, the redirect URI, a `state`, a PKCE
   `S256` challenge, `aud=<FHIR base>` and the scopes below. `aud` is required
   when `launch/patient` is asked for [EpicDoc]. Epic recommends PKCE for every
   app and does not support the `plain` method [EpicDoc].
3. **Sign in and choose.** Alex McRitchie signs in with his own MyChart login,
   chooses the patient (2.4) and chooses how long the access lasts (2.5).
4. **Exchange.** The hub's callback trades the code at the token endpoint,
   authenticating with a signed JWT client assertion. The answer carries an
   access token, `expires_in`, the granted scope, the `patient` id in context,
   an ID token, and a refresh token when `offline_access` was granted. Epic's
   sample answer shows `"expires_in": 3600` [EpicDoc]; one hour is the example,
   not a stated rule, so the hub reads `expires_in`.

**Scopes.** SMART v2 uses the CRUDS syntax: `.rs` means read and search, and v1
`.read` maps to v2 `.rs`
([HL7 SMART App Launch 2.2, scopes](https://hl7.org/fhir/smart-app-launch/scopes-and-launch-context.html)).
Epic's sample uses v1 (`patient/Immunization.read ... launch/patient
offline_access`) [EpicDoc]. Children's Colorado advertises both, so the hub asks
in v1, the form Epic's docs show, and switches only if the sandbox refuses:

```
openid fhirUser launch/patient offline_access
patient/Patient.read patient/Immunization.read
patient/DocumentReference.read patient/Binary.read
patient/DiagnosticReport.read patient/Observation.read
patient/Encounter.read patient/AllergyIntolerance.read
patient/MedicationRequest.read
```

`launch/patient` asks Epic for a patient to be selected when launching outside
the EHR (HL7 spec above). `openid fhirUser` returns an ID token naming the
signed-in user.

### 2.3 What the hub can read

Epic's USCDI v1 auto-distribution list includes the R4 read APIs for
AllergyIntolerance, DiagnosticReport (Results), DocumentReference (Clinical
Notes, Generated CCDA, Labs), Encounter, Immunization, MedicationRequest,
Observation (Labs, Social History, Vitals), Patient, Procedure and
RelatedPerson (Proxy) [EpicDoc]. The USCDI v3 set adds, among others,
Binary.Read for studies and outside-record notes [EpicDoc].

| Need | Resource | Confirmed? |
|------|----------|------------|
| Immunization record | `Immunization` (one per dose: vaccine code, date, status) | Yes, in the list |
| Visit notes, after-visit summaries | `DocumentReference` (Clinical Notes) plus the `Binary` it points to | The DocumentReference entry, yes; a general Binary.Read for note bodies **could not be confirmed** |
| Lab results | `DiagnosticReport`, `Observation` | Yes |
| Visits | `Encounter` | Yes |
| Allergies, medications | `AllergyIntolerance`, `MedicationRequest` | Yes |
| Letters, school forms, an immunization certificate PDF | none known | **Could not be confirmed.** No letters or correspondence category appears in Epic's list |

Two consequences. First, the immunization record is **built from
`Immunization` resources**, not fetched as a ready-made PDF: the hub renders a
dated table (vaccine, dose date, status, source organization) into a PDF and
files that, with the FHIR JSON beside it. Second, an organization may filter
what a patient context sees: "FHIR APIs may be configured to exclude specific
lab results to comply with state and local regulations" [EpicDoc]. The hub
reports what it got; it never says a record is complete.

**The school form caveat.** A Colorado childcare provider may require a
specific form (a Certificate of Immunization or an official state registry
printout) rather than any list of doses. Which form this preschool takes, and
whether Colorado's immunization registry offers parents a printout, **was not
researched here**. The first build files the FHIR-derived record; Alex
McRitchie confirms with the school whether it suffices (decision 6).

### 2.4 Proxy: choosing the child's record

Epic marks who signed in through `fhirUser`: a Patient resource for MyChart
self access, a **RelatedPerson** resource for proxy access [EpicDoc]. Epic also
warns that a proxy "might not have access to a patient's preferred name, gender
identity, or sex for clinical use" [EpicDoc]. The patient whose record the
token reads is the `patient` value in the token answer.

How the patient picker looks to a proxy in a standalone launch **could not be
confirmed** from an Epic source; the sandbox test in task M1 proves it. The
design does not depend on the screen: the hub stores the `patient` id the token
names, reads only that patient, and labels the connection with the name the
`Patient` resource returns (shown to Alex McRitchie, never logged). Connecting
a second child is a second sign-in and a second row.

**Age limit.** Children's Colorado's MyChart page says: "Under 14: Parents have
full access"; from 14 to 18 parents "have limited access" (they can still
message the care team and see test results); at 18 parents cannot create an
account
([Children's Colorado, MyChart](https://www.childrenscolorado.org/your-visit/my-chart/)).
Other Colorado systems cut proxy access at 12, for example
[Denver Health](https://www.denverhealth.org/-/media/files/modules/news/2017/mychart-child-proxy-access-request-form-ages-0-11-years-11-2016.pdf),
so the rule is per organization. Whether limited proxy access still lets an app
connect **could not be confirmed**. For a preschool-age child this is years
away; the connection's card states the age rule so nobody is surprised.

### 2.5 Token lifetime, refresh and org activation

- **Refresh needs a confidential client** [EpicDoc]. Children's Colorado also
  advertises `client-public`; whether Epic issues a public client a refresh
  token could not be confirmed, so the design does not rely on it.
- **The patient chooses the duration.** "In patient-facing contexts, it can be
  set by the patient through MyChart." Patients "can choose from a variety of
  options (e.g., 1 hours, 1 day, 1 week, …) configured by the customer"
  [EpicDoc]. An organization may allow "Indefinite" as its maximum, and even
  then "each patient still chooses their max access period" [EpicDoc]. Which
  options Children's Colorado offers **could not be confirmed**; M1 records
  them.
- **The hub mints an access token per fetch**, from the stored refresh token,
  and stores nothing but the refresh token and its stated expiry. If Epic
  answers a new refresh token on refresh, the hub stores it under the row's
  lock before using the access token, as `QuickbooksConnection#rotate!` does for
  Intuit. Whether Epic rotates refresh tokens could not be confirmed, so the
  code handles both.
- **When the grant lapses**, a fetch refuses with "reconnect MyChart on
  /integrations", as a revoked Google grant does. Reconnecting is one sign-in.

**Activation at Children's Colorado.** Epic distributes patient-facing app
licenses to its customers automatically: "Epic customers receive licenses of
applications automatically on a rolling 12-hour cycle ... it may take up to 12
hours before a successful authentication can occur" [EpicDoc]. A client ID
auto-downloads to an organization when the app is read-only, patient-facing,
uses only the USCDI APIs (v3 for Epic August 2024 and later), has "Enable
Auto-download" selected, is Ready for Production, and "does not use refresh
tokens OR uses refresh tokens and has a client credential uploaded by the
vendor for that community member" [EpicDoc]. The organization must also hold
the USCDI license and not have turned auto-download off.

So the expected wait is **about 12 hours after promotion, with no request to
the hospital**, provided the hub uploads its public key for Children's
Colorado under Epic's "Review & Manage Downloads" before that sync. If the
organization has turned auto-download off, activation becomes a request to its
IT team with no known timeline; that is the fallback in decision 4.

### 2.6 Children's Colorado's endpoint

`https://fhir.childrenscolorado.org/fhirprd/api/FHIR/R4/`, listed as
"Children's Hospital Colorado" in Epic's public endpoint list
(<https://open.epic.com/Endpoints/R4>) and answering its smart-configuration on
2026-11-12. The hub keeps endpoints in config keyed by organization, so a
second Epic organization (a specialist, a new pediatrician) is a config row,
not code.

## 3. Alternatives considered

| Option | Why not |
|--------|---------|
| **Browser automation of MyChart** (an agent drives the MyChart website as Alex McRitchie) | It needs his MyChart password and second factor held by an agent, it breaks on every portal redesign, and MyChart terms are set per organization; some ban it outright, for example MSK's bans software "to scrape, spider or crawl" ([MSK MyChart terms](https://mskcc.org/privacy/web-site-privacy-practices/msk-mychart-terms-and-conditions)). Children's Colorado's terms could not be checked. SMART on FHIR is the sanctioned door and Epic opens it to patient apps by default |
| **Apple Health Records** (the iPhone's Health app pulls the record, an export carries it out) | Reading clinical records in code needs an iOS app with Apple's Clinical Health Records capability and App Review ([Apple, accessing health records](https://developer.apple.com/tutorials/data/documentation/healthkit/accessing-health-records.md)). The manual Health export is said to include FHIR JSON only by a user forum report; Apple does not document it. Whether Children's Colorado is in Apple's list could not be checked (the list renders in JavaScript). Every fetch would need his phone in hand |
| **Third-party aggregators** (Flexpa, Particle, Health Gorilla, 1upHealth, b.well) | Built for businesses, not one family: per-patient or per-query pricing for companies (Flexpa's page reportedly lists $2 per patient link per month; the direct fetch failed), 1upHealth's consumer product "sunsets September 30, 2026", and each one adds a company that holds the child's records. None was found that sells to an individual. Epic gives a patient app the same data directly |
| **Ask the clinic each time** | Works today and stays the fallback. It is the manual step this design removes |

## 4. Data handling

The rule, in one line: **the hub holds a key, not the records.**

- **Tokens.** One `MychartConnection` row per (organization, patient) pair: the
  refresh token encrypted at rest with Active Record Encryption (`encrypts
  :refresh_token`, masked in every inspect through `filter_attributes`), exactly
  as `app/models/google_connection.rb`, `app/models/egnyte_connection.rb`,
  `app/models/quickbooks_connection.rb` and `app/models/msgraph_connection.rb`
  do. Without the app's encryption keys the sign-in refuses before it asks
  Epic for anything; with them lost, the row is unreadable and counts as not
  connected: `app/models/google_connection.rb#readable?` rescues
  `ActiveRecord::Encryption::Errors::Base`, and the new model copies it.
  The row stores the organization key, the FHIR patient id, a display label,
  the granted scope and the token expiry. No access token is stored.
- **Records.** Fetched on request, held in memory or a temp file for the
  length of the fetch, written to the family's Google Drive through the
  write path the `drive-filing` task lands (on the hub's Drive client,
  `app/services/workspace/drive_client.rb#files_create`, or its successor), then
  dropped. One master file per document; any second place it should appear
  gets a Drive shortcut, not a copy (the one-master-and-shortcuts dream). No table holds a FHIR resource, a
  document, a diagnosis, a date of birth or a record number.
- **The fetch log.** One `MychartFetch` row per request, like `GmailChange`.
  It holds exactly: who asked (the user id and the agent soul), when, the
  organization key and the connection's random hex slug as plain strings
  (not a foreign key, so the log outlives a disconnect, as `GmailChange`
  keeps `mailbox` as a string), the resource type, the count returned, the Drive file ids
  written, dry run or applied, and a status (`ok`, `refused`, `failed`).
  Never a clinical value: no resource body, vaccine name, result, date of
  birth, record number, the patient's name or the connection's display
  label, or a file name that carries clinical content.
- **Who.** Only Alex McRitchie's own user can connect, fetch or see the card.
  In the hub's access vocabulary, two walls stack. First, every route lives
  under `/admin/mychart`, so AdminWall's default-deny (`app/controllers/application_controller.rb`,
  walked by `test/integration/admin_wall_test.rb`) refuses every non-admin
  by construction, and a future route cannot open by accident. Second, the
  household rule (`GoogleConnection.household`: every admin) is **too wide**
  for a minor's health record, so an explicit owner list (decision 2) is
  checked in the controller, the CLI and the fetch service. Of the agent
  session tiers in [the agent sessions design](agent-sessions-design.md),
  only an `admin` session acting for that owner may fetch; a `studio`
  session (one task) and a `client` session never can. No client, no client
  app owner and no other admin reaches it, and a test proves each refusal.
- **Credentials.** The client ID is public metadata and lives in config. The
  client-assertion private key (or a client secret, if the registration only
  offers one) is a 1Password item named per
  [the credential inventory](../modules/credential-inventory.md) and read
  through [credential access](../modules/credential-access.md): names in the
  docs, never values. The public half is served at the JWK Set URL.
- **No chat context.** MyChart data never enters an agent's memory bundle:
  nothing like `GoogleConnect::OwnerContext` reads it. An agent fetches only
  when asked, and its reply says what it filed and where, not what the record
  says.
- **Every failure is logged, and none leaks.** Every refused exchange,
  refresh or read lands in `ErrorLog` through the engine's
  `rescue_and_log(target:, parent:)` (studio-engine
  `app/controllers/concerns/studio/error_handling.rb`), as the Egnyte
  controller does, with the resource type and HTTP status only; the row never
  carries a response body or a token.
- **Disconnect.** Removing the connection deletes the row and its token, and
  the card says how to revoke the app at Epic as well (MyChart's linked-apps
  page). The fetch log stays, as `GmailChange` outlives a disconnect.

### 4.1 The HIPAA position

Stated carefully, and not legal advice:

- HIPAA binds **covered entities** (providers, health plans, clearinghouses)
  and their **business associates**. Children's Colorado is a covered entity.
- When a patient, or a patient's personal representative, directs a covered
  entity to send records to an app the patient chose, HHS's guidance is that
  the covered entity is not liable for what the app does with the data
  afterwards, "unless the app was developed for or provided on behalf of the
  covered entity"
  ([HHS, access right, health apps and APIs](https://www.hhs.gov/hipaa/for-professionals/privacy/guidance/access-right-health-apps-apis/index.html);
  the page refused automated fetches, so this rests on search summaries of
  it). An app the guardian chose and that works for the family, not for the
  hospital, is not the hospital's business associate.
- A parent is generally a minor child's personal representative under HIPAA
  (45 CFR 164.502(g)(3)), with exceptions where state law lets the minor
  consent to the care or the parent agreed to confidentiality; the
  organization's own age rule narrows it further (2.4).
- So **HIPAA does not regulate the hub's handling of this data**, as far as
  this research shows. That does not make the data less sensitive. The hub
  holds itself to the rules in section 4 because it is a child's health
  record, not because a statute requires it.
- The **FTC Health Breach Notification Rule** (16 CFR 318, amended effective
  2024-07-29) covers an entity that "offers or maintains a personal health
  record" drawing on multiple sources
  ([FTC guidance](https://www.ftc.gov/business-guidance/resources/complying-ftcs-health-breach-notification-rule-0)).
  Whether it reaches a private tool one family runs for itself **could not be
  confirmed**; the likely reading is no, because nothing is offered to
  consumers. **If the connection is ever offered to clients, that changes**:
  the rule, state health-privacy law and Epic's app terms all need a fresh
  review first. This design is for the owner's family only.
- **Information blocking.** Providers are "actors" under the Cures Act rule
  ([ONC](https://www.healthit.gov/topic/information-blocking)), and ONC says
  that requiring security vetting of a patient-chosen app on the certified API
  "would likely be an interference"
  ([ONC FAQ](https://healthit.gov/faq/if-actor-requires-third-party-applications-apps-be-vetted-them-security-reasons-allowing/)).
  This supports the auto-distribution path; it was not checked for changes in
  the last year.

## 5. Shape in the hub

It follows the existing connectors, so a reviewer finds nothing new in kind:

| Piece | Modeled on |
|-------|------------|
| `MychartConnection` model, encrypted refresh token, `#readable?`, rotation under lock | `GoogleConnection`, `QuickbooksConnection` |
| `Mychart::OAuthClient` (discovery, PKCE, JWT client assertion, refresh) | `GoogleConnect::OAuthClient`, `Quickbooks::OAuthClient` |
| `Mychart::Reader` (read-only FHIR searches for the one patient; no write method exists) | `Quickbooks::Reader`, `GoogleConnect::GmailReader` |
| `Mychart::Filer` (render the record, hand it to the Drive writer, log a `MychartFetch`) | `GoogleConnect::GmailEditor` with `GmailChange` |
| `bin/health fetch immunizations --patient LABEL --folder PATH` (dry run unless `--apply`) | `bin/mail organize` |
| A connect-group entry in `config/integrations.yml` (the one place /integrations reads) with `dark: true` until Children's Colorado activates the app, and owner-only after that; never on the public page | The `dark` entries |
| `Admin::MychartController`: show, connect, callback (state check, code exchange, store), disconnect; `before_action :require_admin` plus the owner gate | `app/controllers/admin/egnyte_controller.rb` |
| JWK Set URL served by the hub, private key in credentials | New; a short route |

## 6. Build plan

Each is one small task, in order. None starts until section 9 is answered.

| # | Slug (proposed) | Shape | What it delivers |
|---|-----------------|-------|------------------|
| M1 | `mychart-epic-registration` | ops | Register the app on fhir.epic.com (non-production), generate the key pair, publish the JWK Set URL, and prove a sandbox standalone launch with Epic's test patients, including a proxy test patient: record the picker, the duration options and whether the refresh token rotates |
| M2 | `mychart-connection-model` | backend | `MychartConnection` and `MychartFetch`, encryption, the owner gate, `Mychart::OAuthClient`; unit tests for the gate refusals, rotation and unreadable rows |
| M3 | `mychart-connect-flow` | ui | The owner-only card, the connect and callback routes, disconnect, the age-rule note; component and request tests; local look by Alex McRitchie |
| M4 | `mychart-immunization-filing` | backend | `Mychart::Reader` for `Immunization`, the PDF render, `bin/health fetch immunizations` dry run and apply, filing through `drive-filing`, one log row per run |
| M5 | `mychart-go-live` | ops | Promote to production, upload the client credential for Children's Colorado, wait for the 12-hour sync, connect the child for real, file the first record |
| M6 | `mychart-documents` | backend | `DocumentReference`/`Binary`, `DiagnosticReport`, `AllergyIntolerance`, `MedicationRequest`: whatever M1 proved readable |

M4 depends on `drive-filing` landing. M6 is optional and waits for a real
request.

## 7. Risks

| Risk | Answer |
|------|--------|
| The production registration freezes the API list | Prove every resource in sandbox (M1) before promotion; a missed API means a new app |
| Children's Colorado has auto-download off | Fallback: request activation from its IT team (decision 4); manual MyChart stays available meanwhile |
| The patient chooses a short duration at sign-in | The card says "choose the longest option offered"; a lapsed grant is one reconnect |
| The school wants an official form | Decision 6; the FHIR record may be a supplement, not the answer |
| A leak of the refresh token | Encrypted at rest, scoped read-only to one patient, revocable in MyChart; the private key for client assertion lives only in credentials |
| Scope creep to clients | Out of scope by rule (4.1); a client offering needs its own legal review |

## 8. Not in scope

Writing anything to Epic (messages, appointments, forms); other family members'
own records; any client-facing offering; keeping a copy of any record in the
hub; summarizing records into agent memory.

## 9. Decisions Alex McRitchie owes before any code (defaults stand on silence)

| # | Decision | Default |
|---|----------|---------|
| 1 | Take the SMART on FHIR route at all? | **Yes**, with the build plan in section 6, starting with M1 in Epic's sandbox |
| 2 | Who may connect and fetch | **Only Alex McRitchie's own user**, named in an explicit owner list in config, not every admin. A co-parent would be a second named user with their own MyChart sign-in, added only on his word |
| 3 | The app's name and the Epic developer account | **"McRitchie Studio Family Records"**, under a fhir.epic.com account owned by `team@mcritchie.studio`, its login in 1Password |
| 4 | If auto-distribution has not reached Children's Colorado 48 hours after promotion | **An agent drafts a request to Children's Colorado's MyChart support to activate the client ID; Alex McRitchie sends it** |
| 5 | Where records land in Drive | **`Family/<child's first name>/Medical/<kind>/`** in the Drive of his own `GoogleConnection`, one file per fetch named `<kind> <YYYY-MM-DD>.pdf`, the FHIR JSON beside it |
| 6 | What to give the preschool | **File the FHIR-derived immunization PDF and ask the school whether it suffices**; if it needs an official Colorado certificate, request that from the pediatrician through MyChart messages and file the reply |
| 7 | Access duration to pick at the MyChart sign-in | **The longest option Children's Colorado offers**, so the connection rarely asks again |
| 8 | Resources beyond immunizations | **Ask for all nine resource read scopes at registration** (cheap now, impossible after promotion), **but build only the immunization fetch** until a second real request arrives |

## 10. Sources

- Epic on FHIR documentation, OAuth 2.0 and app distribution: <https://fhir.epic.com/Documentation?docId=oauth2>
- Epic open endpoint list (R4): <https://open.epic.com/Endpoints/R4>
- Children's Colorado SMART configuration: <https://fhir.childrenscolorado.org/fhirprd/api/FHIR/R4/.well-known/smart-configuration>
- HL7 SMART App Launch 2.2, scopes and launch context: <https://hl7.org/fhir/smart-app-launch/scopes-and-launch-context.html>
- Children's Colorado MyChart access by age: <https://www.childrenscolorado.org/your-visit/my-chart/>
- HHS, access right, health apps and APIs: <https://www.hhs.gov/hipaa/for-professionals/privacy/guidance/access-right-health-apps-apis/index.html>
- FTC Health Breach Notification Rule guidance: <https://www.ftc.gov/business-guidance/resources/complying-ftcs-health-breach-notification-rule-0>
- ONC information blocking: <https://www.healthit.gov/topic/information-blocking>
- Apple HealthKit clinical records: <https://developer.apple.com/tutorials/data/documentation/healthkit/accessing-health-records.md>
