/// Single source of truth for the shipped release version.
///
/// `wax-mcp` server info, `wax-mcp --version`, and `wax-cli --version` all read
/// this constant. `Resources/scripts/sync-waxmcp-version.sh` rewrites it to
/// match `Resources/npm/waxmcp/package.json`, and CI checks the two agree.
package enum WaxReleaseInfo {
    package static let version = "0.1.50"
}
