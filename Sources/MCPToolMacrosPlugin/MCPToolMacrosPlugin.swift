// Re-export the macro definition and related utilities
@_exported import MCP

// MARK: - SchemaProviding Protocol
public protocol SchemaProviding {
    static var inputSchema: MCP.Value { get }
}
