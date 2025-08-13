#!/usr/bin/env bash
set -euo pipefail

echo "==> Crée/patch les routes Next.js"

mkdir -p src/app/api/ingest/tenders src/app/api/ingest/tender-docs

cat > src/app/api/ingest/tenders/route.ts <<'EOF'
import { NextResponse } from "next/server";
import { createSupabaseAdmin } from "@/lib/supabaseAdmin";

type Tender = {
  source: string;
  ref: string;
  buyer: string;
  title: string;
  category?: string | null;
  amount_min?: number | null;
  amount_max?: number | null;
  deadline_at?: string | null;
  url?: string | null;
  raw_json?: any;
};

export async function POST(req: Request) {
  const key = req.headers.get("x-ingest-key");
  if (!process.env.INGEST_SECRET || key !== process.env.INGEST_SECRET) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const supa = createSupabaseAdmin();
  const body = await req.json().catch(() => ({}));
  const items = (body?.items ?? []) as Tender[];
  if (!Array.isArray(items) || items.length === 0) {
    return NextResponse.json({ error: "No items" }, { status: 400 });
  }

  const payload = items.map((t) => ({
    source: String(t.source || "portail.marchespublics.nc"),
    ref: String(t.ref || ""),
    buyer: String(t.buyer || ""),
    title: String(t.title || ""),
    category: t.category ?? null,
    amount_min: t.amount_min ?? null,
    amount_max: t.amount_max ?? null,
    deadline_at: t.deadline_at ?? null,
    url: t.url ?? null,
    raw_json: t.raw_json ?? null,
  }));

  const { data, error } = await supa
    .from("tenders")
    .upsert(payload, { onConflict: "source,ref", ignoreDuplicates: false })
    .select("id, source, ref");

  if (error) {
    console.error("Ingest upsert error:", error);
    return NextResponse.json({ error: error.message }, { status: 500 });
  }

  // ← n8n a besoin de l'id pour la suite
  return NextResponse.json({ items: data ?? [] });
}
EOF

cat > src/app/api/ingest/tender-docs/route.ts <<'EOF'
import { NextResponse } from "next/server";
import { createSupabaseAdmin } from "@/lib/supabaseAdmin";

type DocItem = { url: string; mime?: string | null; kind?: string | null };

export async function POST(req: Request) {
  const key = req.headers.get("x-ingest-key");
  if (!process.env.INGEST_SECRET || key !== process.env.INGEST_SECRET) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const body = await req.json().catch(() => ({}));
  let tenderId = body?.tenderId as string | undefined;
  const source = body?.source as string | undefined;
  const ref = body?.ref as string | undefined;
  const docs = (body?.docs ?? []) as DocItem[];

  if ((!tenderId && !(source && ref)) || !Array.isArray(docs) || docs.length === 0) {
    return NextResponse.json({ error: "Missing tenderId or (source,ref) or docs" }, { status: 400 });
  }

  const supa = createSupabaseAdmin();

  // Résolution par (source,ref) si tenderId non fourni
  if (!tenderId && source && ref) {
    const { data: found, error: e0 } = await supa
      .from("tenders")
      .select("id")
      .eq("source", source)
      .eq("ref", ref)
      .limit(1)
      .maybeSingle();

    if (e0) return NextResponse.json({ error: e0.message }, { status: 500 });
    if (!found) return NextResponse.json({ error: "Tender not found for given (source,ref)" }, { status: 404 });
    tenderId = found.id as string;
  }

  const payload = docs.map(d => ({
    tender_id: tenderId!,
    url: String(d.url),
    mime: d.mime ?? null,
    kind: d.kind ?? null,
    status: "queued",
  }));

  const { data, error } = await supa
    .from("tender_docs")
    .upsert(payload, { onConflict: "tender_id,url", ignoreDuplicates: false })
    .select("id");

  if (error) {
    console.error("ingest tender-docs error:", error);
    return NextResponse.json({ error: error.message }, { status: 500 });
  }

  return NextResponse.json({ upserted: data?.length ?? 0, tenderId });
}
EOF

echo "==> Ajoute le workflow n8n autonome + doc"

mkdir -p n8n docs

cat > n8n/portail_full_autonomous.json <<'EOF'
{
  "name": "portail_full_autonomous",
  "nodes": [
    {
      "parameters": { "triggerTimes": { "item": [ { "mode": "everyX", "unit": "hours", "value": 2 } ] } },
      "name": "Cron (2h)",
      "type": "n8n-nodes-base.cron",
      "typeVersion": 1,
      "position": [240, 320]
    },
    {
      "parameters": {
        "mode": "passThrough",
        "options": {
          "values": { "string": [
            { "name": "listUrl",  "value": "https://portail.marchespublics.nc/?page=Entreprise.EntrepriseAdvancedSearch&AllCons" },
            { "name": "userAgent","value": "LegalNCBot/1.0 (+contact@legalnc)" },
            { "name": "baseUrl",  "value": "http://localhost:3000" },
            { "name": "ingestKey","value": "REPLACE_WITH_INGEST_SECRET" }
          ] }
        }
      },
      "name": "Config",
      "type": "n8n-nodes-base.set",
      "typeVersion": 2,
      "position": [480, 320]
    },
    {
      "parameters": {
        "url": "={{$json.listUrl}}",
        "options": { "headers": { "User-Agent": "={{$json.userAgent}}" }, "ignoreResponseCode": true, "fullResponse": true }
      },
      "name": "Fetch Listing",
      "type": "n8n-nodes-base.httpRequest",
      "typeVersion": 4,
      "position": [720, 320]
    },
    {
      "parameters": {
        "functionCode": "const body = $json.body?.toString?.() || $json.body || ''; const re = /href=\\\"([^\\\"]*\\/entreprise\\/consultation\\/(\\d+)\\?orgAcronyme=([A-Za-z0-9]+))\\\"/g; const out=[]; const seen=new Set(); let m; while((m=re.exec(body))){ const url=new URL(m[1],'https://portail.marchespublics.nc').toString(); const id=m[2], org=m[3]; const key=id+':'+org; if(seen.has(key)) continue; seen.add(key); out.push({ json: { id, org, url } }); } return out;"
      },
      "name": "Extract Consultation URLs",
      "type": "n8n-nodes-base.function",
      "typeVersion": 2,
      "position": [960, 320]
    },
    {
      "parameters": {
        "url": "={{$json.url}}",
        "options": { "headers": { "User-Agent": "={{$json.userAgent}}" }, "ignoreResponseCode": true, "fullResponse": true }
      },
      "name": "Fetch Consultation",
      "type": "n8n-nodes-base.httpRequest",
      "typeVersion": 4,
      "position": [1200, 320]
    },
    {
      "parameters": {
        "functionCode": "const html = $json.body?.toString?.() || $json.body || ''; function stripTags(s){return (s||'').replace(/<[^>]+>/g,' ').replace(/\\s+/g,' ').trim();} const deadline=(html.match(/Date et heure limite de remise des plis\\s*:\\s*([^<]+)/i)||[])[1]||''; const reference=(html.match(/R[ée]f[ée]rence\\s*:\\s*([^<]+)/i)||html.match(/Référence\\s*:\\s*([^<]+)/i)||[]; const referenceVal=Array.isArray(reference)?reference[1]||'':reference; const intitule=(html.match(/Intitul[ée]\\s*:\\s*([^<]+)/i)||[])[1]||''; const organisme=(html.match(/Organisme\\s*:\\s*([^<]+)/i)||[])[1]||''; const service=(html.match(/Service\\s*:\\s*([^<]+)/i)||[])[1]||''; const cpv=(html.match(/Code CPV\\s*:\\s*([^<]+)/i)||[])[1]||''; const hrefs=Array.from(html.matchAll(/href=\\\"([^\\\"]+\\.(?:pdf|PDF|docx|DOCX|doc|DOC))\\\"/g)).map(m=>m[1]); const absolute=hrefs.map(h=>h.startsWith('http')?h:new URL(h,'https://portail.marchespublics.nc').toString()); return [{ json: { id:$item(0).$node['Extract Consultation URLs'].json.id, org:$item(0).$node['Extract Consultation URLs'].json.org, url:$item(0).$node['Extract Consultation URLs'].json.url, tender:{ source:'portail.marchespublics.nc', ref:$item(0).$node['Extract Consultation URLs'].json.id+':'+$item(0).$node['Extract Consultation URLs'].json.org, buyer:stripTags(organisme||service||'Inconnu'), title:stripTags(intitule||referenceVal||'Consultation'), deadline_at:(()=>{const m=(deadline||'').match(/(\\d{2})\\/(\\d{2})\\/(\\d{4})\\s+(\\d{2}):(\\d{2})/); if(!m) return null; const[_,d,M,Y,h,mn]=m; return `${Y}-${M}-${d}T${h}:${mn}:00+11:00`;})(), url:$item(0).$node['Extract Consultation URLs'].json.url, raw_json:{service,cpv} }, docs:absolute } }];"
      },
      "name": "Parse Consultation → Tender + Docs",
      "type": "n8n-nodes-base.function",
      "typeVersion": 2,
      "position": [1440, 320]
    },
    {
      "parameters": {
        "url": "={{$json.baseUrl}}/api/ingest/tenders",
        "options": { "headers": { "x-ingest-key":"={{$json.ingestKey}}","Content-Type":"application/json" } },
        "sendBody": true,
        "jsonParameters": true,
        "bodyParametersJson": "={{ { items: [$json.tender] } }}"
      },
      "name": "UPSERT /ingest/tenders",
      "type": "n8n-nodes-base.httpRequest",
      "typeVersion": 4,
      "position": [1680, 320]
    },
    {
      "parameters": {
        "functionCode": "const res=$json; const ref=$item(0).$node['Parse Consultation → Tender + Docs'].json.tender.ref; const item=(res.items||[]).find((x)=>x.ref===ref); if(!item){return[{json:{error:'missing id after upsert',ref}}];} return[{json:{tenderId:item.id, source:'portail.marchespublics.nc', ref, docs:$item(0).$node['Parse Consultation → Tender + Docs'].json.docs}}];"
      },
      "name": "Resolve id",
      "type": "n8n-nodes-base.function",
      "typeVersion": 2,
      "position": [1920, 320]
    },
    {
      "parameters": {
        "url": "={{$json.baseUrl}}/api/ingest/tender-docs",
        "options": { "headers": { "x-ingest-key":"={{$json.ingestKey}}","Content-Type":"application/json" } },
        "sendBody": true,
        "jsonParameters": true,
        "bodyParametersJson": "={{ $json }}"
      },
      "name": "POST /ingest/tender-docs",
      "type": "n8n-nodes-base.httpRequest",
      "typeVersion": 4,
      "position": [2160, 320]
    },
    {
      "parameters": { "milliseconds": 800 },
      "name": "Wait 0.8s",
      "type": "n8n-nodes-base.wait",
      "typeVersion": 1,
      "position": [2380, 320]
    },
    {
      "parameters": {
        "url": "={{$json.baseUrl}}/api/parse/tender/{{$json.tenderId}}",
        "options": { "headers": { "x-parse-key": "={{$json.ingestKey}}" } }
      },
      "name": "POST /parse/tender/:id",
      "type": "n8n-nodes-base.httpRequest",
      "typeVersion": 4,
      "position": [2600, 320]
    }
  ],
  "connections": {
    "Cron (2h)": { "main": [ [ { "node": "Config", "type": "main", "index": 0 } ] ] },
    "Config": { "main": [ [ { "node": "Fetch Listing", "type": "main", "index": 0 } ] ] },
    "Fetch Listing": { "main": [ [ { "node": "Extract Consultation URLs", "type": "main", "index": 0 } ] ] },
    "Extract Consultation URLs": { "main": [ [ { "node": "Fetch Consultation", "type": "main", "index": 0 } ] ] },
    "Fetch Consultation": { "main": [ [ { "node": "Parse Consultation → Tender + Docs", "type": "main", "index": 0 } ] ] },
    "Parse Consultation → Tender + Docs": { "main": [ [ { "node": "UPSERT /ingest/tenders", "type": "main", "index": 0 } ] ] },
    "UPSERT /ingest/tenders": { "main": [ [ { "node": "Resolve id", "type": "main", "index": 0 } ] ] },
    "Resolve id": { "main": [ [ { "node": "POST /ingest/tender-docs", "type": "main", "index": 0 } ] ] },
    "POST /ingest/tender-docs": { "main": [ [ { "node": "Wait 0.8s", "type": "main", "index": 0 } ] ] },
    "Wait 0.8s": { "main": [ [ { "node": "POST /parse/tender/:id", "type": "main", "index": 0 } ] ] }
  }
}
EOF

cat > docs/N8N_AUTONOMOUS_SETUP.md <<'EOF'
# Scraping autonome portail.marchespublics.nc — toutes les 2h

## Prérequis
- `.env.local` contient `INGEST_SECRET=...`
- Tables/Index existent (`tenders`, `tender_docs`, `tender_requirements`), RLS OK.

## Déploiement
1) Importez `n8n/portail_full_autonomous.json` dans n8n.  
2) Dans le node **Config**:
   - `baseUrl` = URL de votre app (ex: http://localhost:3000)
   - `ingestKey` = valeur de `INGEST_SECRET`
3) Laissez le Cron à **2h** puis **Execute Once** pour tester.

## Ce que fait le workflow
- Récupère la page AllCons, extrait toutes les URLs de consultations,
- Pour chaque consultation: parse les champs (Référence, Intitulé, Organisme, Deadline) et les liens PDF/DOCX/DOC,
- **Upsert** dans `tenders` (idempotent sur (source,ref)),
- **Upsert** les docs dans `tender_docs`,
- **Parse** les docs et renseigne `tender_requirements`.

## Déduplication
- `tenders(source,ref)` unique
- `tender_docs(tender_id,url)` unique
- L’étape parse ne traite que `status in ('queued','pending')`

## Vérification
- Après un run: connectez-vous, visitez `/tenders` (liste),
- Ouvrez `/tenders/<ID>/requirements` pour voir la check-list extraite.
EOF

echo "==> Done. Maintenant: git add . && git commit -m 'feat: n8n autonomous scraper' && git push"
