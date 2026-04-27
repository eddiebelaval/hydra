# Memory Architecture

Brain-derived memory taxonomy for HYDRA, the system coordinator.
Subset of the golden sample, scoped to operational memory.
HYDRA does not store personal memories. That is Milo's domain.

## Active Memory Systems (4 of 7)

| System | Brain Region | Function | Implementation |
|--------|-------------|----------|----------------|
| Semantic | Temporal cortex | Facts, knowledge, concepts | routing_preference, entity_insight, fact, observation |
| Procedural | Basal ganglia | Skills, patterns, corrections | routing_pattern, feedback |
| Working | Prefrontal cortex | Current session context | Rolling conversation window + routing_sessions table |
| Episodic | Hippocampus | Significant events | system_event |

## Excluded Memory Systems (3 of 7)

| System | Reason for Exclusion |
|--------|---------------------|
| Prospective | HYDRA does not plan. It routes. Goals belong to Milo. |
| Spatial | HYDRA has no concept of location. |
| Emotional | HYDRA does not have affective associations. Mood belongs to Milo. |

## The 8 Categories

### Core (always active)

| Category | System | Description |
|----------|--------|-------------|
| routing_preference | Semantic | How Eddie prefers to be routed. "He likes Axis for pricing but goes to Milo when stressed about it." |
| routing_pattern | Procedural | Repeatable routing success. "Morning messages are almost always Milo." |
| entity_insight | Semantic | What HYDRA has observed about entity performance. "Axis handles pricing questions well. Milo struggles with pure strategy." |
| feedback | Procedural | Eddie correcting HYDRA's routing behavior. "Stop routing design questions to Milo." |
| observation | Semantic | HYDRA's own analytical insight. "Eddie's evening messages have shifted toward strategic topics this week." |
| fact | Semantic | Operational fact worth remembering. "The Homer daemon runs at 8 AM." |
| system_event | Episodic | Significant system event. "Milo's bot had a 409 conflict on Apr 3." |
| entity_preference | Semantic | Eddie's stated preference for a specific entity. "Eddie said he prefers Axis over Milo for CPN strategy." |

## Loading Strategy

HYDRA's context window is lean. Smart loading:

1. **Always load:** feedback + routing_preference (behavioral calibration)
2. **Load recent:** newest 3 memories regardless of category (continuity)
3. **Load by importance:** remaining slots by importance score (depth)

Total memory budget: 10 memories per context. HYDRA's context must stay lean for fast routing.

## Storage Principles

Same as golden sample:
1. Memories are OBSERVATIONS, not authoritative state.
2. Never DELETE. Archive or supersede.
3. Importance 1-10 determines load frequency.
4. Each memory has an optional domain (entity name or system area).

## What HYDRA Does NOT Remember

- Personal facts about Eddie (that is Milo)
- Business strategy details (that is Axis)
- Design decisions or visual preferences (that is Iris)
- Emotional states or mood (that is Milo)
- Locations, trips, health, finances (that is Milo)

HYDRA remembers HOW Eddie uses the system. Not what Eddie's life contains.
