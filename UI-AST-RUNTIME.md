```markdown
# Visual Statechart Editor & SCXML Execution Engine Specification

This specification defines a language-agnostic architecture for a visual statechart editor, an intermediate document representation (AST), an SCXML parser/serializer, and a high-performance runtime execution engine.

---

## 1. System Architecture & Separation of Concerns

The architecture strictly decouples visual editing, document representation, interchange formats, and execution logic using a three-tier model:
```

┌────────────────────────────────────────────────────────────────────────┐
│ Visual Canvas Layer │
│ (Handles drag-and-drop, UI rendering, layout handles, node placement) │
└───────────────────────────────────┬────────────────────────────────────┘
│ Bidirectional Sync
▼
┌────────────────────────────────────────────────────────────────────────┐
│ Canonical Document AST │
│ (Single source of truth: Semantics + Embedded Visual UI Metadata) │
└───────────────────┬────────────────────────────────┬───────────────────┘
│ │
│ Export / Import │ Compilation Step
▼ ▼
┌──────────────────────────────────────┐ ┌──────────────────────────────┐
│ SCXML File Format │ │ Compiled Runtime Graph │
│ (Portable W3C XML + ) │ │ (Flat O(1) execution engine) │
└──────────────────────────────────────┘ └──────────────────────────────┘

````

1. **Visual Canvas Layer:** Responsible only for UI interaction, user input, drag-and-drop coordinates, edge routing, and view state.
2. **Canonical AST (JSON Object):** The central, normalized data structure representing the full statechart topology, executable actions, guards, and layout coordinates.
3. **SCXML Generator / Parser:** A bidirectional translation layer that maps between W3C SCXML XML documents and the Canonical AST, preserving layout details inside SCXML `<metadata>` nodes.
4. **Compiled Runtime Graph:** An optimized execution representation containing flattened $O(1)$ state lookups, ancestor chains, event matchers, and pre-computed Least Common Ancestor (LCA) transition entry/exit paths.

---

## 2. Canonical AST Schema Specification

The Canonical AST represents statechart structure independently of programming languages. Layout metadata is isolated within a `ui` block to allow clean stripping during runtime compilation.

### AST Node Data Types

* **Document:** Root node holding metadata, initial state reference, datamodel, and top-level states.
* **State Node:** Represens an Atomic, Compound, Parallel, History, or Final state.
* **Transition Node:** Represents outgoing edges containing event signatures, guard condition strings, target state IDs, and internal executable action lists.

### Schema Definition (JSON)

```json
{
  "$schema": "[http://json-schema.org/draft-07/schema#](http://json-schema.org/draft-07/schema#)",
  "title": "CanonicalStatechartAST",
  "type": "object",
  "required": ["id", "initial", "states"],
  "properties": {
    "id": { "type": "string" },
    "initial": { "type": "string" },
    "version": { "type": "string", "default": "1.0" },
    "datamodel": {
      "type": "object",
      "additionalProperties": true
    },
    "states": {
      "type": "object",
      "additionalProperties": { "$ref": "#/definitions/StateNode" }
    }
  },
  "definitions": {
    "StateNode": {
      "type": "object",
      "required": ["id", "type"],
      "properties": {
        "id": { "type": "string" },
        "type": { "type": "string", "enum": ["atomic", "compound", "parallel", "history", "final"] },
        "initial": { "type": "string" },
        "onEntry": { "type": "array", "items": { "$ref": "#/definitions/ActionNode" } },
        "onExit": { "type": "array", "items": { "$ref": "#/definitions/ActionNode" } },
        "transitions": { "type": "array", "items": { "$ref": "#/definitions/TransitionNode" } },
        "states": {
          "type": "object",
          "additionalProperties": { "$ref": "#/definitions/StateNode" }
        },
        "ui": {
          "type": "object",
          "properties": {
            "x": { "type": "number" },
            "y": { "type": "number" },
            "width": { "type": "number" },
            "height": { "type": "number" }
          }
        }
      }
    },
    "TransitionNode": {
      "type": "object",
      "properties": {
        "id": { "type": "string" },
        "event": { "type": "string" },
        "target": { "type": "string" },
        "type": { "type": "string", "enum": ["external", "internal"], "default": "external" },
        "cond": { "type": "string" },
        "actions": { "type": "array", "items": { "$ref": "#/definitions/ActionNode" } },
        "ui": {
          "type": "object",
          "properties": {
            "sourceHandle": { "type": "string" },
            "targetHandle": { "type": "string" },
            "waypoints": {
              "type": "array",
              "items": {
                "type": "object",
                "properties": { "x": { "type": "number" }, "y": { "type": "number" } }
              }
            }
          }
        }
      }
    },
    "ActionNode": {
      "type": "object",
      "required": ["type"],
      "properties": {
        "type": { "type": "string" },
        "params": { "type": "object" }
      }
    }
  }
}

````

---

## 3. SCXML Interchange: Parsing and Serialization Algorithms

To support round-tripping between visual tools and standard SCXML files, UI positioning data is encoded inside an SCXML `<metadata>` block using custom XML elements.

### Serializer Algorithm (AST → SCXML String)

1. **Initialize Buffer:** Open root `<scxml>` element with namespace `http://www.w3.org/2005/07/scxml` and set the `initial` attribute.
2. **Recursive Node Traversal:** For each state in `doc.states`:

- Determine XML tag name (`<state>`, `<parallel>`, `<final>`, `<history>`).
- Write element attributes (`id`, `initial`).
- If `state.ui` exists, emit:

```xml
<metadata>
  <layout:node x="..." y="..." width="..." height="..." xmlns:layout="[http://example.com/scxml-layout](http://example.com/scxml-layout)"/>
</metadata>

```

- Process `onEntry` actions into `<onentry>` blocks and `onExit` actions into `<onexit>` blocks.
- Process `transitions` into `<transition>` tags, mapping `event`, `target`, `type`, and `cond` properties. Embed transition routing waypoints inside `<metadata>` if present.
- Recursively serialize nested `state.states`.

3. **Finalize Buffer:** Close root `</scxml>` element.

### Parser Algorithm (SCXML String → AST)

1. **Parse XML Tree:** Stream or parse the XML document into an in-memory element DOM/tree.
2. **Extract Root Attributes:** Read `initial` and `id` from the root `<scxml>` tag.
3. **Traverse Child Tags Recursively:**

- For each `<state>`, `<parallel>`, `<final>`, or `<history>` tag:
- Extract `id` and state type.
- Search for child `<metadata>` nodes containing layout attributes (`x`, `y`, `width`, `height`). Extract into `state.ui`.
- Extract `<onentry>` and `<onexit>` child elements into action lists.
- Extract `<transition>` elements into transition objects. Read routing waypoints from transition `<metadata>` nodes.
- Recursively process nested state tags.

4. **Emit Normalized AST:** Return the structured JSON document.

---

## 4. Derived Runtime Graph Compilation Algorithm

To execute statechart microsteps efficiently without tree-traversal overhead, compile the hierarchical AST into a flattened graph.

### Target Compilation Structures

- **States Map (`states_by_id`):** Hash Map mapping `StateID -> CompiledState`.
- **Parent Map (`parent_map`):** Hash Map mapping `ChildStateID -> ParentStateID`.
- **Ancestors Map (`ancestors`):** Hash Map mapping `StateID -> List[ParentStateID]` (ordered from immediate parent up to root).
- **Indexed Transitions (`event_transitions`):** Hash Map mapping `EventPattern -> List[CompiledTransition]`.

### Pre-Computing Transition LCA Paths

For every transition, the execution path (states exited and states entered) is constant and must be pre-calculated during compilation using the Least Common Ancestor (LCA) algorithm.

```
Algorithm: ComputeTransitionPath(source_id, target_id, parent_map, ancestors)
Input: Source state ID, Target state ID, Parent Map, Ancestors Map
Output: ExitSet (List of state IDs), EntrySet (List of state IDs)

1. If target_id is null/undefined (Internal transition without state change):
     Return ExitSet = [], EntrySet = []

2. source_ancestors = [source_id] + ancestors[source_id]
3. target_ancestors = [target_id] + ancestors[target_id]

4. lca = null
5. For each state_id in source_ancestors:
     If state_id exists in target_ancestors:
       lca = state_id
       Break Loop

6. ExitSet = All states in source_ancestors from source_id up to (excluding) lca
7. RawEntrySet = All states in target_ancestors from target_id up to (excluding) lca
8. EntrySet = Reverse(RawEntrySet)

9. Return (ExitSet, EntrySet)

```

---

## 5. Language-Agnostic Execution Engine Specification

The execution engine runs as an event loop maintaining an **Active Configuration Set** ($A$), an **Internal Queue** ($Q_{int}$), and an **External Queue** ($Q_{ext}$).

### Runtime State Memory Representation

```
Runtime Engine Context:
  - active_configuration: Set[String] (Set of currently active state IDs)
  - datamodel: Map[String, Any] (Environment variables and data)
  - internal_queue: FIFO Queue of Event Objects
  - external_queue: FIFO Queue of Event Objects
  - compiled_graph: Compiled Runtime Graph Reference

```

### Event Matching Algorithm

Given a candidate transition event pattern string ($P$) and an incoming event name string ($E$):

```
Algorithm: MatchEvent(pattern, event_name)
1. If pattern is null or empty string: Return False (Eventless transition, evaluated separately)
2. If pattern == "*": Return True
3. If pattern == event_name: Return True
4. If pattern ends with ".*":
     prefix = pattern without ".*"
     If event_name starts with (prefix + ".") or event_name == prefix:
       Return True
5. If pattern contains spaces (tokenized patterns like "A B"):
     For each token in Split(pattern, " "):
       If MatchEvent(token, event_name) is True: Return True
6. Return False

```

### Macrostep & Microstep Interpreter Engine Loop

```
Algorithm: StepEngine(EngineContext, incoming_event)
Input: Engine Context, External Event Object

1. Push incoming_event to EngineContext.external_queue
2. While EngineContext.external_queue is not empty OR EngineContext.internal_queue is not empty:

     If EngineContext.internal_queue is not empty:
       current_event = Pop(EngineContext.internal_queue)
     Else:
       current_event = Pop(EngineContext.external_queue)

     EngineContext.datamodel["_event"] = current_event

     // 1. Select Enabled Transitions
     enabled_transitions = []
     For each state_id in EngineContext.active_configuration:
       state_transitions = EngineContext.compiled_graph.states[state_id].transitions
       For each transition in state_transitions:
         If MatchEvent(transition.event, current_event.name) is True:
           If transition.cond is null OR EvaluateGuard(transition.cond, EngineContext.datamodel) is True:
             Append transition to enabled_transitions
             Break // First matching transition per active state takes priority

     // 2. Execute Microstep if transitions exist
     If enabled_transitions is not empty:
       For each transition in enabled_transitions:

         // A. Exit States (Bottom-up execution)
         For each exit_id in transition.exit_set:
           If exit_id in EngineContext.active_configuration:
             ExecuteOnExitActions(exit_id, EngineContext)
             Remove exit_id from EngineContext.active_configuration

         // B. Execute Transition Actions
         ExecuteActionList(transition.actions, EngineContext)

         // C. Enter States (Top-down execution)
         For each entry_id in transition.entry_set:
           ExecuteOnEntryActions(entry_id, EngineContext)
           Add entry_id to EngineContext.active_configuration

           // If compound state entered without explicit atomic target, enter initial state
           If EngineContext.compiled_graph.states[entry_id].type == "compound":
             initial_child = EngineContext.compiled_graph.states[entry_id].initial
             Add initial_child to EngineContext.active_configuration
             ExecuteOnEntryActions(initial_child, EngineContext)

     // 3. Evaluate Eventless / Null Transitions (Microstep Completion)
     EvaluateEventlessTransitions(EngineContext)

```

---

## 6. Implementation Checklist for Any Tech Stack

1. **Data Model Layer:** Implement JSON Schema validation for the Canonical AST format.
2. **Serializer/Parser:** Write the XML $\leftrightarrow$ JSON converter, ensuring layout elements in `<metadata>` tags correctly survive round-trips.
3. **Compiler:** Implement the graph compiler to flatten nested structures, build parent lookup tables, and compute the transition entry/exit paths via the LCA algorithm.
4. **Engine Core:** Build an event loop handling active state sets (`Set`), FIFO event queues, event wildcard matching, and the microstep/macrostep interpreter state machine.

```

```
