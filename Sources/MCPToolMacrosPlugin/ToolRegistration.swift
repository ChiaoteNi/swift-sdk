import Foundation

/// A macro that adds schema information to struct properties.
/// 
/// This macro is used in conjunction with @InputSchema, @OutputSchema, or @Schema
/// to provide additional metadata for JSON schema generation.
///
/// Usage:
/// ```swift
/// @SchemaField(description: "The temperature units to use", enum: ["celsius", "fahrenheit"])
/// let units: String
/// ```
@attached(peer)
public macro SchemaField(
    description: String? = nil,
    enum: [String]? = nil
) = #externalMacro(
    module: "MCPToolMacros",
    type: "SchemaFieldMacro"
)

/// A macro that generates input schema for a Swift struct.
/// 
/// This macro generates a static `inputSchema` property containing the JSON schema
/// definition for the struct, suitable for use in MCP tool definitions.
///
/// Usage:
/// ```swift
/// @InputSchema
/// struct FormatTemplateInput {
///     @SchemaField(description: "The type of format template", enum: ["commit", "pr-title"])
///     let formatType: String
/// }
/// ```
@attached(extension, conformances: MCP.MCPParameterParsable, names: named(inputSchema), named(parseArguments))
public macro InputSchema() = #externalMacro(
    module: "MCPToolMacros",
    type: "InputSchemaMacro"
)

/// A macro that generates output schema for a Swift struct.
/// 
/// This macro generates a static `outputSchema` property containing the JSON schema
/// definition for the struct, suitable for documenting tool output format.
///
/// Usage:
/// ```swift
/// @OutputSchema
/// struct FormatTemplateOutput {
///     let template: String
///     let variables: [String]?
/// }
/// ```
@attached(extension, names: named(outputSchema))
public macro OutputSchema() = #externalMacro(
    module: "MCPToolMacros",
    type: "OutputSchemaMacro"
)

/// A macro that generates input schema for a Swift struct (simpler API).
/// 
/// This macro generates a static `inputSchema` property containing the JSON schema
/// definition for the struct. This is the simpler alternative to @InputSchema.
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

/// A macro that adds schema information to struct properties (simpler API).
/// 
/// This macro is used in conjunction with @Schema to provide metadata
/// for JSON schema generation. This is the simpler alternative to @SchemaField.
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

