---
type: reference
last_verified: 2026-05-22
owner: orchestrator-installer
---

# Notion Skill

Covers: auth, database setup, NotionTicket shape, write tool implementations, rate-limit handling.

## Auth

```bash
NOTION_API_KEY=secret_...     # Notion integration token
TRACKER_DATABASE_ID=<db-id>  # 32-char database ID from Notion URL
```

The integration must be shared with the target database in Notion (database `...` menu → Connections).

## Getting the database ID

The database ID comes from the Notion URL. Two URL formats exist:

```
# Format 1 — database is a standalone page:
https://www.notion.so/<workspace>/<DATABASE_ID>?v=<view-id>

# Format 2 — database is inline in a page (no workspace prefix):
https://www.notion.so/<DATABASE_ID>?v=<view-id>
```

The 32-char hex string before `?v=` is the database ID. **Do not use the page ID** that contains the database — Notion returns `"Provided ID is a page, not a database"`.

## Database setup

Before the orchestrator can run, the Notion database must have these properties. Use the API to create them if they don't exist:

```bash
curl -s -X PATCH "https://api.notion.com/v1/databases/<DATABASE_ID>" \
  -H "Authorization: Bearer $NOTION_API_KEY" \
  -H "Notion-Version: 2022-06-28" \
  -H "Content-Type: application/json" \
  -d '{
    "properties": {
      "Status": { "status": {} },
      "Priority": {
        "select": {
          "options": [
            {"name": "Urgent", "color": "red"},
            {"name": "High", "color": "orange"},
            {"name": "Medium", "color": "yellow"},
            {"name": "Low", "color": "gray"}
          ]
        }
      },
      "URL": { "url": {} }
    }
  }'
```

To verify the database has the right properties:
```bash
curl -s "https://api.notion.com/v1/databases/<DATABASE_ID>" \
  -H "Authorization: Bearer $NOTION_API_KEY" \
  -H "Notion-Version: 2022-06-28" \
  | python3 -c "import json,sys; [print(f'{n} ({p[\"type\"]})') for n,p in json.load(sys.stdin)['properties'].items()]"
```

## Status option casing

Notion's default Status property uses **lowercase "In progress"** (not "In Progress"). Always check exact option names via the database schema API before setting `TRACKER_CANDIDATE_STATES`. Set `WORKFLOW.md` states to match exactly.

Default Notion status options: `Not started`, `In progress`, `Done`, `To-do`, `In progress`, `Complete`

## NotionTicket shape

```typescript
interface NotionTicket extends BaseTicket {
  database_id: string;                     // TRACKER_DATABASE_ID
  properties: Record<string, unknown>;     // raw Notion property bag
  page_url: string;                        // canonical page URL
}
```

Mapping Notion API response to NotionTicket:
- `id` → page ID (format: `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`)
- `identifier` → `NOTION-<page-id>` (prefixed for readability)
- `title` → find the property with `type === "title"`, join `plain_text` values
- `state` → `properties.Status.status.name`
- `priority` → `properties.Priority.select.name` mapped to integer (Urgent=1, High=2, Medium=3, Low=4)
- `url` → `url` field from API response

## fetchCandidateTickets() implementation

```typescript
async fetchCandidateTickets(): Promise<NotionTicket[]> {
  const filter = this.candidateStates.length === 1
    ? { property: "Status", status: { equals: this.candidateStates[0] } }
    : { or: this.candidateStates.map((s) => ({ property: "Status", status: { equals: s } })) };

  const response = await fetch(`https://api.notion.com/v1/databases/${this.databaseId}/query`, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${this.apiKey}`,
      "Notion-Version": "2022-06-28",
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ filter, sorts: [{ property: "Priority", direction: "ascending" }] }),
  });
  if (!response.ok) throw new Error(`Notion API ${response.status}: ${await response.text()}`);
  const data = await response.json() as { results: unknown[] };
  return data.results.map((page) => this.mapPage(page));
}
```

## fetchTicketStatesByIds() implementation

IDs are stored as `NOTION-<pageId>` — strip the prefix before calling the API:

```typescript
async fetchTicketStatesByIds(ids: string[]): Promise<Map<string, string>> {
  const map = new Map<string, string>();
  for (const id of ids) {
    const pageId = id.startsWith("NOTION-") ? id.slice(7) : id;
    const res = await fetch(`https://api.notion.com/v1/pages/${pageId}`, {
      headers: { "Authorization": `Bearer ${this.apiKey}`, "Notion-Version": "2022-06-28" },
    });
    if (!res.ok) continue;
    const page = await res.json() as Record<string, unknown>;
    const props = page.properties as Record<string, unknown>;
    const state = (props.Status as any)?.status?.name;
    if (state) map.set(id, state);
  }
  return map;
}
```

## Rate limits

Notion API: 3 requests/second average. Under concurrent agent sessions:
- Add 350ms delay between consecutive API calls.
- On 429 response: wait `Retry-After` header seconds, then retry once.

## Agent write tools (getAgentTools())

Four required tools for agents to write back to Notion:

| Tool | API call |
|------|----------|
| `notion_update_page` | `PATCH /v1/pages/<id>` — update properties |
| `notion_append_block` | `PATCH /v1/blocks/<id>/children` — append content |
| `notion_create_comment` | `POST /v1/comments` — add comment to page |
| `notion_set_property` | `PATCH /v1/pages/<id>` with single property — set one field |

Implement as an in-process MCP server using `createSdkMcpServer()`.

**IMPORTANT:** `tool()` takes positional args `(name, description, inputSchema, handler)` — NOT an object. Handler must return `{ content: [{ type: "text" as const, text: string }] }`.

```typescript
import { createSdkMcpServer, tool } from "@anthropic-ai/claude-agent-sdk";
import { z } from "zod";

const server = createSdkMcpServer({
  name: "notion-tools",
  tools: [
    tool(
      "notion_set_property",
      "Set a property on a Notion page. Use to transition ticket state.",
      {
        page_id: z.string().describe("Notion page ID"),
        property_name: z.string().describe("Property name (e.g., 'Status')"),
        property_value: z.string().describe("New value"),
      },
      async ({ page_id, property_name, property_value }) => {
        const res = await fetch(`https://api.notion.com/v1/pages/${page_id}`, {
          method: "PATCH",
          headers: { "Authorization": `Bearer ${apiKey}`, "Notion-Version": "2022-06-28", "Content-Type": "application/json" },
          body: JSON.stringify({ properties: { [property_name]: { status: { name: property_value } } } }),
        });
        if (!res.ok) throw new Error(`notion_set_property failed: ${res.status} ${await res.text()}`);
        return { content: [{ type: "text" as const, text: `Set ${property_name} to "${property_value}" on ${page_id}` }] };
      },
    ),
    // notion_update_page, notion_append_block, notion_create_comment follow the same pattern
  ],
});

// Return as McpServerConfig
return { "notion-tools": server as unknown as McpServerConfig };
```

## .env.example entries for Notion

```bash
CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-...
NOTION_API_KEY=secret_...
TRACKER_DATABASE_ID=<32-char-database-id>
TRACKER_CANDIDATE_STATES=In progress    # must match Notion's exact casing
ORCHESTRATOR_CWD=/absolute/path/to/repo
```
