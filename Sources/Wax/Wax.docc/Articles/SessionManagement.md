# Session Management

Understand how Wax manages writer leases and sessions internally.

## Public Lifecycle

External packages should open and close the public ``Memory`` facade:

```swift
var config = Memory.Config()
config.enableVectorSearch = false
let memory = try await Memory(at: storeURL, config: config)

try await memory.save("The user prefers short status updates.")

var options = Memory.SearchOptions()
options.mode = .textOnly
let context = try await memory.search("communication preference", options: options)

try await memory.close()
```

`WaxSession` is package-internal in the main Wax target. Use it only when
developing Wax itself.

## Internal Session Modes

Internally, Wax uses read-only and read-write sessions:

| Mode | Role |
|------|------|
| Read-only | Search and read frames without acquiring a writer lease |
| Read-write | Acquire a writer lease for exclusive writes and commits |

Multiple read-only sessions can operate concurrently. Only one read-write
session can be active at a time.

## Internal Writer Policies

The internal writer policy controls what happens when another writer already
holds the lease:

| Policy | Behavior |
|--------|----------|
| `wait` | Suspend until the lease becomes available |
| `fail` | Throw immediately |
| `timeout` | Wait up to a duration, then throw |

## Agent Sessions

The MCP server exposes broker-managed virtual sessions through unprefixed tool
names such as `session_start`, `remember`, `recall`, `handoff`, and
`session_end`. These are separate from the package-internal `WaxSession` type.

Normal coding-agent flows should not manage raw store paths or call `flush`;
the broker owns long-term memory and virtual session stores.
