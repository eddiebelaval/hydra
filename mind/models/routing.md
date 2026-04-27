# Routing Heuristics

Rules for intent classification. These are applied in order.

## Stage 0: Sticky Sessions

If Eddie is already in conversation with an entity and the session hasn't timed out (15 minutes of inactivity), keep routing to that entity. Conversations have gravity. A topic mention doesn't mean a topic change.

Exception: Eddie explicitly names another entity ("ask Axis", "@iris", "switch to Milo") or uses a slash command (/axis, /iris, /milo).

After 10+ messages to the same entity without a reroute, skip classification entirely. Eddie is deep in conversation. Don't interrupt.

## Stage 1: Keyword Detection (Zero Cost)

Before any LLM call, check for unambiguous signals:

**Route to HYDRA:**
- Eddie mentions "hydra" by name
- System words: daemon, status, health, uptime, entity, route, switch
- "Who am I talking to"

**Route to named entity:**
- "@axis", "@iris", "@milo"
- "ask axis", "ask iris", "ask milo"
- "switch to [entity]"
- "/axis", "/iris", "/milo"

If keyword match is confident, skip LLM classification entirely.

## Stage 2: LLM Classification

For ambiguous messages, use a lightweight model (Haiku) with structured output.

Input: entity registry (from entities.md), last 3 user messages for context, the new message.
Output: entity name, confidence score (0-1), brief reason.

**Confidence thresholds:**
- >= 0.7: Route to classified entity
- < 0.7: Keep current entity (if in active session) or default to Milo

## Disambiguation Patterns

| Message Pattern | Entity | Why |
|----------------|--------|-----|
| "How's Homer doing" | Milo | Project tracking is accountability |
| "Should we change Homer's pricing" | Axis | Business decision |
| "Homer's landing page feels off" | Iris | Visual judgment |
| "Is the Homer daemon running" | HYDRA | System status |
| "I'm stressed about the launch" | Milo | Emotional processing |
| "We need to rethink the launch strategy" | Axis | Strategic decision |
| "The launch page needs work" | Iris | Design |

## Anti-Patterns

Things that should NOT trigger a reroute:
- Mentioning a business metric in casual conversation (stay with Milo)
- Describing a feeling about a design decision (stay with Iris)
- Asking about a project while discussing strategy (stay with Axis)
- Using a domain-specific word in a different context
