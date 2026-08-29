class Wax < Formula
  desc "On-device memory and RAG framework with MCP server for Claude Code"
  homepage "https://github.com/christopherkarani/Wax"
  url "https://github.com/christopherkarani/Wax/archive/refs/tags/waxmcp-v0.1.37.tar.gz"
  sha256 "5b52ad13e74e5960f7342c55b3dea9ef062aab04a48f01a93e68def001647459"
  license "MIT"

  depends_on xcode: ["16.3", :build]

  def install
    # The upstream repo defines a `waxTests` target with a custom path of
    # `Tests/WaxTests`, but empty directories aren't included in GitHub source
    # archives. Ensure the directory exists so SwiftPM's package graph
    # validation succeeds.
    mkdir_p "Tests/WaxTests"

    system "swift", "build", "--disable-sandbox", "-c", "release",
           "--product", "wax-cli", "--traits", "default,MCPServer"
    system "swift", "build", "--disable-sandbox", "-c", "release",
           "--product", "wax-mcp", "--traits", "default,MCPServer"

    libexec.install ".build/release/wax-cli" => "waxmcp"
    libexec.install ".build/release/wax-mcp"
    libexec.install Dir[".build/release/*.bundle"]

    rm_f bin/"waxmcp"
    rm_f bin/"wax-mcp"
    bin.write_exec_script libexec/"waxmcp"
    bin.write_exec_script libexec/"wax-mcp"
  end

  test do
    output = shell_output("#{bin}/waxmcp --help")
    assert_match "USAGE:", output

    health = shell_output("#{bin}/waxmcp vector-health --format text --store-path #{testpath}/health.wax")
    assert_match "Vector health: PASS", health
  end
end
