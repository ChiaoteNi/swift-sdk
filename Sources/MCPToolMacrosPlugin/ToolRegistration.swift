import Foundation

/// A macro that generates input schema for a Swift struct.
/// 
/// This macro generates a static `inputSchema` property containing the JSON schema
/// definition for the struct, suitable for use in MCP tool definitions.
///
/// Usage:
/// ```swift
/// @Schema
/// struct FormatTemplateInput {
///     @Field(description: "The type of format template", validOptions: ["commit", "pr-title"])
///     let formatType: String
/// }
/// ```
@attached(extension, conformances: MCP.MCPParameterParsable, names: named(inputSchema), named(parseArguments))
public macro Schema() = #externalMacro(
    module: "MCPToolMacros",
    type: "SchemaMacro"
)

/// A macro that adds schema information to struct properties.
/// 
/// This macro is used in conjunction with @Schema to provide metadata
/// for JSON schema generation.
///
/// Usage:
/// ```swift
/// @Field(description: "The temperature units to use", validOptions: ["celsius", "fahrenheit"], isRequired: true)
/// var units: String
/// ```
@attached(peer)
public macro Field(
    description: String? = nil,
    validOptions: [String]? = nil,
    isRequired: Bool = true
) = #externalMacro(
    module: "MCPToolMacros",
    type: "FieldMacro"
)

