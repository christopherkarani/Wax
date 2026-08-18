import WaxCore
import WaxVectorSearch

// Explicit public re-exports of the WaxCore/WaxVectorSearch types that are part of
// Wax's documented public API (see Resources/skills/public/wax/references/public-api.md).
// Anything not listed here is an implementation detail; add a typealias only together
// with a docs entry. `@_exported import` was removed because it silently leaks every
// public symbol of the underlying modules into Wax's namespace.

public typealias WaxError = WaxCore.WaxError

public typealias EmbeddingProvider = WaxVectorSearch.EmbeddingProvider
public typealias BatchEmbeddingProvider = WaxVectorSearch.BatchEmbeddingProvider
public typealias QueryAwareEmbeddingProvider = WaxVectorSearch.QueryAwareEmbeddingProvider
public typealias EmbeddingIdentity = WaxVectorSearch.EmbeddingIdentity
public typealias ProviderExecutionMode = WaxVectorSearch.ProviderExecutionMode
public typealias VectorEnginePreference = WaxVectorSearch.VectorEnginePreference
