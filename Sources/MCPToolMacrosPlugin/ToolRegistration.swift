import MCP
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
///     @Field(description: "The type of format template", constraint: .options(["commit", "pr-title"]))
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
/// @Field(description: "Search terms")
/// var searchTerms: [String]
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
/// Focused on the most essential constraints: enum and range
public enum FieldConstraint {
    /// Specifies a numeric range for Int fields
    case range(ClosedRange<Int>)
    /// Specifies allowed enum values - LLM can only choose from these options
    case options([String])
    /// Specifies dynamic enum values resolved at runtime from an expression
    /// Usage: .dynamicOptions(DocumentType.allCases.map(\.rawValue))
    case dynamicOptions(Any)
}

// MARK: - Convenience Extensions for Dynamic Options

public extension FieldConstraint {
    /// Creates a dynamic options constraint from a CaseIterable enum
    /// Usage: .dynamicEnum(DocumentType.self)
    static func dynamicEnum<T: CaseIterable & RawRepresentable>(_ enumType: T.Type) -> FieldConstraint where T.RawValue == String {
        return .dynamicOptions(enumType.allCases.map(\.rawValue))
    }
    
    /// Creates a dynamic options constraint from any sequence of strings
    /// Usage: .dynamicSequence(myStringArray)
    static func dynamicSequence<S: Sequence>(_ sequence: S) -> FieldConstraint where S.Element == String {
        return .dynamicOptions(Array(sequence))
    }
}


