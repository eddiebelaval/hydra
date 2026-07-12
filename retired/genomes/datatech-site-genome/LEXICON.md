# LEXICON: Data Tech

> The fourth Genome gene: how Data Tech names things. The client's terms of art with gospel
> definitions the Build and Voice loops read so every asset uses the client's own language by
> construction. Locked terms are used verbatim. Engagement-born terms graduate here when
> client-enduring; terms that go portfolio-wide graduate to the global id8Labs LEXICON.md.
>
> Backfilled 2026-06-15 by mining the HALO docs (genome + engagements/datatech). Eddie adjusts wording.

## The Phases
> The four-phase delivery sequence for the Data Tech platform: Phase 1 Facelift, Phase 2 Outlet, Phase 3 Master, Phase 4 Hub / Intelligence Layer. Each phase is independently capitalizable; Phases 2-4 are gated on Yadira's ACCPAC audit.
source: VISION.md, ROADMAP.md

## Phase 1 — Facelift
> The self-contained visible win quoted and shipped before July: bilingual EN/ES homepage + about + product list/page with images and filtering + login (existing auth preserved) + structured banner slots + an Outlet "coming soon" shell + the invisible backend seam. If the client stops here, it stands alone.
source: PHASE-1-QUOTE-SCOPE.md, VISION.md

## Phase 2 — Outlet
> A standalone aged-inventory clearance store with pricing and access control; the quick second win that proves the platform moves real product. Gated on PMs providing aging data.
source: VISION.md, ROADMAP.md

## Phase 3 — Master (Data Tech Master)
> The partner portal for ~100 resellers across the tiers, displaying quotas, rankings, incentives, and tokens. Targeted to test October, launch November in Miami as a keynote moment.
source: VISION.md, DT-MASTER-QA.md

## Phase 4 — Hub / Intelligence Layer
> The data-cleaning primitive chain plus by-brand / by-account analytics that automate Marcos's hand-built reports; the recurring-retainer layer priced against the client's current IT spend. Eval set = Marcos's clean data since November 2022.
source: VISION.md, DT-MASTER-QA.md

## Ecosystem Tier
> The commercial tier that front-loads the deep pillars (unified dashboard + ACCPAC integration + data layer + grounded on-page AI agent) into one package instead of a slow phased drip. The owner-blessed direction after the June 12 buy-in.
source: VISION.md, call-notes/datatech-client-2026-06-12.md

## ACCPAC (Pro Series)
> Data Tech's on-prem accounting/inventory system of record: Sage Pro Series, discontinued 2014, built on Visual FoxPro. No modern API; readable read-only via ODBC against the .DBF tables. Never touches the internet — a one-directional sync replicates it into the new platform.
source: ACCPAC-INTEGRATION-NOTE.md, VISION.md

## Yadira
> The third-party IT contractor who controls ACCPAC access, hosting, and the data master, and guards that control. The pivotal gatekeeper; the June 24 Miami meeting is the critical path to read-access for Phases 2-4. (Spelling to confirm; "Yadid" appears informally.)
source: call-notes/datatech-client-2026-06-12.md, VISION.md

## Banner Slots
> Designated home- and category-page banner positions Data Tech rents to brands (e.g. Epson) as a revenue line. Phase 1 builds them as structured, swappable inventory; self-serve scheduling/targeting is Phase 2+.
source: PHASE-1-QUOTE-SCOPE.md, call-notes/datatech-client-2026-06-01.md

## Two-Modifications Rule
> Per approved milestone the client gets two rounds of modifications at no scope-change cost; a third and beyond is billable at standard rate. In writing in the SOW. Jose owns enforcing the conversation; Eddie forwards "could you also..." requests to him.
source: LOVABLE.md §14, VISION.md

## Partner Tiers
> The reseller tiers in Master: Select, Elite, Premiere / Premier Plus (nomenclature variant — Premiere primary), roughly by annual purchase USD. Quotas, rewards, and token eligibility vary by tier.
source: DT-MASTER-QA.md

## Tickets Master
> The gamified engagement tokens in Master that partners accrue, redeem, or win in raffles/promotions. Renamed from "Tokens" in portal UX.
source: DT-MASTER-QA.md

## The Collaboration Portal
> The internal TanStack Start + Supabase app where the pod and client align on strategy, design, and data before the customer rebuild. Lovable v0 schema accepted on Path A. NOT the customer-facing platform.
source: ROADMAP.md, LOVABLE.md, DATABASE-ARCHITECTURE.md

## Grounded Agent
> Data Tech's AI agent (v1) on the partner dashboard: read-only, RLS-scoped per partner, answers questions about that partner's own account in EN/ES, cites its sources, and never makes up a number. Claude tuned on Data Tech data, grounded in retrieved rows, not general chat.
source: AI-AGENT-V1-SCOPE.md, VISION.md

## Backend Seam Structure
> The invisible data-layer scaffold built in Phase 1 (profiles table tied to auth.uid(), ACCPAC ETL anchors, the shape but not the data of partner/order/quota tables) so Phases 2-4 attach without a rebuild.
source: PHASE-1-QUOTE-SCOPE.md, DATABASE-ARCHITECTURE.md

## Row-Level Security (RLS)
> Database-enforced access scoped to the logged-in partner's own data. Non-negotiable from day one on every partner-visible table; enforced in Supabase, never in app logic alone. Blocks cross-partner leakage and fences the AI agent.
source: DATABASE-ARCHITECTURE.md, AI-AGENT-V1-SCOPE.md

## Golden-Eval Gate
> The non-negotiable acceptance test for the AI agent: a held-out question set over real partner data with known answers. Asymmetric scoring — a miss is a yellow; a fabricated number is an automatic red (fail). No prompt change ships without re-running it.
source: AI-AGENT-V1-SCOPE.md

## Comunicado
> The formal quarterly communication from Data Tech marketing to all portal partners announcing the period's structure and opportunities. Fully automatable as a chain.
source: DT-MASTER-QA.md

## HP-Supplies Accelerator
> A quota/incentive program where accounts over 100% of the HP-Supplies goal earn extra points or rewards. HP is ~56% of sales and the dominant ranking/incentive lens.
source: DT-MASTER-QA.md

## Version PRO
> Data Tech's published target visual/strategic direction for Oct/Nov 2026 (referenced as the Cloudflare homepage). The Phase 1 facelift is the bridge toward it.
source: DESIGN.md, ETHOS.md

## Federation Pod
> The two-operator co-build: Jose Cruz (prime; client / UX / design) and Eddie Belaval (sub; backend / architecture / DB / infra), shared quarterback. Jose runs all directional client conversations; Eddie does not face Data Tech directly without Jose's blessing.
source: VISION.md, LOVABLE.md

## Hacked Twice
> Context that shapes every security decision: Data Tech was breached twice in ~13 months. Hence ACCPAC stays off the internet, RLS is non-negotiable, auth is hardened post-Phase-1, and the stack is enterprise-credentialed (Vercel SOC 2 + Supabase).
source: call-notes/datatech-client-2026-06-12.md, VULNERABILITY-MAP.md
