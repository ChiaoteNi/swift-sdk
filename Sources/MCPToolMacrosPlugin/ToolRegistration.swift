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
@attached(extension, conformances: MCP.MCPParameterParsable, names: named(inputSchema), named(parseArguments), named(_requireSchema))
public macro Schema() = #externalMacro(
    module: "MCPToolMacros",
    type: "SchemaMacro"
)

/// A macro that adds schema information to struct properties.
/// 
/// This macro is used in conjunction with @Schema to provide metadata
/// for JSON schema generation. Similar to Foundation's @Guide macro.
///
/// Usage:
/// ```swift
/// @Field(description: "The temperature units", constraint: .options(["celsius", "fahrenheit"]))
/// var units: String
/// 
/// @Field(description: "User age", constraint: .range(0...120))
/// var age: Int
/// 
/// @Field(description: "Search terms", constraint: .count(5))
/// var searchTerms: [String]
/// 
/// @Field(description: "Price", constraint: .rangeDouble(0.0...999.9))
/// var price: Double
/// ```
@attached(peer)
public macro Field(
    description: String? = nil,
    constraint: FieldConstraint? = nil,
    isRequired: Bool? = nil
) = #externalMacro(
    module: "MCPToolMacros",
    type: "FieldMacro"
)


/// Field constraints similar to Foundation's @Guide macro  
/// Focused on the most essential constraints: enum, range, and count
public enum FieldConstraint {
    /// Specifies a numeric range for Int fields
    case range(ClosedRange<Int>)
    /// Specifies a numeric range for Double fields  
    case rangeDouble(ClosedRange<Double>)
    /// Specifies exact count for arrays
    case count(Int)
    /// Specifies allowed enum values - LLM can only choose from these options
    case options([String])
}


